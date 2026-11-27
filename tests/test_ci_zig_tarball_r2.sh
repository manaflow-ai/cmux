#!/usr/bin/env bash
# scripts/ci/zig-tarball-r2.sh restore fills an empty Zig tarball directory from the CI cache bucket, so a
# fresh runner (Freestyle) skips the third-party Zig mirrors: job 137551791655 spent its whole 480 s Zig
# budget on them and failed. A miss, an unreachable bucket or a populated directory is never an error.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/ci/zig-tarball-r2.sh"
TMP="$(mktemp -d)"
server_pid=""
cleanup() { [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

hash="$(sha256sum "$ROOT/scripts/ci/zig-tarballs.sha256" | cut -c1-16)"
key="zig-tarballs-v1-$hash"
mkdir -p "$TMP/bucket/v1/Linux-X64/objects" "$TMP/src"
echo tarball > "$TMP/src/zig-x86_64-linux-0.0.0.tar.xz"
tar -czf "$TMP/bucket/v1/Linux-X64/objects/$key.tar.gz" -C "$TMP/src" .

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$TMP/bucket" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 50); do curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 0.1; done
export RUNNER_OS=Linux RUNNER_ARCH=X64 PATH="/usr/bin:/bin:$PATH" CMUX_LAN_CACHE_SOCKET="$TMP/none.sock"

# A hit fills the empty directory.
out="$(ZIG_TARBALL_R2_URL="http://127.0.0.1:$port" bash "$SCRIPT" restore "$TMP/hit")"
[[ -f "$TMP/hit/zig-x86_64-linux-0.0.0.tar.xz" ]] || fail "restore left no tarball: $out"
grep -q "restored $key" <<<"$out" || fail "restore did not say it restored: $out"

# A populated directory is kept as it is.
mkdir -p "$TMP/full"; echo mine > "$TMP/full/own.tar.xz"
out="$(ZIG_TARBALL_R2_URL="http://127.0.0.1:$port" bash "$SCRIPT" restore "$TMP/full")"
[[ ! -e "$TMP/full/zig-x86_64-linux-0.0.0.tar.xz" && "$(cat "$TMP/full/own.tar.xz")" == mine ]] || fail "restore replaced a populated directory"

# Another namespace (another OS or arch) is a miss, exit 0.
out="$(RUNNER_ARCH=ARM64 ZIG_TARBALL_R2_URL="http://127.0.0.1:$port" bash "$SCRIPT" restore "$TMP/miss")"
[[ ! -e "$TMP/miss/zig-x86_64-linux-0.0.0.tar.xz" ]] || fail "a miss restored something"
grep -q "no cached $key" <<<"$out" || fail "a miss did not say so: $out"

# An unreachable bucket and an empty URL are misses too.
ZIG_TARBALL_R2_URL="http://127.0.0.1:1" bash "$SCRIPT" restore "$TMP/down" >/dev/null || fail "an unreachable bucket failed the step"
ZIG_TARBALL_R2_URL='' bash "$SCRIPT" restore "$TMP/off" | grep -q "no cache URL" || fail "an empty URL did not turn it off"

# seed refuses without write credentials once the bucket lacks the key.
if env -u AWS_ACCESS_KEY_ID RUNNER_ARCH=ARM64 ZIG_TARBALL_R2_URL="http://127.0.0.1:$port" bash "$SCRIPT" seed "$TMP/seed" 2>/dev/null; then
  fail "seed ran without credentials"
fi
# seed exits at once when the bucket holds the key (and the patched tree's key, when this checkout has one).
tree_key="$(ZIG_PRINT_TREE_KEY=1 ZIG_FORCE_LOCAL_INSTALL=1 bash "$ROOT/scripts/install-zig-ci.sh" 2>/dev/null || true)"
[[ -z "$tree_key" ]] || cp "$TMP/bucket/v1/Linux-X64/objects/$key.tar.gz" "$TMP/bucket/v1/Linux-X64/objects/$tree_key.tar.gz"
ZIG_TARBALL_R2_URL="http://127.0.0.1:$port" bash "$SCRIPT" seed "$TMP/seed2" | grep -q "already holds $key" || fail "seed did not see the held key"

# The daemon tests job restores before it installs, and inits ghostty-next through the cache.
wf="$ROOT/.github/workflows/cmux-tui-artifacts.yml"
job="$(awk '/^  cmux-next-daemon-tests:/{on=1} on&&/^  publish-ref-notice:/{exit} on' "$wf")"
grep -q 'run: bash scripts/ci/init-submodule.sh ghostty-next' <<<"$job" || fail "daemon tests does not init ghostty-next through init-submodule.sh"
restore_line="$(grep -n 'zig-tarball-r2.sh restore' <<<"$job" | cut -d: -f1)"
install_line="$(grep -n 'name: Install zig$' <<<"$job" | cut -d: -f1)"
[[ -n "$restore_line" && -n "$install_line" && "$restore_line" -lt "$install_line" ]] || fail "the Zig restore does not run before Install zig"
grep -q 'zig-tarball-r2.sh seed' "$ROOT/.github/workflows/cmux-next-fast-tier-seed.yml" || fail "nothing seeds the Zig tarball"
echo "PASS zig-tarball-r2"
