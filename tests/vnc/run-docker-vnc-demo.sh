#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${CMUX_VNC_DEMO_IMAGE:-cmux-vnc-demo:latest}"
PASSWORD="${CMUX_VNC_DEMO_PASSWORD:-cmuxvnc}"
MANIFEST_OUT="${1:-}"

docker build -t "$IMAGE" "$SCRIPT_DIR/docker-demo"

for index in 1 2; do
  name="cmux-vnc-demo-$index"
  port=$((5900 + index))
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run \
    --detach \
    --name "$name" \
    --publish "127.0.0.1:$port:5900" \
    --env "VNC_PASSWORD=$PASSWORD" \
    --env "SESSION_TITLE=cmux Docker VNC $index" \
    "$IMAGE" >/dev/null
done

for index in 1 2; do
  port=$((5900 + index))
  for attempt in $(seq 1 60); do
    if nc -z 127.0.0.1 "$port"; then
      break
    fi
    if [[ "$attempt" == "60" ]]; then
      echo "error: VNC demo container $index did not open port $port" >&2
      exit 1
    fi
    sleep 1
  done
done

if [[ -n "$MANIFEST_OUT" ]]; then
  mkdir -p "$(dirname "$MANIFEST_OUT")"
  cat >"$MANIFEST_OUT" <<JSON
{
  "default_password": "$PASSWORD",
  "hosts": [
    {
      "name": "docker-vnc",
      "prefix": "docker-vnc",
      "tag": "tag:mac-mini-cluster",
      "sessions": [
        {
          "index": 1,
          "name": "docker-vnc-1",
          "address": "127.0.0.1",
          "port": 5901,
          "username": "cmuxvnc"
        },
        {
          "index": 2,
          "name": "docker-vnc-2",
          "address": "127.0.0.1",
          "port": 5902,
          "username": "cmuxvnc"
        }
      ]
    }
  ]
}
JSON
fi

echo "Docker VNC demo sessions are listening on 127.0.0.1:5901 and 127.0.0.1:5902"
