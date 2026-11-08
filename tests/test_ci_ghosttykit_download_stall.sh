#!/usr/bin/env bash
# A download that stalls mid-transfer must be dropped quickly and resumed on a
# new connection, instead of crawling until the per-attempt time limit.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

head -c 3145728 /dev/urandom > "$WORK/GhosttyKit.xcframework.tar.gz"
SHA="$(shasum -a 256 "$WORK/GhosttyKit.xcframework.tar.gz" | awk '{print $1}')"
echo "feedfacefeedfacefeedfacefeedfacefeedface $SHA" > "$WORK/checksums.txt"
printf 'import sys\nsys.exit(0)\n' > "$WORK/validator.py"

cat > "$WORK/server.py" <<'PY'
import http.server, os, sys, time

root, log = sys.argv[1], sys.argv[2]
payload = open(os.path.join(root, "GhosttyKit.xcframework.tar.gz"), "rb").read()
state = {"requests": 0}

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        state["requests"] += 1
        rng = self.headers.get("Range")
        with open(log, "a") as handle:
            handle.write(f"{state['requests']} {rng}\n")
        if state["requests"] == 1:
            # First connection: send a little, then stall.
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload[:65536])
            self.wfile.flush()
            time.sleep(120)
            return
        start = int(rng.split("=")[1].split("-")[0]) if rng else 0
        body = payload[start:]
        self.send_response(206 if rng else 200)
        if rng:
            self.send_header("Content-Range", f"bytes {start}-{len(payload) - 1}/{len(payload)}")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(root, "port"), "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY

python3 "$WORK/server.py" "$WORK" "$WORK/requests.log" &
SERVER_PID=$!
for _ in $(seq 1 50); do
  [ -s "$WORK/port" ] && break
  sleep 0.1
done
PORT="$(cat "$WORK/port")"

START="$(date +%s)"
GHOSTTY_SHA=feedfacefeedfacefeedfacefeedfacefeedface \
GHOSTTYKIT_CHECKSUMS_FILE="$WORK/checksums.txt" \
GHOSTTYKIT_ARCHIVE_VALIDATOR="$WORK/validator.py" \
GHOSTTYKIT_URL="http://127.0.0.1:$PORT/GhosttyKit.xcframework.tar.gz" \
GHOSTTYKIT_DOWNLOAD_RETRY_DELAY=0 \
GHOSTTYKIT_DOWNLOAD_STALL_SECONDS=2 \
GHOSTTYKIT_DOWNLOAD_MAX_TIME=45 \
  "$ROOT_DIR/scripts/download-prebuilt-ghosttykit.sh" --verify-only >"$WORK/out.log" 2>&1 || {
    echo "FAIL: a stalled first connection must not fail the download"
    cat "$WORK/out.log"
    exit 1
  }
ELAPSED=$(( $(date +%s) - START ))

if [ "$ELAPSED" -ge 30 ]; then
  echo "FAIL: the stalled connection was held for ${ELAPSED}s instead of being dropped"
  exit 1
fi
if ! grep -Eq '^2 bytes=[1-9][0-9]*-' "$WORK/requests.log"; then
  echo "FAIL: the retry must resume from the bytes already received"
  cat "$WORK/requests.log"
  exit 1
fi

echo "PASS: a stalled GhosttyKit download is dropped, resumed, and still checksum verified"
