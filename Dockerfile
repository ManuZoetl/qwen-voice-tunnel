FROM vllm/vllm-omni:v0.22.0

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends openssh-client openssh-server curl ca-certificates && \
    mkdir -p /run/sshd /root/.ssh && \
    chmod 700 /root/.ssh && \
    rm -rf /var/lib/apt/lists/*

COPY start-qwen-voice-with-tunnels.sh /usr/local/bin/start-qwen-voice-with-tunnels-real.sh
COPY entrypoint-qwen-voice.sh /usr/local/bin/start-qwen-voice-with-tunnels.sh
RUN chmod +x /usr/local/bin/start-qwen-voice-with-tunnels.sh /usr/local/bin/start-qwen-voice-with-tunnels-real.sh

ENV ENABLE_CONTAINER_SSH=true
ENV CONTAINER_SSH_PORT=22

EXPOSE 22/tcp

ENTRYPOINT ["/usr/local/bin/start-qwen-voice-with-tunnels.sh"]
CMD []
