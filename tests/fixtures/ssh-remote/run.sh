#!/bin/sh
set -eu

if [ -z "${AUTHORIZED_KEY:-}" ]; then
  echo "AUTHORIZED_KEY is required" >&2
  exit 1
fi

REMOTE_HTTP_PORT="${REMOTE_HTTP_PORT:-43173}"
REMOTE_WS_PORT="${REMOTE_WS_PORT:-43174}"

mkdir -p /home/dev/.ssh /root/.ssh /run/sshd
printf '%s\n' "$AUTHORIZED_KEY" > /home/dev/.ssh/authorized_keys
printf '%s\n' "$AUTHORIZED_KEY" > /root/.ssh/authorized_keys
chown -R dev:dev /home/dev/.ssh
chmod 700 /home/dev/.ssh
chmod 600 /home/dev/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

python3 -m http.server "$REMOTE_HTTP_PORT" --bind 127.0.0.1 --directory /srv/www >/tmp/http.log 2>&1 &
HTTP_PID=$!
python3 /usr/local/bin/ws_echo.py --host 127.0.0.1 --port "$REMOTE_WS_PORT" >/tmp/ws.log 2>&1 &
WS_PID=$!

sleep 0.2
if ! kill -0 "$HTTP_PID" 2>/dev/null; then
  echo "HTTP fixture failed to start (see /tmp/http.log)" >&2
  cat /tmp/http.log >&2 || true
  exit 1
fi
if ! kill -0 "$WS_PID" 2>/dev/null; then
  echo "WebSocket fixture failed to start (see /tmp/ws.log)" >&2
  cat /tmp/ws.log >&2 || true
  exit 1
fi

exec /usr/sbin/sshd -D -e
