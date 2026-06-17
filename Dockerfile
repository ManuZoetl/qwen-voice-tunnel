FROM vllm/vllm-omni:v0.22.0

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends openssh-client curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY start-qwen-voice-with-tunnels.sh /usr/local/bin/start-qwen-voice-with-tunnels.sh
RUN chmod +x /usr/local/bin/start-qwen-voice-with-tunnels.sh

ENTRYPOINT ["/usr/local/bin/start-qwen-voice-with-tunnels.sh"]
CMD []
