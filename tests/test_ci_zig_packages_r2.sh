#!/usr/bin/env bash
# scripts/ci/zig-packages-r2.sh restore puts the locked Zig package archives a cache lacks into its p/ from
# the CI cache bucket, and seed-zig-package-archives.sh runs it when its GitHub-release mirror round fails:
# nightly run 45776501690 (job 139764481921) failed with all 40 mirror downloads refused by github.com.
# A copy whose sha256 is not the lock's is never used; a miss or an unreachable bucket is never an error.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/ci/zig-packages-r2.sh"
SEED="$ROOT/scripts/ci/seed-zig-package-archives.sh"
TMP="$(mktemp -d)"
server_pid=""
cleanup() { [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
sha() { sha256sum < "$1" | cut -d' ' -f1; }

# Two packages: a real tar each. A third copy in the bucket has bytes the lock does not pin.
mkdir -p "$TMP/pkg/a" "$TMP/pkg/b" "$TMP/pkg/c" "$TMP/copy"
echo a > "$TMP/pkg/a/build.zig.zon"; echo b > "$TMP/pkg/b/file"; echo c > "$TMP/pkg/c/file"
tar -czf "$TMP/copy/pkgA-1.tar.gz" -C "$TMP/pkg/a" .
tar -czf "$TMP/copy/pkgB-1.tar.gz" -C "$TMP/pkg/b" .
tar -czf "$TMP/copy/pkgC-1.tar.gz" -C "$TMP/pkg/c" .
cat > "$TMP/lock" <<EOF
# test lock
mirror http://127.0.0.1:1/zig-packages/
pkgA-1 $(sha "$TMP/copy/pkgA-1.tar.gz") ghostty https://example.invalid/a.tar.gz -
pkgB-1 $(sha "$TMP/copy/pkgB-1.tar.gz") ghostty https://example.invalid/b.tar.gz -
pkgC-1 0000000000000000000000000000000000000000000000000000000000000000 ghostty https://example.invalid/c.tar.gz -
EOF
key="zig-packages-v1-$(sha "$TMP/lock" | cut -c1-16)"
mkdir -p "$TMP/bucket/v1/any/objects"
tar -czf "$TMP/bucket/v1/any/objects/$key.tar.gz" -C "$TMP/copy" .

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$TMP/bucket" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 50); do curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 0.1; done
export CMUX_ZIG_LOCK="$TMP/lock" PATH="/usr/bin:/bin:$PATH" CMUX_LAN_CACHE_SOCKET="$TMP/none.sock"
export ZIG_PACKAGES_R2_URL="http://127.0.0.1:$port"

# A hit fills what the cache lacks, keeps what it has, and skips a copy the lock does not pin.
mkdir -p "$TMP/cache/p"; echo mine > "$TMP/cache/p/pkgB-1.tar.gz"
out="$(bash "$SCRIPT" restore "$TMP/cache" 2>&1)"
cmp -s "$TMP/cache/p/pkgA-1.tar.gz" "$TMP/copy/pkgA-1.tar.gz" || fail "restore did not put pkgA: $out"
[[ "$(cat "$TMP/cache/p/pkgB-1.tar.gz")" == mine ]] || fail "restore replaced an archive the cache had"
[[ ! -e "$TMP/cache/p/pkgC-1.tar.gz" ]] || fail "restore used a copy whose sha256 is not the lock's"
grep -q "put 1 of 2 missing" <<<"$out" || fail "restore did not count: $out"
grep -q "not the locked sha256" <<<"$out" || fail "restore did not name the bad copy: $out"

# A full cache does nothing; a missing key, an unreachable bucket and an empty URL are misses, exit 0.
mkdir -p "$TMP/full/p"; for h in pkgA-1 pkgB-1 pkgC-1; do echo x > "$TMP/full/p/$h.tar.gz"; done
bash "$SCRIPT" restore "$TMP/full" | grep -q "already holds every locked package" || fail "a full cache was restored"
echo "# moved" >> "$TMP/lock2"; cat "$TMP/lock" >> "$TMP/lock2"
CMUX_ZIG_LOCK="$TMP/lock2" bash "$SCRIPT" restore "$TMP/miss" | grep -q "no cached" || fail "a missing key did not say so"
ZIG_PACKAGES_R2_URL="http://127.0.0.1:1" bash "$SCRIPT" restore "$TMP/down" >/dev/null || fail "an unreachable bucket failed"
ZIG_PACKAGES_R2_URL='' bash "$SCRIPT" restore "$TMP/off" | grep -q "no cache URL" || fail "an empty URL did not turn it off"

# seed exits at once when the bucket holds the key, and refuses without write credentials when it does not.
bash "$SCRIPT" seed "$TMP/seed" | grep -q "already holds $key" || fail "seed did not see the held key"
if CMUX_ZIG_LOCK="$TMP/lock2" env -u AWS_ACCESS_KEY_ID bash "$SCRIPT" seed "$TMP/seed2" 2>/dev/null; then
  fail "seed ran without credentials"
fi

# The seeder falls back to the bucket when its mirror (unreachable here) leaves packages missing.
src="$TMP/src/ghostty"; mkdir -p "$src"
cat > "$src/build.zig.zon" <<'EOF'
.{ .dependencies = .{ .a = .{ .url = "https://example.invalid/a.tar.gz", .hash = "pkgA-1" } } }
EOF
out="$(CI=true CMUX_ZIG_SEED_TIMEOUT=60 bash "$SEED" "$TMP/seedcache" "$src" 2>&1)"
cmp -s "$TMP/seedcache/p/pkgA-1.tar.gz" "$TMP/copy/pkgA-1.tar.gz" || fail "the seeder did not fall back to the bucket: $out"
grep -q "zig-packages-r2: put" <<<"$out" || fail "the seeder did not say it used the bucket: $out"

grep -q 'zig-packages-r2.sh seed' "$ROOT/.github/workflows/cmux-next-fast-tier-seed.yml" || fail "nothing seeds the Zig packages"
echo "PASS zig-packages-r2"
