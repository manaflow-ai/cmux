#!/usr/bin/env bash
# The web pieces switch file (scripts/cmux-next/web-pieces-file.py and web-pieces-publish.sh,
# cmux-tui/crates/cmux-web-pieces): the publish step continues the published file's serial,
# keeps its switches, refuses names that are no piece, and never continues a file that no
# pinned key covers. Needs openssl 3 (ed25519 with pkeyutl -rawin).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PTR="$ROOT/scripts/cmux-next/web-ota-pointer.py"
FILE="$ROOT/scripts/cmux-next/web-pieces-file.py"
PUBLISH="$ROOT/scripts/cmux-next/web-pieces-publish.sh"
TMP=$(mktemp -d)
SERVER=
FORBID=
trap '[[ -z "$SERVER" ]] || kill "$SERVER" 2>/dev/null || true; [[ -z "$FORBID" ]] || kill "$FORBID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$@" >&2; exit 1; }

# The script's pieces are the crate's.
crate=$(sed -n '/^pub const PIECES/,/^];/p' "$ROOT/cmux-tui/crates/cmux-web-pieces/src/lib.rs" \
  | grep -o '^ *(\?"[a-z-]*",\|^ *"[a-z-]*",$' | grep -o '[a-z-]\+' | tr '\n' ' ')
[[ "$crate" == "$(python3 "$FILE" pieces | tr '\n' ' ')" ]] || fail "web-pieces-file.py PIECES differ from the crate's: $crate"

keyfile() { # PEM OUT
  python3 - "$1" "$2" <<'PY'
import base64, hashlib, json, subprocess, sys
der = subprocess.run(["openssl", "pkey", "-in", sys.argv[1], "-pubout", "-outform", "DER"], capture_output=True, check=True).stdout
raw = der[-32:]
json.dump({"keys": [{"id": hashlib.sha256(raw).hexdigest()[:16], "ed25519": base64.b64encode(raw).decode()}]}, open(sys.argv[2], "w"))
PY
}
openssl genpkey -algorithm ed25519 -out "$TMP/a.pem" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "$TMP/b.pem" 2>/dev/null
keyfile "$TMP/a.pem" "$TMP/keys-a.json"
keyfile "$TMP/b.pem" "$TMP/keys-b.json"
mkdir "$TMP/site" "$TMP/work"
field() { # FILE EXPR: a Python expression over the verified payload `v`
  python3 "$PTR" verify --pointer "$1" --keys "$TMP/keys-a.json" --channel every-merge --purpose cmux-web-pieces --allow-expired \
    | python3 -c "import json,sys; v=json.load(sys.stdin); print($2)"
}
# A folder served over HTTP stands in for files.cmux.com.
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$TMP/site" >"$TMP/server.log" 2>&1 &
SERVER=$!
port=
for _ in $(seq 1 100); do
  port=$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$TMP/server.log" | head -1)
  [[ -n "$port" ]] && break
  sleep 0.1
done
[[ -n "$port" ]] || fail "the test server did not start"
publish() { # ENV...: one dry run
  env CHANNEL=every-merge WEB_PIECES_BASE="http://127.0.0.1:$port" WEB_PIECES_KEYS="$TMP/keys-a.json" WEB_PIECES_DRY_RUN=1 \
    "$@" "$PUBLISH" "$TMP/work" "$TMP/a.pem"
}
take() { cp "$TMP/work/pieces-every-merge.json" "$TMP/site/pieces-every-merge.json"; }
key=$(printf 'x%.0s' {1..64} | tr x a)

# No file yet: the channel's first is serial 1.
publish OUT_OF="agent-pane=last-good" REASON="blank pane" >/dev/null
take
[[ "$(field "$TMP/site/pieces-every-merge.json" 'v["serial"], v["pieces"]["agent-pane"]["serve"], v["pieces"]["agent-pane"]["reason"]')" == "1 last-good blank pane" ]] \
  || fail "the first file is not serial 1 with its switch"
# A place that cannot be read is not "no file": the serial is never guessed.
env CHANNEL=every-merge WEB_PIECES_BASE="http://127.0.0.1:1" WEB_PIECES_KEYS="$TMP/keys-a.json" WEB_PIECES_DRY_RUN=1 \
  "$PUBLISH" "$TMP/work" "$TMP/a.pem" >/dev/null 2>&1 && fail "an unreadable published file was taken as none"
# A 403 is not "no file" either: only a 404 starts the serial at 1.
python3 -u -c '
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(403); self.send_header("Content-Length", "0"); self.end_headers()
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print("port", s.server_address[1], flush=True)
s.serve_forever()
' >"$TMP/forbid.log" 2>&1 &
FORBID=$!
fport=
for _ in $(seq 1 100); do
  fport=$(sed -n 's/^port \([0-9]*\).*/\1/p' "$TMP/forbid.log" | head -1)
  [[ -n "$fport" ]] && break
  sleep 0.1
done
[[ -n "$fport" ]] || fail "the 403 test server did not start"
env CHANNEL=every-merge WEB_PIECES_BASE="http://127.0.0.1:$fport" WEB_PIECES_KEYS="$TMP/keys-a.json" WEB_PIECES_DRY_RUN=1 \
  "$PUBLISH" "$TMP/work" "$TMP/a.pem" >/dev/null 2>&1 && fail "a 403 for the published file was taken as none"
kill "$FORBID" 2>/dev/null || true

# The next file continues the serial and keeps the switch it was not asked to change.
publish OUT_OF="pages/settings=bundled" REASON="blank settings" REFUSE="$key" >/dev/null
take
[[ "$(field "$TMP/site/pieces-every-merge.json" 'v["serial"], sorted(v["pieces"]), v["pieces"]["pages/settings"]["reason"], len(v["refuse"])')" \
  == "2 ['agent-pane', 'pages/settings'] blank settings 1" ]] || fail "the second file lost a switch or its serial"

# Live again: the piece leaves the file; the refuse list stays until allowed.
publish LIVE="agent-pane" ALLOW="$key" >/dev/null
take
[[ "$(field "$TMP/site/pieces-every-merge.json" 'v["serial"], sorted(v["pieces"]), v["refuse"]')" == "3 ['pages/settings'] []" ]] \
  || fail "live again did not remove the piece"
publish ALL_LIVE=true >/dev/null
[[ "$(field "$TMP/work/pieces-every-merge.json" 'v["serial"], v["pieces"]')" == "4 {}" ]] || fail "all live left a switch"

# Refused: a name that is no piece, a serve that is none, a key that is none, a piece that is live.
publish OUT_OF="composer=bundled" >/dev/null 2>&1 && fail "a name that is no piece was switched"
publish OUT_OF="pages-later=bundled" >/dev/null 2>&1 && fail "a name that only starts like a piece was switched"
publish OUT_OF="pages=gone" >/dev/null 2>&1 && fail "an unknown serve was taken"
publish REFUSE="abc" >/dev/null 2>&1 && fail "a refuse entry that is no key was taken"
publish LIVE="inspector" >/dev/null 2>&1 && fail "a live piece was made live"
python3 "$FILE" payload --channel stable --out "$TMP/x" >/dev/null 2>&1 && fail "a channel without web updates got a switch file"

# A published file another key signed is never continued, and nor is a web update pointer.
python3 "$FILE" payload --channel every-merge --out "$TMP/p1" --out-of "agent-pane=bundled" >/dev/null
python3 "$PTR" sign --payload "$TMP/p1" --key "$TMP/b.pem" --keys "$TMP/keys-b.json" --out "$TMP/site/pieces-every-merge.json"
publish OUT_OF="pages=bundled" >/dev/null 2>&1 && fail "a file signed by an unlisted key was continued"
printf '{"schema":1,"channel":"every-merge","key":"%s","committed_at":1}' "$key" >"$TMP/ptr"
python3 "$PTR" sign --payload "$TMP/ptr" --key "$TMP/a.pem" --keys "$TMP/keys-a.json" --out "$TMP/site/pieces-every-merge.json"
publish OUT_OF="pages=bundled" >/dev/null 2>&1 && fail "a web update pointer was continued as a switch file"
echo "ok: web pieces switch file"
