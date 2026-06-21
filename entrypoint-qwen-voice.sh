#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Qwen Voice container entrypoint ==="

if [[ "${ENABLE_CONTAINER_SSH:-true}" == "true" ]]; then
  echo "== Prepare container SSH =="
  mkdir -p /run/sshd /root/.ssh
  chmod 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys

  echo "== Authorized SSH key fingerprints =="
  ssh-keygen -lf /root/.ssh/authorized_keys || true

  ssh-keygen -A >/dev/null 2>&1 || true

  sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config || true
  sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config || true
  sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
  sed -i 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config || true

  if pgrep -x sshd >/dev/null 2>&1; then
    echo "sshd already running; not starting another one."
  else
    echo "Starting container sshd on port ${CONTAINER_SSH_PORT:-22}..."
    /usr/sbin/sshd -D -e -p "${CONTAINER_SSH_PORT:-22}" &
    echo "Container sshd PID: $!"
  fi
fi

exec /usr/local/bin/start-qwen-voice-with-tunnels.sh "$@"
