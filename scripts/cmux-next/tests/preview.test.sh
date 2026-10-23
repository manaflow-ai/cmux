#!/usr/bin/env bash
# Focused contract checks for the developer preview wrapper. These checks only
# inspect metadata and failure handling; they never start Vite, a native build,
# or a browser.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d)
state="$TMP/state"
foreign_gallery_pid=""
foreign_index_pid=""
cleanup() {
  local state_file pid
  [[ -z "$foreign_gallery_pid" ]] || kill "$foreign_gallery_pid" 2>/dev/null || true
  [[ -z "$foreign_index_pid" ]] || kill "$foreign_index_pid" 2>/dev/null || true
  while IFS= read -r state_file; do
    pid=$(sed -n 's/^pid[[:space:]]*//p' "$state_file" | head -1 || true)
    [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
  done < <(find "$TMP" -name '*.state' -type f -print 2>/dev/null || true)
  rm -rf "$TMP"
}
trap cleanup EXIT

bash -n "$ROOT/scripts/cmux-next/preview.sh"

sha=$(git -C "$ROOT" rev-parse HEAD)
set +e
status_json=$(CMUX_PREVIEW_STATE_DIR="$state" "$ROOT/scripts/cmux-next/preview.sh" status --json 2>"$TMP/status.err")
status_rc=$?
missing_json=$(CMUX_PREVIEW_STATE_DIR="$state" CMUX_PREVIEW_WEB_DEV_SCRIPT="$TMP/missing" \
  "$ROOT/scripts/cmux-next/preview.sh" web --json 2>"$TMP/web.err")
missing_rc=$?
set -e
[[ "$status_rc" -eq 1 ]] || { echo "preview status should fail when stopped (rc=$status_rc)" >&2; exit 1; }
[[ "$missing_rc" -eq 1 ]] || { echo "preview web should fail for a missing helper (rc=$missing_rc)" >&2; exit 1; }

python3 - "$status_json" "$missing_json" "$sha" <<'PY'
import json
import sys

status = json.loads(sys.argv[1])
missing = json.loads(sys.argv[2])
sha = sys.argv[3]
assert status["ok"] is False
assert status["mode"] == "status"
assert status["sha"] == sha
assert "no preview state" in status["error"]
assert missing["ok"] is False
assert missing["mode"] == "web"
assert missing["sha"] == sha
assert "web helper is missing" in missing["error"]
assert missing["index_url"] is None
PY

# A tiny local helper proves the start/reuse path without Vite, a native build,
# or a browser. Its HTTP server binds an ephemeral loopback port.
cat > "$TMP/fake-web.sh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
port_file="${TMP_FAKE_WEB_PORT_FILE:?}"
token="${TMP_FAKE_WEB_INDEX_TOKEN:-fake-preview-token}"
python3 - "$port_file" "$token" <<'PY' &
import http.server
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
token = sys.argv[2]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(f"<meta name=cmux-preview-token content={token}>".encode())
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
path.write_text(str(server.server_port))
server.serve_forever()
PY
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT INT TERM
for _ in $(seq 1 50); do
  [[ -s "$port_file" ]] && break
  sleep 0.1
done
port=$(cat "$port_file")
echo "INDEX_TOKEN=$token"
if [[ "${TMP_FAKE_WEB_PUBLISH_GALLERY:-0}" == 1 ]]; then echo "GALLERY_URL=http://127.0.0.1:$port/"; fi
echo "INDEX_URL=http://127.0.0.1:$port/"
wait "$server_pid"
FAKE
chmod +x "$TMP/fake-web.sh"
export TMP_FAKE_WEB_PORT_FILE="$TMP/port"
first_json=$(CMUX_PREVIEW_STATE_DIR="$state" CMUX_PREVIEW_WEB_DEV_SCRIPT="$TMP/fake-web.sh" \
  TMP_FAKE_WEB_INDEX_TOKEN=first-preview-token CMUX_PREVIEW_START_TIMEOUT=10 "$ROOT/scripts/cmux-next/preview.sh" web --json)
second_json=$(CMUX_PREVIEW_STATE_DIR="$state" CMUX_PREVIEW_WEB_DEV_SCRIPT="$TMP/fake-web.sh" \
  TMP_FAKE_WEB_INDEX_TOKEN=first-preview-token CMUX_PREVIEW_START_TIMEOUT=10 "$ROOT/scripts/cmux-next/preview.sh" web --json)
python3 - "$first_json" "$second_json" "$sha" <<'PY'
import json
import sys

first, second, sha = json.loads(sys.argv[1]), json.loads(sys.argv[2]), sys.argv[3]
assert first["ok"] is True
assert first["sha"] == sha
assert first["reused"] is False
assert first["index_url"].startswith("http://127.0.0.1:")
assert second["ok"] is True
assert second["reused"] is True
assert second["pid"] == first["pid"]
assert second["index_url"] == first["index_url"]
PY

# A gallery from another checkout must not become this preview's gallery merely
# because it answers on the configured port. This helper publishes only an index.
python3 - "$TMP/foreign-gallery-port" <<'PY' &
import http.server
import pathlib
import sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"another checkout's gallery")

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
PY
foreign_gallery_pid=$!
for _ in $(seq 1 50); do
  [[ -s "$TMP/foreign-gallery-port" ]] && break
  sleep 0.1
done
foreign_gallery_port=$(cat "$TMP/foreign-gallery-port")

# A foreign index on the fixed index port must not satisfy a helper that merely
# echoes INDEX_URL while its own index server failed to bind.
python3 - "$TMP/foreign-index-port" <<'PY' &
import http.server
import pathlib
import sys

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
PY
foreign_index_pid=$!
for _ in $(seq 1 50); do
  [[ -s "$TMP/foreign-index-port" ]] && break
  sleep 0.1
done
foreign_index_port=$(cat "$TMP/foreign-index-port")
cat > "$TMP/foreign-index-helper.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "INDEX_URL=http://127.0.0.1:$foreign_index_port/"
while :; do sleep 1; done
EOF
chmod +x "$TMP/foreign-index-helper.sh"
set +e
foreign_index_json=$(CMUX_PREVIEW_STATE_DIR="$TMP/index-collision-state" \
  CMUX_PREVIEW_WEB_DEV_SCRIPT="$TMP/foreign-index-helper.sh" CMUX_PREVIEW_START_TIMEOUT=1 \
  "$ROOT/scripts/cmux-next/preview.sh" web --json)
foreign_index_rc=$?
set -e
[[ "$foreign_index_rc" -eq 1 ]] || { echo "preview must refuse a foreign index" >&2; exit 1; }
python3 - "$foreign_index_json" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
assert result["ok"] is False
assert "INDEX_URL" in result["error"] or "readiness" in result["error"]
PY

set +e
foreign_gallery_json=$(CMUX_PREVIEW_STATE_DIR="$state" CMUX_PREVIEW_WEB_DEV_SCRIPT="$TMP/fake-web.sh" \
  CMUX_WEB_DEV_GALLERY_PORT="$foreign_gallery_port" "$ROOT/scripts/cmux-next/preview.sh" gallery --json)
foreign_gallery_rc=$?
set -e
[[ "$foreign_gallery_rc" -eq 1 ]] || { echo "preview must refuse a gallery the helper did not publish" >&2; exit 1; }
python3 - "$foreign_gallery_json" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
assert result["ok"] is False
assert "live gallery is unavailable" in result["error"]
assert result["gallery_url"] is None
PY

# A helper-published gallery is accepted even while the configured port belongs
# to that other server. The URL must come from the managed helper's readiness.
published_json=$(CMUX_PREVIEW_STATE_DIR="$TMP/published-state" CMUX_PREVIEW_WEB_DEV_SCRIPT="$TMP/fake-web.sh" \
  TMP_FAKE_WEB_PORT_FILE="$TMP/published-port" TMP_FAKE_WEB_INDEX_TOKEN=published-preview-token TMP_FAKE_WEB_PUBLISH_GALLERY=1 \
  CMUX_WEB_DEV_GALLERY_PORT="$foreign_gallery_port" CMUX_PREVIEW_START_TIMEOUT=10 \
  "$ROOT/scripts/cmux-next/preview.sh" gallery --json)
python3 - "$published_json" "$foreign_gallery_port" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
assert result["ok"] is True
assert result["gallery_url"] == result["index_url"]
assert result["gallery_url"] != f"http://127.0.0.1:{sys.argv[2]}/gallery/"
PY

grep -q 'No native build is performed' <("$ROOT/scripts/cmux-next/preview.sh" --help)
# Entry links must use the gallery shell's hash-history contract. A query-only
# link silently redirects to the default composer and is a bad agent receipt.
grep -q 'gallery_result_url="\${gallery_result_url}#/' "$ROOT/scripts/cmux-next/preview.sh"
printf 'preview wrapper: ok\n'
