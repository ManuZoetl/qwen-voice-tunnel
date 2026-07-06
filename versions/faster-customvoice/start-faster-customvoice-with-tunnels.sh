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
# vLLM uses this fraction to calculate model + CUDA graph + KV-cache budget. 0.20 is too low
# for Nemotron 4B FP8 because the weights alone need ~5 GiB, so no KV cache remains.
SPEAKER_GPU_MEMORY_UTILIZATION="${SPEAKER_GPU_MEMORY_UTILIZATION:-0.55}"
SPEAKER_MAX_MODEL_LEN="${SPEAKER_MAX_MODEL_LEN:-1024}"
SPEAKER_MAX_NUM_BATCHED_TOKENS="${SPEAKER_MAX_NUM_BATCHED_TOKENS:-256}"
SPEAKER_DTYPE="${SPEAKER_DTYPE:-auto}"
# Prefix caching can help repeated long Speaker prompts, but Qwen3.5 uses experimental Mamba cache handling.
# Keep it opt-in so weaker/different 20GB GPUs can still start reliably.
SPEAKER_ENABLE_PREFIX_CACHING="${SPEAKER_ENABLE_PREFIX_CACHING:-false}"
SPEAKER_STARTUP_TIMEOUT_SECONDS="${SPEAKER_STARTUP_TIMEOUT_SECONDS:-900}"
SPEAKER_LOG="/workspace/logs/speaker.log"

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
echo "SPEAKER_GPU_MEMORY_UTILIZATION=$SPEAKER_GPU_MEMORY_UTILIZATION"
echo "SPEAKER_MAX_MODEL_LEN=$SPEAKER_MAX_MODEL_LEN"
echo "SPEAKER_MAX_NUM_BATCHED_TOKENS=$SPEAKER_MAX_NUM_BATCHED_TOKENS"
echo "SPEAKER_ENABLE_PREFIX_CACHING=$SPEAKER_ENABLE_PREFIX_CACHING"
echo "SPEAKER_STARTUP_TIMEOUT_SECONDS=$SPEAKER_STARTUP_TIMEOUT_SECONDS"

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
    echo "== TTS log tail =="
    tail -200 /workspace/logs/tts-faster-customvoice.log || true
    exit 1
  fi
done

echo "== Start Speaker LLM on ${SPEAKER_LOCAL_PORT} =="
SPEAKER_VLLM_EXTRA_ARGS=()
if [ "$SPEAKER_ENABLE_PREFIX_CACHING" = "true" ]; then
  SPEAKER_VLLM_EXTRA_ARGS+=(--enable-prefix-caching)
fi
if [ -n "${SPEAKER_LIMIT_MM_PER_PROMPT:-}" ]; then
  SPEAKER_VLLM_EXTRA_ARGS+=(--limit-mm-per-prompt "$SPEAKER_LIMIT_MM_PER_PROMPT")
fi
if [ -n "${SPEAKER_SAFETENSORS_LOAD_STRATEGY:-}" ]; then
  SPEAKER_VLLM_EXTRA_ARGS+=(--safetensors-load-strategy "$SPEAKER_SAFETENSORS_LOAD_STRATEGY")
fi
: > "$SPEAKER_LOG"
nohup vllm serve "$SPEAKER_MODEL" \
  --served-model-name "$SPEAKER_SERVED_MODEL_NAME" \
  --host 0.0.0.0 \
  --port "$SPEAKER_LOCAL_PORT" \
  --dtype "$SPEAKER_DTYPE" \
  --max-model-len "$SPEAKER_MAX_MODEL_LEN" \
  --gpu-memory-utilization "$SPEAKER_GPU_MEMORY_UTILIZATION" \
  --max-num-seqs 1 \
  --max-num-batched-tokens "$SPEAKER_MAX_NUM_BATCHED_TOKENS" \
  "${SPEAKER_VLLM_EXTRA_ARGS[@]}" \
  --download-dir /workspace/huggingface \
  --trust-remote-code \
  --api-key "$VLLM_API_KEY" \
  > "$SPEAKER_LOG" 2>&1 &
SPEAKER_PID=$!
echo "Speaker LLM PID: ${SPEAKER_PID}"

echo "== Wait for Speaker LLM =="
SPEAKER_WAIT_ITERATIONS=$((SPEAKER_STARTUP_TIMEOUT_SECONDS / 3))
if [ "$SPEAKER_WAIT_ITERATIONS" -lt 1 ]; then
  SPEAKER_WAIT_ITERATIONS=1
fi

for i in $(seq 1 "$SPEAKER_WAIT_ITERATIONS"); do
  if ! kill -0 "$SPEAKER_PID" >/dev/null 2>&1; then
    echo "Speaker LLM process exited before becoming ready."
    echo "== Speaker log tail =="
    tail -300 "$SPEAKER_LOG" || true
    echo "== GPU status =="
    nvidia-smi || true
    exit 1
  fi

  if curl -sS "http://127.0.0.1:${SPEAKER_LOCAL_PORT}/v1/models" -H "Authorization: Bearer $VLLM_API_KEY" >/dev/null 2>&1; then
    echo "Speaker LLM ready"
    break
  fi

  if [ $((i % 10)) -eq 0 ]; then
    echo "Speaker still starting... elapsed=$((i * 3))s"
    echo "== Speaker log tail =="
    tail -60 "$SPEAKER_LOG" || true
    echo "== GPU status =="
    nvidia-smi || true
  fi

  sleep 3

  if [ "$i" = "$SPEAKER_WAIT_ITERATIONS" ]; then
    echo "Speaker LLM did not become ready within ${SPEAKER_STARTUP_TIMEOUT_SECONDS}s."
    echo "== Speaker log tail =="
    tail -300 "$SPEAKER_LOG" || true
    echo "== GPU status =="
    nvidia-smi || true
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
  if ! kill -0 "$SPEAKER_PID" >/dev/null 2>&1; then
    echo "Speaker LLM process is no longer running."
    echo "== Speaker log tail =="
    tail -300 "$SPEAKER_LOG" || true
    exit 1
  fi
  sleep 5
done
