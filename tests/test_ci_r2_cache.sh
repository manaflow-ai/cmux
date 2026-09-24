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
import hashlib, http.server, os, sys, threading
store, ready = sys.argv[1], sys.argv[2]
os.makedirs(store, exist_ok=True)
metadata = {}
lock = threading.Lock()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def target(self): return os.path.join(store, self.path.lstrip("/"))
    def do_PUT(self):
        if "AWS4-HMAC-SHA256" not in self.headers.get("Authorization", ""):
            self.send_response(403); self.end_headers(); return
        body = self.rfile.read(int(self.headers["Content-Length"]))
        with lock:
            target = self.target()
            exists = os.path.isfile(target)
            etag = '"' + hashlib.md5(open(target, "rb").read()).hexdigest() + '"' if exists else None
            if (self.headers.get("If-None-Match") == "*" and exists) or (self.headers.get("If-Match") and self.headers["If-Match"] != etag):
                self.send_response(412); self.end_headers(); return
            # Deterministic fault injection exercises repair and CAS retries.
            if "/latest/" in target:
                for marker, code in [("fail-pointer", 403), ("race-pointer", 412)]:
                    control = os.path.join(store, marker)
                    if os.path.exists(control):
                        os.unlink(control)
                        self.send_response(code); self.end_headers(); return
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as out: out.write(body)
            metadata[target] = self.headers.get("x-amz-meta-generation", "0")
            self.send_response(200); self.end_headers()
    def serve(self, with_body):
        if not os.path.isfile(self.target()):
            self.send_response(404); self.end_headers(); return
        data = open(self.target(), "rb").read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("ETag", '"' + hashlib.md5(data).hexdigest() + '"')
        self.send_header("x-amz-meta-generation", metadata.get(self.target(), "0"))
        self.end_headers()
        if with_body: self.wfile.write(data)
    def do_GET(self): self.serve(True)
    def do_HEAD(self): self.serve(False)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(ready, "w") as out: out.write(str(server.server_address[1]))
server.serve_forever()
PY
SERVER_PID=$!
PORT="$(cat "$WORK/ready")"

export RUNNER_OS=TestOS RUNNER_ARCH=TestArch GITHUB_RUN_NUMBER=10
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

# Extra tar padding must be consumed so a successful extraction cannot send
# SIGPIPE to the decompressor under pipefail (notably with macOS bsdtar).
if command -v zstd >/dev/null 2>&1; then
  tar -cf "$WORK/padded.tar" -C "$WORK/src" .
  dd if=/dev/zero bs=1024 count=256 >> "$WORK/padded.tar" 2>/dev/null
  zstd -q "$WORK/padded.tar" -o "$NS/objects/padded-one.tar.zst"
  out="$(output_of restore "$WORK/dst" padded-one)"
  grep -q '^cache-hit=true$' <<<"$out" || fail "a padded archive must restore successfully"
  diff -r "$WORK/src" "$WORK/dst" >/dev/null || fail "padded archive contents differ"
  echo "PASS: padded archives restore without decompressor SIGPIPE"
fi

before="$(ls -l "$NS/objects/")"
output_of save "$WORK/src" family-tool-one >/dev/null
grep -q "already exists" "$WORK/log" || fail "saving an existing key must be skipped"
[[ "$before" == "$(ls -l "$NS/objects/")" ]] || fail "saving an existing key must not rewrite it"
echo "PASS: an existing key is not saved again"

# Retrying a save repairs a failed pointer without re-uploading its archive.
touch "$WORK/store/fail-pointer"
output_of save "$WORK/src" repair-one >/dev/null
[[ ! -f "$NS/latest/repair-" ]] || fail "the injected pointer failure did not occur"
output_of save "$WORK/src" repair-one >/dev/null
[[ "$(cat "$NS/latest/repair-")" == "repair-one" ]] || fail "an existing archive must repair a missing pointer"
echo "PASS: an existing archive repairs failed pointer publication"

# A later-finishing older run must not replace a newer run's pointer.
GITHUB_RUN_NUMBER=30 output_of save "$WORK/src" order-new >/dev/null
GITHUB_RUN_NUMBER=20 output_of save "$WORK/src" order-old >/dev/null
[[ "$(cat "$NS/latest/order-")" == "order-new" ]] || fail "an older run regressed a newer pointer"
# An existing object retains its original generation on a later retry.
GITHUB_RUN_NUMBER=40 output_of save "$WORK/src" order-old >/dev/null
[[ "$(cat "$NS/latest/order-")" == "order-new" ]] || fail "an old archive was promoted by a later retry"
echo "PASS: out-of-order saves cannot regress pointers"

touch "$WORK/store/race-pointer"
output_of save "$WORK/src" race-one >/dev/null
[[ "$(cat "$NS/latest/race-")" == "race-one" ]] || fail "a conditional write conflict must retry"
echo "PASS: conditional pointer conflicts retry"

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
