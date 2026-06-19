#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Jarvis Faster CustomVoice Starter ==="

: "${VLLM_API_KEY:?VLLM_API_KEY missing}"
: "${VPS_HOST:?VPS_HOST missing}"
: "${VPS_USER:?VPS_USER missing}"

export HF_HOME="${HF_HOME:-/workspace/huggingface}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-/workspace/huggingface}"

ASR_LOCAL_PORT="${ASR_LOCAL_PORT:-8000}"
TTS_LOCAL_PORT="${TTS_LOCAL_PORT:-8091}"
ASR_MODEL="${ASR_MODEL:-Qwen/Qwen3-ASR-0.6B}"
ASR_SERVED_MODEL_NAME="${ASR_SERVED_MODEL_NAME:-qwen3-asr}"

mkdir -p /workspace/logs /workspace/huggingface
cd /workspace

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

# Keep the container alive for direct RunPod port testing. Tunnel support will be added after first runtime validation.
tail -f /workspace/logs/tts-faster-customvoice.log /workspace/logs/asr.log
