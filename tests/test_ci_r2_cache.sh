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
    # Like the public bucket, the query string names no object.
    def target(self): return os.path.join(store, self.path.split("?", 1)[0].lstrip("/"))
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

# DerivedData seeds and compilation caches repeat content far apart (module
# copies, duplicated objects). Saves use a 128 MiB window (--long=27), which
# shrank real seeds by 27% and the compilation cache by 33%, and which a plain
# `zstd -d` still reads without --long or --memory.
if command -v zstd >/dev/null 2>&1; then
  mkdir -p "$WORK/far/x"
  head -c 6000000 /dev/urandom > "$WORK/far/a.bin"
  head -c 4000000 /dev/urandom > "$WORK/far/x/gap.bin"
  cp "$WORK/far/a.bin" "$WORK/far/x/z.bin"
  output_of save "$WORK/far" far-one >/dev/null
  size="$(wc -c < "$NS/objects/far-one.tar.zst")"
  (( size < 11000000 )) || fail "repeats 10 MB apart must compress once, archive is $size bytes"
  zstd -q -t "$NS/objects/far-one.tar.zst" || fail "a plain zstd must read the long-window archive"
  rm -rf "$WORK/dst"
  out="$(output_of restore "$WORK/dst" far-one)"
  grep -q '^cache-hit=true$' <<<"$out" || fail "a long-window archive must restore, got: $out"
  diff -r "$WORK/far" "$WORK/dst" >/dev/null || fail "long-window archive contents differ"
  echo "PASS: saves find repeats beyond the default window and restore with plain zstd"
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

# `pack` then `publish` is `save` split across two jobs, so the job that builds
# a cache holds no credentials (seed-derived-data-pool.yml). Pack writes what
# save would upload, with no credentials; publish uploads it under the
# packer's namespace, even from another OS.
NS_MAC="$WORK/store/bucket/v1/macOS-ARM64"
: > "$WORK/packout"
env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u CI_CACHE_R2_ENDPOINT -u CI_CACHE_R2_BUCKET \
  RUNNER_OS=macOS RUNNER_ARCH=ARM64 GITHUB_OUTPUT="$WORK/packout" bash "$SCRIPT" pack "$WORK/src" split-tool-one "$WORK/packed" >"$WORK/log" 2>&1 \
  || fail "pack must not need credentials"
ls "$WORK/packed" | grep -q '^split-tool-one\.tar\.' || fail "pack must leave the archive save would upload"
grep -qx 'namespace=v1/macOS-ARM64' "$WORK/packed/split-tool-one.packed" || fail "pack must record the packer's namespace"
[[ ! -e "$NS_MAC/objects" ]] || fail "pack must upload nothing"
# The digest the build hands the save job through its job outputs.
digest="$(sed -n 's/^sha256=//p' "$WORK/packout")"
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "pack must output the sha256 of what it packed, got: $digest"
RUNNER_OS=Linux RUNNER_ARCH=X64 GITHUB_RUN_ID=50 output_of publish "$WORK/packed" split-tool-one "$digest" >/dev/null
ls "$NS_MAC/objects/" | grep -q '^split-tool-one\.tar\.' || fail "publish must upload under the packer's namespace"
[[ "$(cat "$NS_MAC/latest/split-")" == "split-tool-one" && "$(cat "$NS_MAC/latest/split-tool-")" == "split-tool-one" ]] \
  || fail "publish must write one pointer per dash-terminated prefix, as save does"
rm -rf "$WORK/dst"
out="$(RUNNER_OS=macOS RUNNER_ARCH=ARM64 output_of restore "$WORK/dst" split-tool-one)"
grep -q '^cache-hit=true$' <<<"$out" || fail "a published key must restore, got: $out"
diff -r "$WORK/src" "$WORK/dst" >/dev/null || fail "published contents differ"
echo "PASS: pack needs no credentials and publish uploads it as save would"

# An already published key packs nothing; publish still repairs its pointers.
rm -f "$NS_MAC/latest/split-tool-"
out="$(RUNNER_OS=macOS RUNNER_ARCH=ARM64 output_of pack "$WORK/src" split-tool-one "$WORK/packed2")"
grep -q "already exists; not packing" "$WORK/log" || fail "pack must skip a key the public URL serves"
ls "$WORK/packed2" | grep -q '\.tar\.' && fail "pack must not archive a published key"
digest2="$(sed -n 's/^sha256=//p' <<<"$out")"
[[ "$digest2" =~ ^[0-9a-f]{64}$ ]] || fail "pack must output a sha256 for a record alone too"
before="$(ls -l "$NS_MAC/objects/")"
RUNNER_OS=Linux RUNNER_ARCH=X64 output_of publish "$WORK/packed2" split-tool-one "$digest2" >/dev/null
[[ "$before" == "$(ls -l "$NS_MAC/objects/")" ]] || fail "publishing a published key must not rewrite it"
[[ "$(cat "$NS_MAC/latest/split-tool-")" == "split-tool-one" ]] || fail "publish must repair a published key's pointer"
echo "PASS: a published key is not packed again and publish repairs its pointers"

# A refusal fails the step, and uploads nothing.
refuses() { if output_of "$@" >/dev/null; then fail "publish must fail when it refuses: $*"; fi; }

# Publish uploads only the key the caller names, and only a well-formed record.
RUNNER_OS=Linux RUNNER_ARCH=X64 refuses publish "$WORK/packed" split-tool-other "$digest"
grep -q "nothing was packed for split-tool-other" "$WORK/log" || fail "publish must refuse a key that was not packed"
ls "$NS_MAC/objects/" | grep -q '^split-tool-other' && fail "publish uploaded a key that was not packed"
cp -R "$WORK/packed" "$WORK/forged"
printf 'namespace=v1/../../x\nextension=tar.zst\n' > "$WORK/forged/split-tool-one.packed"
RUNNER_OS=Linux RUNNER_ARCH=X64 refuses publish "$WORK/forged" split-tool-one "$digest"
grep -q "is not a pack record\|does not match" "$WORK/log" || fail "publish must refuse a record with another namespace shape"
env -u AWS_SECRET_ACCESS_KEY RUNNER_OS=Linux RUNNER_ARCH=X64 bash "$SCRIPT" publish "$WORK/packed" split-tool-one "$digest" >"$WORK/log" 2>&1 \
  || fail "a publish without credentials must not fail the job"
grep -q "AWS_SECRET_ACCESS_KEY is not set" "$WORK/log" || fail "a publish without credentials must say so"
echo "PASS: publish uploads only the packed key, a well-formed record, and with credentials"

# The save job publishes only the bytes the build packed: any other archive or
# record under that name (an artifact another job overwrote) has another digest.
mkdir -p "$WORK/swapped"
cp "$WORK/packed/split-tool-one.packed" "$WORK/swapped/"
for archive in "$WORK"/packed/split-tool-one.tar.*; do
  { cat "$archive"; printf 'tampered'; } > "$WORK/swapped/${archive##*/}"
done
before="$(ls -l "$NS_MAC/objects/" "$NS_MAC/latest/")"
RUNNER_OS=Linux RUNNER_ARCH=X64 GITHUB_RUN_ID=60 refuses publish "$WORK/swapped" split-tool-one "$digest"
grep -q "does not match what was packed" "$WORK/log" || fail "publish must name a digest mismatch"
[[ "$before" == "$(ls -l "$NS_MAC/objects/" "$NS_MAC/latest/")" ]] || fail "publish touched the bucket for bytes the build did not pack"
cp "$WORK"/packed/split-tool-one.* "$WORK/swapped/" 2>/dev/null
for name in "$WORK"/swapped/split-tool-one.*; do mv "$name" "${name/split-tool-one/split-tool-swap}"; done
RUNNER_OS=Linux RUNNER_ARCH=X64 GITHUB_RUN_ID=60 refuses publish "$WORK/swapped" split-tool-swap "0000000000000000000000000000000000000000000000000000000000000000"
grep -q "does not match" "$WORK/log" || fail "publish must refuse a digest that does not match"
ls "$NS_MAC/objects/" | grep -q '^split-tool-swap' && fail "publish uploaded under a mismatched digest"
RUNNER_OS=Linux RUNNER_ARCH=X64 refuses publish "$WORK/swapped" split-tool-swap
grep -q "usage" "$WORK/log" || fail "publish without a digest must refuse"
ls "$NS_MAC/objects/" | grep -q '^split-tool-swap' && fail "publish uploaded with no digest"
echo "PASS: publish refuses an archive or digest the build did not hand over"

# Only macOS caches go through pack and publish: a record naming any other
# namespace is refused, even one of the right shape.
mkdir -p "$WORK/linux"
: > "$WORK/linuxout"
RUNNER_OS=Linux RUNNER_ARCH=X64 GITHUB_OUTPUT="$WORK/linuxout" bash "$SCRIPT" pack "$WORK/src" split-tool-linux "$WORK/linux" >/dev/null 2>&1
linux_digest="$(sed -n 's/^sha256=//p' "$WORK/linuxout")"
[[ "$linux_digest" =~ ^[0-9a-f]{64}$ ]] || fail "pack must output a digest on any OS"
RUNNER_OS=Linux RUNNER_ARCH=X64 refuses publish "$WORK/linux" split-tool-linux "$linux_digest"
grep -q "is not a pack record" "$WORK/log" || fail "publish must refuse a namespace other than v1/macOS-ARM64 or v1/macOS-X64"
[[ ! -e "$WORK/store/bucket/v1/Linux-X64/objects" ]] || fail "publish uploaded a non-macOS namespace"
echo "PASS: publish pins the namespace to v1/macOS-(ARM64|X64)"

unset AWS_SECRET_ACCESS_KEY
output_of save "$WORK/src" family-tool-four >/dev/null || fail "a save without credentials must not fail the job"
ls "$NS/objects/" | grep -q '^family-tool-four' && fail "a save without credentials must upload nothing"
echo "PASS: a save without credentials warns and uploads nothing"
