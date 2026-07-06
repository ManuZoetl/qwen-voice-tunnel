FROM vllm/vllm-omni:v0.22.0

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      openssh-client openssh-server curl ca-certificates ffmpeg libsndfile1 && \
    mkdir -p /run/sshd /root/.ssh && \
    chmod 700 /root/.ssh && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --no-cache-dir \
    "faster-qwen3-tts[demo]" \
    "fastapi" \
    "uvicorn[standard]" \
    "soundfile" \
    "numpy"

COPY versions/faster-customvoice/faster_customvoice_server.py /usr/local/bin/faster_customvoice_server.py
COPY versions/faster-customvoice/start-faster-customvoice-with-tunnels.sh /usr/local/bin/start-faster-customvoice-with-tunnels.sh
COPY versions/faster-customvoice/entrypoint-faster-customvoice.sh /usr/local/bin/entrypoint-faster-customvoice.sh
RUN chmod +x /usr/local/bin/start-faster-customvoice-with-tunnels.sh /usr/local/bin/entrypoint-faster-customvoice.sh

ENV JARVIS_TTS_MODEL=Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice
ENV JARVIS_TTS_SERVED_MODEL_NAME=qwen3-tts-faster-customvoice
ENV JARVIS_TTS_DEFAULT_SPEAKER=aiden
ENV JARVIS_TTS_DEFAULT_LANGUAGE=German
ENV TTS_LOCAL_PORT=8091
ENV TTS_REMOTE_PORT=18082

# ASR is external now. The old ASR tunnel slot is reused by the Speaker LLM.
ENV SPEAKER_MODEL=nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8
ENV SPEAKER_SERVED_MODEL_NAME=jarvis-speaker
ENV SPEAKER_LOCAL_PORT=8000
ENV SPEAKER_REMOTE_PORT=18081
ENV SPEAKER_GPU_MEMORY_UTILIZATION=0.20
ENV SPEAKER_MAX_MODEL_LEN=2048
ENV SPEAKER_MAX_NUM_BATCHED_TOKENS=512
ENV SPEAKER_DTYPE=auto

ENV ENABLE_CONTAINER_SSH=true
ENV CONTAINER_SSH_PORT=22

EXPOSE 22/tcp 8000/tcp 8091/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint-faster-customvoice.sh"]
CMD []
