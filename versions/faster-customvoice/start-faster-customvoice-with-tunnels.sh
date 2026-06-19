#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Jarvis Faster CustomVoice Tunnel Starter ==="

: "${VLLM_API_KEY:?VLLM_API_KEY missing}"
: "${VPS_HOST:?VPS_HOST missing}"
: "${VPS_USER:?VPS_USER missing}"
KEY_ENV_NAME="${KEY_ENV_NAME:-RUNPOD_TUNNEL_PRIVATE_KEY_B64}"
: "${!KEY_ENV_NAME:?${KEY_ENV_NAME} missing}"

export HF_HOME="${HF_HOME:-/workspace/huggingface}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-/workspace/huggingface}"

VPS_PORT="${VPS_PORT:-22}"
ASR_LOCAL_PORT="${ASR_LOCAL_PORT:-8092}"
TTS_LOCAL_PORT="${TTS_LOCAL_PORT:-8091}"
ASR_REMOTE_PORT="${ASR_REMOTE_PORT:-18081}"
TTS_REMOTE_PORT="${TTS_REMOTE_PORT:-18082}"
ASR_MODEL="${ASR_MODEL:-Qwen/Qwen3-ASR-0.6B}"
ASR_SERVED_MODEL_NAME="${ASR_SERVED_MODEL_NAME:-qwen3-asr}"

mkdir -p /workspace/logs /workspace/huggingface /root/.ssh
chmod 700 /root/.ssh
cd /workspace

echo "== Prepare SSH key =="
printf "%s" "${!KEY_ENV_NAME}" | base64 -d > /root/.ssh/runpod_tunnel_key
chmod 600 /root/.ssh/runpod_tunnel_key

echo "== Add VPS host key =="
ssh-keyscan -p "$VPS_PORT" -H "$VPS_HOST" >> /root/.ssh/known_hosts 2>/dev/null || true

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

echo "== Start ASR on ${ASR_LOCAL_PORT} =="
nohup vllm serve "$ASR_MODEL" \
  --served-model-name "$ASR_SERVED_MODEL_NAME" \
  --host 0.0.0.0 \
  --port "$ASR_LOCAL_PORT" \
  --dtype bfloat16 \
  --max-model-len 1024 \
  --gpu-memory-utilization "${ASR_GPU_MEMORY_UTILIZATION:-0.18}" \
  --max-num-seqs 1 \
  --max-num-batched-tokens 1024 \
  --download-dir /workspace/huggingface \
  --trust-remote-code \
  --api-key "$VLLM_API_KEY" \
  > /workspace/logs/asr.log 2>&1 &

for i in $(seq 1 80); do
  if curl -sS "http://127.0.0.1:${ASR_LOCAL_PORT}/v1/models" -H "Authorization: Bearer $VLLM_API_KEY" >/dev/null 2>&1; then
    echo "ASR ready"
    break
  fi
  sleep 3
  if [ "$i" = "80" ]; then
    echo "ASR did not become ready."
    echo "Check: tail -200 /workspace/logs/asr.log"
    exit 1
  fi
done

echo "== Status =="
echo "-- ASR models --"
curl -sS "http://127.0.0.1:${ASR_LOCAL_PORT}/v1/models" -H "Authorization: Bearer $VLLM_API_KEY" || true
echo ""
echo "-- TTS models --"
curl -sS "http://127.0.0.1:${TTS_LOCAL_PORT}/v1/models" -H "Authorization: Bearer $VLLM_API_KEY" || true
echo ""
echo "-- TTS voices --"
curl -sS "http://127.0.0.1:${TTS_LOCAL_PORT}/v1/audio/voices" -H "Authorization: Bearer $VLLM_API_KEY" || true
echo ""
nvidia-smi || true

echo "Voice stack ready."
echo "ASR internal: http://127.0.0.1:${ASR_LOCAL_PORT}/v1/audio/transcriptions"
echo "TTS internal: http://127.0.0.1:${TTS_LOCAL_PORT}/v1/audio/speech"

echo "== Start reverse SSH tunnels =="
echo "VPS 127.0.0.1:${ASR_REMOTE_PORT} -> RunPod 127.0.0.1:${ASR_LOCAL_PORT}"
echo "VPS 127.0.0.1:${TTS_REMOTE_PORT} -> RunPod 127.0.0.1:${TTS_LOCAL_PORT}"

while true; do
  ssh -i /root/.ssh/runpod_tunnel_key \
    -N -T \
    -p "$VPS_PORT" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -R "127.0.0.1:${ASR_REMOTE_PORT}:127.0.0.1:${ASR_LOCAL_PORT}" \
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
  if ! pgrep -f "qwen3-asr|Qwen3-ASR" >/dev/null 2>&1; then
    echo "ASR process is no longer running. Exiting."
    exit 1
  fi
  sleep 5
done
