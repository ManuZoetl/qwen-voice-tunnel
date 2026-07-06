#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Qwen Voice + Speaker Tunnel Starter ==="

: "${VLLM_API_KEY:?VLLM_API_KEY missing}"
: "${RUNPOD_TUNNEL_PRIVATE_KEY_B64:?RUNPOD_TUNNEL_PRIVATE_KEY_B64 missing}"
: "${VPS_HOST:?VPS_HOST missing}"
: "${VPS_USER:?VPS_USER missing}"
: "${TTS_MODE:?TTS_MODE missing: base | customvoice | voicedesign}"

export HF_HOME="${HF_HOME:-/workspace/huggingface}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-/workspace/huggingface}"

VPS_PORT="${VPS_PORT:-22}"

# Local services inside the RunPod container.
# ASR has been moved out to Groq, so the old ASR tunnel slot is now used by the Speaker LLM.
SPEAKER_LOCAL_PORT="${SPEAKER_LOCAL_PORT:-8000}"
TTS_LOCAL_PORT="${TTS_LOCAL_PORT:-8091}"

# Remote VPS ports. Keep SPEAKER_REMOTE_PORT on the former ASR_REMOTE_PORT so the existing
# asr.arbitraiq.com nginx tunnel target can be reused without changing public DNS/nginx.
SPEAKER_REMOTE_PORT="${SPEAKER_REMOTE_PORT:-${ASR_REMOTE_PORT:-18081}}"
TTS_REMOTE_PORT="${TTS_REMOTE_PORT:-18082}"

DEFAULT_VOICE_FILE="${DEFAULT_VOICE_FILE:-/workspace/jarvis_reference.wav}"
DEFAULT_VOICE_NAME="${DEFAULT_VOICE_NAME:-jarvis_main}"

# Speaker LLM defaults. This process is only the low-latency persona/dialog layer.
SPEAKER_MODEL="${SPEAKER_MODEL:-nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8}"
SPEAKER_SERVED_MODEL_NAME="${SPEAKER_SERVED_MODEL_NAME:-jarvis-speaker}"
SPEAKER_GPU_MEMORY_UTILIZATION="${SPEAKER_GPU_MEMORY_UTILIZATION:-0.20}"
SPEAKER_MAX_MODEL_LEN="${SPEAKER_MAX_MODEL_LEN:-2048}"
SPEAKER_MAX_NUM_BATCHED_TOKENS="${SPEAKER_MAX_NUM_BATCHED_TOKENS:-512}"
SPEAKER_DTYPE="${SPEAKER_DTYPE:-auto}"

case "$TTS_MODE" in
  base)
    TTS_MODEL="Qwen/Qwen3-TTS-12Hz-1.7B-Base"
    TTS_SERVED_MODEL_NAME="${TTS_SERVED_MODEL_NAME:-qwen3-tts-base}"
    TTS_LOG="/workspace/logs/tts-base-1.7b.log"
    ;;
  customvoice)
    TTS_MODEL="Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"
    TTS_SERVED_MODEL_NAME="${TTS_SERVED_MODEL_NAME:-qwen3-tts-customvoice}"
    TTS_LOG="/workspace/logs/tts-customvoice-1.7b.log"
    ;;
  voicedesign)
    TTS_MODEL="Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"
    TTS_SERVED_MODEL_NAME="${TTS_SERVED_MODEL_NAME:-qwen3-tts-voicedesign}"
    TTS_LOG="/workspace/logs/tts-voicedesign-1.7b.log"
    ;;
  *)
    echo "Invalid TTS_MODE=$TTS_MODE. Use: base | customvoice | voicedesign"
    exit 1
    ;;
esac

mkdir -p /workspace/logs /workspace/huggingface /root/.ssh
chmod 700 /root/.ssh
cd /workspace

echo "== Mode =="
echo "TTS_MODE=$TTS_MODE"
echo "TTS_MODEL=$TTS_MODEL"
echo "TTS_SERVED_MODEL_NAME=$TTS_SERVED_MODEL_NAME"
echo "SPEAKER_MODEL=$SPEAKER_MODEL"
echo "SPEAKER_SERVED_MODEL_NAME=$SPEAKER_SERVED_MODEL_NAME"
echo "SPEAKER_LOCAL_PORT=$SPEAKER_LOCAL_PORT"
echo "SPEAKER_REMOTE_PORT=$SPEAKER_REMOTE_PORT"

echo "== Prepare SSH key =="
echo "$RUNPOD_TUNNEL_PRIVATE_KEY_B64" | base64 -d > /root/.ssh/runpod_tunnel_key
chmod 600 /root/.ssh/runpod_tunnel_key

echo "== Add VPS host key =="
ssh-keyscan -p "$VPS_PORT" -H "$VPS_HOST" >> /root/.ssh/known_hosts 2>/dev/null || true

echo "== Stop old voice/speaker processes =="
pkill -9 -f "Qwen3-ASR" || true
pkill -9 -f "qwen3-asr" || true
pkill -9 -f "Qwen3-TTS" || true
pkill -9 -f "qwen3-tts" || true
pkill -9 -f "Nemotron" || true
pkill -9 -f "jarvis-speaker" || true
pkill -9 -f "StageEngineCoreProc" || true
sleep 8

echo "== Create TTS live config =="
cp /usr/local/lib/python3.12/dist-packages/vllm_omni/deploy/qwen3_tts.yaml /workspace/qwen3_tts_17b_live.yaml

# TTS Stage 0 / Talker
sed -i '/stage_id: 0/,/devices:/ s/max_num_seqs: .*/max_num_seqs: 1/' /workspace/qwen3_tts_17b_live.yaml
sed -i '/stage_id: 0/,/devices:/ s/gpu_memory_utilization: .*/gpu_memory_utilization: 0.30/' /workspace/qwen3_tts_17b_live.yaml
sed -i '/stage_id: 0/,/devices:/ s/max_num_batched_tokens: .*/max_num_batched_tokens: 512/' /workspace/qwen3_tts_17b_live.yaml
sed -i '/stage_id: 0/,/devices:/ s/max_model_len: .*/max_model_len: 2048/' /workspace/qwen3_tts_17b_live.yaml

# TTS Stage 1 / Code2Wav
sed -i '/stage_id: 1/,/devices:/ s/max_num_seqs: .*/max_num_seqs: 1/' /workspace/qwen3_tts_17b_live.yaml
sed -i '/stage_id: 1/,/devices:/ s/gpu_memory_utilization: .*/gpu_memory_utilization: 0.22/' /workspace/qwen3_tts_17b_live.yaml
sed -i '/stage_id: 1/,/devices:/ s/max_num_batched_tokens: .*/max_num_batched_tokens: 16384/' /workspace/qwen3_tts_17b_live.yaml
sed -i '/stage_id: 1/,/devices:/ s/max_model_len: .*/max_model_len: 16384/' /workspace/qwen3_tts_17b_live.yaml

echo "== TTS config summary =="
grep -nE "stage_id:|gpu_memory_utilization|max_num_seqs|max_model_len|max_num_batched_tokens|devices:" /workspace/qwen3_tts_17b_live.yaml || true

echo "== Start TTS on ${TTS_LOCAL_PORT} =="
nohup vllm serve "$TTS_MODEL" \
  --served-model-name "$TTS_SERVED_MODEL_NAME" \
  --omni \
  --stage-configs-path /workspace/qwen3_tts_17b_live.yaml \
  --host 0.0.0.0 \
  --port "$TTS_LOCAL_PORT" \
  --download-dir /workspace/huggingface \
  --trust-remote-code \
  --enforce-eager \
  --allowed-local-media-path /workspace \
  --api-key "$VLLM_API_KEY" \
  > "$TTS_LOG" 2>&1 &

echo "== Wait for TTS =="
for i in $(seq 1 160); do
  if curl -sS "http://127.0.0.1:${TTS_LOCAL_PORT}/v1/models" -H "Authorization: Bearer $VLLM_API_KEY" >/dev/null 2>&1; then
    echo "TTS ready"
    break
  fi
  sleep 3
  if [ "$i" = "160" ]; then
    echo "TTS did not become ready."
    echo "Check: tail -200 $TTS_LOG"
    exit 1
  fi
done

if [[ "$TTS_MODE" == "base" ]]; then
  echo "== Upload default clone voice for Base model =="
  if [ -f "$DEFAULT_VOICE_FILE" ]; then
    curl -sS -X POST "http://127.0.0.1:${TTS_LOCAL_PORT}/v1/audio/voices" \
      -H "Authorization: Bearer $VLLM_API_KEY" \
      -F "audio_sample=@${DEFAULT_VOICE_FILE}" \
      -F "consent=manual_user_consent_jarvis_voice" \
      -F "name=${DEFAULT_VOICE_NAME}" \
      -F "speaker_description=ruhige klare deutsche Jarvis-Assistentenstimme" || true
    echo ""
  else
    echo "WARNING: $DEFAULT_VOICE_FILE not found. Default clone voice was not uploaded."
  fi
else
  echo "== Skip voice upload =="
  echo "Voice upload is only used for Base clone mode."
fi

echo "== Start Speaker LLM on ${SPEAKER_LOCAL_PORT} =="
nohup vllm serve "$SPEAKER_MODEL" \
  --served-model-name "$SPEAKER_SERVED_MODEL_NAME" \
  --host 0.0.0.0 \
  --port "$SPEAKER_LOCAL_PORT" \
  --dtype "$SPEAKER_DTYPE" \
  --max-model-len "$SPEAKER_MAX_MODEL_LEN" \
  --gpu-memory-utilization "$SPEAKER_GPU_MEMORY_UTILIZATION" \
  --max-num-seqs 1 \
  --max-num-batched-tokens "$SPEAKER_MAX_NUM_BATCHED_TOKENS" \
  --download-dir /workspace/huggingface \
  --trust-remote-code \
  --api-key "$VLLM_API_KEY" \
  > /workspace/logs/speaker.log 2>&1 &

echo "== Wait for Speaker LLM =="
for i in $(seq 1 120); do
  if curl -sS "http://127.0.0.1:${SPEAKER_LOCAL_PORT}/v1/models" -H "Authorization: Bearer $VLLM_API_KEY" >/dev/null 2>&1; then
    echo "Speaker LLM ready"
    break
  fi
  sleep 3
  if [ "$i" = "120" ]; then
    echo "Speaker LLM did not become ready."
    echo "Check: tail -200 /workspace/logs/speaker.log"
    exit 1
  fi
done

echo "== Status =="
echo "-- Speaker models --"
curl -sS "http://127.0.0.1:${SPEAKER_LOCAL_PORT}/v1/models" -H "Authorization: Bearer $VLLM_API_KEY" || true
echo ""
echo "-- TTS models --"
curl -sS "http://127.0.0.1:${TTS_LOCAL_PORT}/v1/models" -H "Authorization: Bearer $VLLM_API_KEY" || true
echo ""
echo "-- TTS voices --"
curl -sS "http://127.0.0.1:${TTS_LOCAL_PORT}/v1/audio/voices" -H "Authorization: Bearer $VLLM_API_KEY" || true
echo ""
echo "-- GPU --"
nvidia-smi || true

echo ""
echo "Voice + Speaker stack ready."
echo "Speaker internal: http://127.0.0.1:${SPEAKER_LOCAL_PORT}/v1/chat/completions"
echo "TTS internal: http://127.0.0.1:${TTS_LOCAL_PORT}/v1/audio/speech"

echo "== Start reverse SSH tunnels =="
echo "VPS 127.0.0.1:${SPEAKER_REMOTE_PORT} -> RunPod 127.0.0.1:${SPEAKER_LOCAL_PORT} (asr.arbitraiq.com slot)"
echo "VPS 127.0.0.1:${TTS_REMOTE_PORT} -> RunPod 127.0.0.1:${TTS_LOCAL_PORT}"

while true; do
  ssh -i /root/.ssh/runpod_tunnel_key \
    -N -T \
    -p "$VPS_PORT" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -R "127.0.0.1:${SPEAKER_REMOTE_PORT}:127.0.0.1:${SPEAKER_LOCAL_PORT}" \
    -R "127.0.0.1:${TTS_REMOTE_PORT}:127.0.0.1:${TTS_LOCAL_PORT}" \
    "${VPS_USER}@${VPS_HOST}" &

  TUNNEL_PID=$!
  echo "Tunnel PID: ${TUNNEL_PID}"

  wait "$TUNNEL_PID" || true
  echo "Tunnel disconnected. Reconnecting in 5 seconds..."

  if ! pgrep -f "jarvis-speaker|Nemotron" >/dev/null 2>&1; then
    echo "Speaker LLM process is no longer running. Exiting."
    exit 1
  fi

  sleep 5
done
