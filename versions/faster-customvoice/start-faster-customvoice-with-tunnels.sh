#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Jarvis Faster CustomVoice + Speaker Tunnel Starter ==="

: "${VLLM_API_KEY:?VLLM_API_KEY missing}"
: "${VPS_HOST:?VPS_HOST missing}"
: "${VPS_USER:?VPS_USER missing}"
KEY_ENV_NAME="${KEY_ENV_NAME:-RUNPOD_TUNNEL_PRIVATE_KEY_B64}"
: "${!KEY_ENV_NAME:?${KEY_ENV_NAME} missing}"

export HF_HOME="${HF_HOME:-/workspace/huggingface}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-/workspace/huggingface}"

VPS_PORT="${VPS_PORT:-22}"
TTS_LOCAL_PORT="${TTS_LOCAL_PORT:-8091}"
TTS_REMOTE_PORT="${TTS_REMOTE_PORT:-18082}"

# ASR was moved to Groq. Reuse the old ASR tunnel slot for the low-latency Speaker LLM.
# Keep ASR_* as fallback env names so existing RunPod templates continue to work.
SPEAKER_LOCAL_PORT="${SPEAKER_LOCAL_PORT:-${ASR_LOCAL_PORT:-8000}}"
SPEAKER_REMOTE_PORT="${SPEAKER_REMOTE_PORT:-${ASR_REMOTE_PORT:-18081}}"
SPEAKER_MODEL="${SPEAKER_MODEL:-nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8}"
SPEAKER_SERVED_MODEL_NAME="${SPEAKER_SERVED_MODEL_NAME:-jarvis-speaker}"
SPEAKER_GPU_MEMORY_UTILIZATION="${SPEAKER_GPU_MEMORY_UTILIZATION:-0.20}"
SPEAKER_MAX_MODEL_LEN="${SPEAKER_MAX_MODEL_LEN:-2048}"
SPEAKER_MAX_NUM_BATCHED_TOKENS="${SPEAKER_MAX_NUM_BATCHED_TOKENS:-512}"
SPEAKER_DTYPE="${SPEAKER_DTYPE:-auto}"

mkdir -p /workspace/logs /workspace/huggingface /root/.ssh
chmod 700 /root/.ssh
cd /workspace

echo "== Mode =="
echo "TTS_LOCAL_PORT=$TTS_LOCAL_PORT"
echo "TTS_REMOTE_PORT=$TTS_REMOTE_PORT"
echo "SPEAKER_MODEL=$SPEAKER_MODEL"
echo "SPEAKER_SERVED_MODEL_NAME=$SPEAKER_SERVED_MODEL_NAME"
echo "SPEAKER_LOCAL_PORT=$SPEAKER_LOCAL_PORT"
echo "SPEAKER_REMOTE_PORT=$SPEAKER_REMOTE_PORT"

echo "== Prepare SSH key =="
printf "%s" "${!KEY_ENV_NAME}" | base64 -d > /root/.ssh/runpod_tunnel_key
chmod 600 /root/.ssh/runpod_tunnel_key

echo "== Add VPS host key =="
ssh-keyscan -p "$VPS_PORT" -H "$VPS_HOST" >> /root/.ssh/known_hosts 2>/dev/null || true

echo "== Stop old local voice processes =="
pkill -9 -f "Qwen3-ASR|qwen3-asr|jarvis-speaker|Nemotron|faster_customvoice_server|uvicorn" || true
pkill -9 -f "vllm serve" || true
sleep 5

echo "== Start Faster CustomVoice TTS on ${TTS_LOCAL_PORT} =="
nohup uvicorn faster_customvoice_server:app \
  --app-dir /usr/local/bin \
  --host 0.0.0.0 \
  --port "$TTS_LOCAL_PORT" \
  > /workspace/logs/tts-faster-customvoice.log 2>&1 &

for i in $(seq 1 160); do
  if curl -sS "http://127.0.0.1:${TTS_LOCAL_PORT}/health" >/dev/null 2>&1; then
    echo "Faster CustomVoice TTS ready"
    break
  fi
  sleep 3
  if [ "$i" = "160" ]; then
    echo "Faster CustomVoice TTS did not become ready."
    echo "Check: tail -200 /workspace/logs/tts-faster-customvoice.log"
    exit 1
  fi
done

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
nvidia-smi || true

echo "Voice + Speaker stack ready."
echo "Speaker internal: http://127.0.0.1:${SPEAKER_LOCAL_PORT}/v1/chat/completions"
echo "TTS internal: http://127.0.0.1:${TTS_LOCAL_PORT}/v1/audio/speech"

echo "== Start reverse SSH tunnels =="
echo "VPS 127.0.0.1:${SPEAKER_REMOTE_PORT} -> RunPod 127.0.0.1:${SPEAKER_LOCAL_PORT} (old ASR/asr.arbitraiq.com slot)"
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

  if ! pgrep -f "faster_customvoice_server|uvicorn" >/dev/null 2>&1; then
    echo "Faster CustomVoice TTS process is no longer running. Exiting."
    exit 1
  fi
  if ! pgrep -f "jarvis-speaker|Nemotron|vllm serve" >/dev/null 2>&1; then
    echo "Speaker LLM process is no longer running. Exiting."
    exit 1
  fi
  sleep 5
done
