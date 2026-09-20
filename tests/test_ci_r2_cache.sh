#!/usr/bin/env bash
# Exercises scripts/ci/r2-cache.sh against a local object server: save, exact
# restore, prefix restore, misses, and the failure paths that must stay misses.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci/r2-cache.sh"
WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

mkfifo "$WORK/ready"
python3 - "$WORK/store" "$WORK/ready" <<'PY' &
import http.server, os, sys
store, ready = sys.argv[1], sys.argv[2]
os.makedirs(store, exist_ok=True)
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def target(self): return os.path.join(store, self.path.lstrip("/"))
    def do_PUT(self):
        if "AWS4-HMAC-SHA256" not in self.headers.get("Authorization", ""):
            self.send_response(403); self.end_headers(); return
        body = self.rfile.read(int(self.headers["Content-Length"]))
        os.makedirs(os.path.dirname(self.target()), exist_ok=True)
        with open(self.target(), "wb") as out: out.write(body)
        self.send_response(200); self.end_headers()
    def serve(self, with_body):
        if not os.path.isfile(self.target()):
            self.send_response(404); self.end_headers(); return
        data = open(self.target(), "rb").read()
        self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers()
        if with_body: self.wfile.write(data)
    def do_GET(self): self.serve(True)
    def do_HEAD(self): self.serve(False)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(ready, "w") as out: out.write(str(server.server_address[1]))
server.serve_forever()
PY
SERVER_PID=$!
PORT="$(cat "$WORK/ready")"

export RUNNER_OS=TestOS RUNNER_ARCH=TestArch
export CI_CACHE_R2_PUBLIC_URL="http://127.0.0.1:$PORT/bucket"
export CI_CACHE_R2_ENDPOINT="http://127.0.0.1:$PORT"
export CI_CACHE_R2_BUCKET="bucket"
export AWS_ACCESS_KEY_ID="test-id" AWS_SECRET_ACCESS_KEY="test-secret"
NS="$WORK/store/bucket/v1/TestOS-TestArch"

fail() { echo "FAIL: $1"; exit 1; }
output_of() { GITHUB_OUTPUT="$WORK/out" bash "$SCRIPT" "$@" >"$WORK/log" 2>&1; local rc=$?; cat "$WORK/out" 2>/dev/null; : > "$WORK/out"; return $rc; }

mkdir -p "$WORK/src/nested"
echo alpha > "$WORK/src/a.txt"
echo beta > "$WORK/src/nested/b.txt"

out="$(output_of restore "$WORK/dst" spm-one spm-)"
[[ "$out" == "cache-hit=false" ]] || fail "an empty store must be a miss, got: $out"
[[ ! -e "$WORK/dst" ]] || fail "a miss must not create the directory"
echo "PASS: an empty store is a miss"

output_of save "$WORK/src" family-tool-one >/dev/null
ls "$NS/objects/" | grep -q '^family-tool-one\.tar\.' || fail "save did not upload the object"
[[ "$(cat "$NS/latest/family-")" == "family-tool-one" && "$(cat "$NS/latest/family-tool-")" == "family-tool-one" ]] \
  || fail "save must write one pointer per dash-terminated prefix"
echo "PASS: save uploads the archive and its prefix pointers"

out="$(output_of restore "$WORK/dst" family-tool-one family-tool-)"
grep -q '^cache-hit=true$' <<<"$out" || fail "an exact key must report a hit, got: $out"
diff -r "$WORK/src" "$WORK/dst" >/dev/null || fail "restored contents differ"
echo "PASS: an exact key restores the same files and reports a hit"

rm -rf "$WORK/dst"
out="$(output_of restore "$WORK/dst" family-tool-two family-tool-)"
grep -q '^cache-hit=false$' <<<"$out" || fail "a prefix match is not an exact hit, got: $out"
grep -q '^cache-matched-key=family-tool-one$' <<<"$out" || fail "a prefix match must name the key it restored, got: $out"
diff -r "$WORK/src" "$WORK/dst" >/dev/null || fail "prefix-restored contents differ"
echo "PASS: a prefix restores the newest key without claiming an exact hit"

before="$(ls -l "$NS/objects/")"
output_of save "$WORK/src" family-tool-one >/dev/null
grep -q "already exists" "$WORK/log" || fail "saving an existing key must be skipped"
[[ "$before" == "$(ls -l "$NS/objects/")" ]] || fail "saving an existing key must not rewrite it"
echo "PASS: an existing key is not saved again"

echo "other-thing" > "$NS/latest/family-tool-"
rm -rf "$WORK/dst"
out="$(output_of restore "$WORK/dst" family-tool-three family-tool-)"
[[ "$out" == "cache-hit=false" && ! -e "$WORK/dst" ]] || fail "a pointer outside its prefix must be ignored, got: $out"
echo "PASS: a pointer that names a key outside its prefix is ignored"

for object in "$NS"/objects/family-tool-one.tar.*; do echo "not an archive" > "$object"; done
echo "family-tool-one" > "$NS/latest/family-tool-"
out="$(output_of restore "$WORK/dst" family-tool-one family-tool-)" || fail "a corrupt archive must not fail the job"
[[ "$out" == "cache-hit=false" && ! -e "$WORK/dst" ]] || fail "a corrupt archive must be a clean miss, got: $out"
echo "PASS: a corrupt archive is a miss and leaves no partial directory"

if output_of restore "$WORK/dst" 'bad/key' >/dev/null; then fail "a key with a slash must be rejected"; fi
echo "PASS: keys outside [A-Za-z0-9._-] are rejected"

unset AWS_SECRET_ACCESS_KEY
output_of save "$WORK/src" family-tool-four >/dev/null || fail "a save without credentials must not fail the job"
ls "$NS/objects/" | grep -q '^family-tool-four' && fail "a save without credentials must upload nothing"
echo "PASS: a save without credentials warns and uploads nothing"
