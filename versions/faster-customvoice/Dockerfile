FROM vllm/vllm-omni:v0.22.0

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      openssh-client curl ca-certificates ffmpeg libsndfile1 && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --no-cache-dir \
    "faster-qwen3-tts[demo]" \
    "fastapi" \
    "uvicorn[standard]" \
    "soundfile" \
    "numpy"

COPY versions/faster-customvoice/faster_customvoice_server.py /usr/local/bin/faster_customvoice_server.py
COPY versions/faster-customvoice/start-faster-customvoice-with-tunnels.sh /usr/local/bin/start-faster-customvoice-with-tunnels.sh
RUN chmod +x /usr/local/bin/start-faster-customvoice-with-tunnels.sh

ENV JARVIS_TTS_MODEL=Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice
ENV JARVIS_TTS_SERVED_MODEL_NAME=qwen3-tts-faster-customvoice
ENV JARVIS_TTS_DEFAULT_SPEAKER=aiden
ENV JARVIS_TTS_DEFAULT_LANGUAGE=German
ENV TTS_LOCAL_PORT=8091
ENV ASR_MODEL=Qwen/Qwen3-ASR-0.6B
ENV ASR_SERVED_MODEL_NAME=qwen3-asr
ENV ASR_LOCAL_PORT=8092

EXPOSE 8091/tcp 8092/tcp

ENTRYPOINT ["/usr/local/bin/start-faster-customvoice-with-tunnels.sh"]
CMD []
