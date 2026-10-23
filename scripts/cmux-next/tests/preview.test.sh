#!/usr/bin/env bash
# Focused contract checks for the developer preview wrapper. These checks only
# inspect metadata and failure handling; they never start Vite, a native build,
# or a browser.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d)
state="$TMP/state"
cleanup() {
  local state_file pid
  state_file=$(find "$state" -name '*.state' -type f -print -quit 2>/dev/null || true)
  if [[ -n "$state_file" ]]; then
    pid=$(sed -n 's/^pid[[:space:]]*//p' "$state_file" | head -1 || true)
    [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
  fi
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
python3 - "$port_file" <<'PY' &
import http.server
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
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
echo "INDEX_URL=http://127.0.0.1:$port/"
wait "$server_pid"
FAKE
chmod +x "$TMP/fake-web.sh"
export TMP_FAKE_WEB_PORT_FILE="$TMP/port"
first_json=$(CMUX_PREVIEW_STATE_DIR="$state" CMUX_PREVIEW_WEB_DEV_SCRIPT="$TMP/fake-web.sh" \
  CMUX_PREVIEW_START_TIMEOUT=10 "$ROOT/scripts/cmux-next/preview.sh" web --json)
second_json=$(CMUX_PREVIEW_STATE_DIR="$state" CMUX_PREVIEW_WEB_DEV_SCRIPT="$TMP/fake-web.sh" \
  CMUX_PREVIEW_START_TIMEOUT=10 "$ROOT/scripts/cmux-next/preview.sh" web --json)
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

grep -q 'No native build is performed' <("$ROOT/scripts/cmux-next/preview.sh" --help)
# Entry links must use the gallery shell's hash-history contract. A query-only
# link silently redirects to the default composer and is a bad agent receipt.
grep -q 'gallery_result_url="\${gallery_result_url}#/' "$ROOT/scripts/cmux-next/preview.sh"
printf 'preview wrapper: ok\n'
