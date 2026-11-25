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

export RUNNER_OS=TestOS RUNNER_ARCH=TestArch GITHUB_RUN_ID=10
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

# A persistent nightly cache is linked into the workspace. A populated target
# must win over a remote seed, and an empty target may be seeded without
# unlinking the workspace path.
rm -rf "$WORK/persistent" "$WORK/linked"
mkdir -p "$WORK/persistent"
echo local > "$WORK/persistent/local.txt"
ln -s "$WORK/persistent" "$WORK/linked"
out="$(output_of restore "$WORK/linked" family-tool-one family-tool-)"
[[ "$out" == "cache-hit=false" ]] || fail "a populated cache symlink must not be replaced, got: $out"
[[ -L "$WORK/linked" && -f "$WORK/persistent/local.txt" ]] || fail "a populated cache symlink was removed"
rm -f "$WORK/persistent/local.txt"
out="$(output_of restore "$WORK/linked" family-tool-one family-tool-)"
grep -q '^cache-hit=true$' <<<"$out" || fail "an empty cache symlink must accept a remote seed, got: $out"
[[ -L "$WORK/linked" && -f "$WORK/persistent/a.txt" ]] || fail "a seeded cache symlink was replaced"
echo "PASS: R2 restore preserves and seeds persistent cache symlinks"

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
GITHUB_RUN_ID=30 output_of save "$WORK/src" order-new >/dev/null
GITHUB_RUN_ID=20 output_of save "$WORK/src" order-old >/dev/null
[[ "$(cat "$NS/latest/order-")" == "order-new" ]] || fail "an older run regressed a newer pointer"
# An existing object retains its original generation on a later retry.
GITHUB_RUN_ID=40 output_of save "$WORK/src" order-old >/dev/null
[[ "$(cat "$NS/latest/order-")" == "order-new" ]] || fail "an old archive was promoted by a later retry"
echo "PASS: out-of-order saves cannot regress pointers"

# Two workflows write the same prefix (nightly.yml and seed-derived-data.yml).
# Their run numbers are separate counters, so a newer seed from the younger
# workflow must still replace a pointer the older, higher-numbered one wrote.
GITHUB_RUN_NUMBER=5872 GITHUB_RUN_ID=35950000000 output_of save "$WORK/src" cross-nightly >/dev/null
GITHUB_RUN_NUMBER=38 GITHUB_RUN_ID=35960000000 output_of save "$WORK/src" cross-seeder >/dev/null
[[ "$(cat "$NS/latest/cross-")" == "cross-seeder" ]] || fail "a newer run of another workflow was ignored"
grep -q "pointer cross- names a newer save" "$WORK/log" && fail "the newer save reported itself as older"
GITHUB_RUN_NUMBER=5873 GITHUB_RUN_ID=35955000000 output_of save "$WORK/src" cross-late >/dev/null
[[ "$(cat "$NS/latest/cross-")" == "cross-seeder" ]] || fail "an older run of another workflow regressed the pointer"
grep -q "pointer cross- names a newer save" "$WORK/log" || fail "a pointer left in place must say so"
echo "PASS: pointers order saves across workflows"

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

# A platform-independent cache (web bundles a Linux job saves and a Mac
# restores) lives under one shared namespace, whatever runner wrote it.
rm -rf "$WORK/src" "$WORK/dst"; mkdir -p "$WORK/src"; echo shared > "$WORK/src/bundle.js"
CI_CACHE_R2_NAMESPACE=any output_of save "$WORK/src" shared-bundle-one >/dev/null || fail "a namespaced save must succeed"
ls "$WORK/store/bucket/v1/any/objects/shared-bundle-one.tar."* >/dev/null 2>&1 || fail "a namespaced save must land under v1/any"
out="$(RUNNER_OS=OtherOS RUNNER_ARCH=OtherArch CI_CACHE_R2_NAMESPACE=any output_of restore "$WORK/dst" shared-bundle-one)"
[[ "$out" == *"cache-hit=true"* && "$(cat "$WORK/dst/bundle.js")" == shared ]] || fail "another OS must restore the shared namespace, got: $out"
out="$(output_of restore "$WORK/dst2" shared-bundle-one)"
[[ "$out" == *"cache-hit=false"* ]] || fail "the runner namespace must not see the shared one, got: $out"
if CI_CACHE_R2_NAMESPACE='../x' output_of restore "$WORK/dst" shared-bundle-one >/dev/null; then fail "a namespace with a slash must be rejected"; fi
echo "PASS: CI_CACHE_R2_NAMESPACE shares one cache across runner platforms"

# The site's LAN cache host, through the mini's glaeda broker (a Unix socket): an archive comes from it
# first; its miss is the bucket's miss; any other answer falls through to the bucket.
lan_dir="$(mktemp -d /tmp/r2lan.XXXXXX)"
mkfifo "$WORK/lan-ready"
python3 - "$lan_dir/fetch.sock" "$WORK/lan-ready" "$WORK/lan-log" "$WORK/lan-src" <<'PY' &
import json, os, shutil, socket, sys
path, ready, log, src = sys.argv[1:]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path); server.listen(4)
open(ready, "w").write("ok")
while True:
    conn, _ = server.accept()
    request = json.loads(conn.makefile().readline())
    open(log, "a").write(json.dumps(request) + "\n")
    mode = open(os.path.join(src, "mode")).read().strip()
    if mode == "hit":
        shutil.copy(os.path.join(src, "archive"), request["dest"])
        answer = {"code": 0, "record": {"bytes": os.path.getsize(request["dest"]), "seconds": 0.1, "wait_seconds": 0}}
    elif mode == "miss":
        answer = {"code": 3, "record": {"reason": "not in the bucket"}}
    elif mode == "old":
        answer = {"code": 1, "record": {"tool": "glaeda-lan-fetch", "error": "bad request"}}
    else:
        answer = {"code": 1, "record": {"error": "host down"}}
    conn.sendall((json.dumps(answer) + "\n").encode()); conn.close()
PY
LAN_PID=$!
mkdir -p "$WORK/lan-src"
cat "$WORK/lan-ready" >/dev/null
rm -rf "$WORK/src" "$WORK/dst"; mkdir -p "$WORK/src"; echo lan > "$WORK/src/f.txt"
output_of save "$WORK/src" lan-one >/dev/null
lan_object="$(cd "$NS/objects" && ls lan-one.tar.*)"
mkdir -p "$WORK/lan-copy"; echo from-lan > "$WORK/lan-copy/f.txt"
if [[ "$lan_object" == *.tar.zst ]]; then tar -cf - -C "$WORK/lan-copy" . | zstd -q -o "$WORK/lan-src/archive"
else tar -czf "$WORK/lan-src/archive" -C "$WORK/lan-copy" .; fi
export CMUX_LAN_CACHE_SOCKET="$lan_dir/fetch.sock"
# lan_cache_fetch.py takes only an https bucket; the local test server is http, so pretend for it.
lan_shim="$WORK/shim"; mkdir -p "$lan_shim"
real_python="$(command -v python3)"  # resolved before the shim goes first on PATH
cat > "$lan_shim/python3" <<SH
#!/usr/bin/env bash
if [[ "\$1" == *lan_cache_fetch.py ]]; then set -- "\$1" "https://ci-cache.example" "\${@:3}"; fi
exec "$real_python" "\$@"
SH
chmod +x "$lan_shim/python3"
echo hit > "$WORK/lan-src/mode"
out="$(PATH="$lan_shim:$PATH" output_of restore "$WORK/dst" lan-one)"
[[ "$out" == *"cache-hit=true"* && "$(cat "$WORK/dst/f.txt")" == from-lan ]] || fail "a LAN hit must restore its copy, got: $out"
grep -q '"verb": "cache"' "$WORK/lan-log" && grep -q "\"file\": \"$lan_object\"" "$WORK/lan-log" || fail "the broker was not asked for the object"
echo down > "$WORK/lan-src/mode"; rm -rf "$WORK/dst"
out="$(PATH="$lan_shim:$PATH" output_of restore "$WORK/dst" lan-one)"
[[ "$out" == *"cache-hit=true"* && "$(cat "$WORK/dst/f.txt")" == lan ]] || fail "a down LAN host must fall back to the bucket, got: $out"
# A broker without the cache verb (an older glaeda) falls through to the bucket and warns, once per job.
echo old > "$WORK/lan-src/mode"; rm -rf "$WORK/dst"; warn_tmp="$(mktemp -d "$WORK/rt.XXXXXX")"
out="$(RUNNER_TEMP="$warn_tmp" PATH="$lan_shim:$PATH" output_of restore "$WORK/dst" lan-one)"
[[ "$out" == *"cache-hit=true"* && "$(cat "$WORK/dst/f.txt")" == lan ]] || fail "an old broker must fall back to the bucket, got: $out"
grep -q '^::warning title=LAN cache unused::' "$WORK/log" || fail "an old broker must warn, log: $(cat "$WORK/log")"
rm -rf "$WORK/dst"
out="$(RUNNER_TEMP="$warn_tmp" PATH="$lan_shim:$PATH" output_of restore "$WORK/dst" lan-one)"
[[ "$out" == *"cache-hit=true"* ]] || fail "a second old-broker restore must still hit the bucket, got: $out"
grep -q '::warning' "$WORK/log" && fail "the old-broker warning must show once per job, log: $(cat "$WORK/log")"
echo miss > "$WORK/lan-src/mode"; rm -rf "$WORK/dst"
out="$(PATH="$lan_shim:$PATH" output_of restore "$WORK/dst" lan-one)"
[[ "$out" == "cache-hit=false" ]] || fail "the LAN host's miss is the bucket's miss, got: $out"
kill "$LAN_PID" 2>/dev/null || true; wait "$LAN_PID" 2>/dev/null || true
rm -rf "$lan_dir"; unset CMUX_LAN_CACHE_SOCKET
echo "PASS: archives come from the LAN cache host first and fall back to the bucket"

unset AWS_SECRET_ACCESS_KEY
output_of save "$WORK/src" family-tool-four >/dev/null || fail "a save without credentials must not fail the job"
ls "$NS/objects/" | grep -q '^family-tool-four' && fail "a save without credentials must upload nothing"
echo "PASS: a save without credentials warns and uploads nothing"
