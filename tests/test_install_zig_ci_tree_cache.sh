#!/usr/bin/env bash
# install-zig-ci.sh restores the unpacked, std-fixed Zig tree from the CI cache bucket before it downloads:
# on 2026-11-25 a Freestyle fast tier (cargo) job spent 31 min unpacking the .tar.xz and 5 min copying the
# tree, and timed out. A hit installs with no download; a miss, a tree of another version or an empty URL
# falls through to the verified download.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
server_pid=""
cleanup() { [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A fixture repository whose only reviewed Zig is 99.99.99 (no std fix), so no real Zig can stand in.
repo="$TMP/repo"
mkdir -p "$repo/scripts/ci" "$repo/cmux-tui/build-support/notices/toolchains"
cp "$ROOT/scripts/install-zig-ci.sh" "$ROOT/scripts/ghostty-zig-version.sh" "$repo/scripts/"
cp "$ROOT/scripts/ci/r2-cache.sh" "$ROOT/scripts/ci/lan_cache_fetch.py" "$repo/scripts/ci/"
printf '{"zig": [{"ci_version": "99.99.99"}]}\n' > "$repo/cmux-tui/build-support/notices/toolchains/toolchains.json"
case "$(uname -m)" in arm64 | aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
case "$(uname -s)" in Darwin) os=macos ;; *) os=linux ;; esac
name="zig-$arch-$os-99.99.99"
printf '%s  %s.tar.xz\n' "$(printf x | sha256sum | cut -d' ' -f1)" "$name" > "$repo/scripts/ci/zig-tarballs.sha256"

export ZIG_REQUIRED=99.99.99 ZIG_FLEET_TOOLS_DIR="" ZIG_REUSE_CANDIDATES="" ZIG_FORCE_LOCAL_INSTALL=1
export RUNNER_OS=Linux RUNNER_ARCH=X64 CMUX_LAN_CACHE_SOCKET="$TMP/none.sock" GITHUB_PATH="" GITHUB_ENV=""
unreachable="http://127.0.0.1:9/unreachable"
export ZIG_INDEX_URL="$unreachable" ZIG_MIRROR_URL="$unreachable" ZIG_SECONDARY_MIRROR_URL="$unreachable" \
  ZIG_TERTIARY_MIRROR_URL="$unreachable" ZIG_OFFICIAL_URL="$unreachable" ZIG_DOWNLOAD_ATTEMPTS=1 ZIG_DOWNLOAD_RETRY_DELAY=0

key="$(ZIG_PRINT_TREE_KEY=1 bash "$repo/scripts/install-zig-ci.sh")"
[[ "$key" == "zig-tree-v1-$name-$(printf x | sha256sum | cut -c1-16)-unpatched" ]] || fail "unexpected tree key: $key"

fake_tree() { # DIR VERSION
  mkdir -p "$1/$name/lib/std"
  echo "// fixture" > "$1/$name/lib/std/std.zig"
  printf '#!/bin/sh\n[ "$1" = version ] && echo %s\n' "$2" > "$1/$name/zig"
  chmod 755 "$1/$name/zig"
}
objects="$TMP/bucket/v1/Linux-X64/objects"
mkdir -p "$objects"
fake_tree "$TMP/good" 99.99.99
tar -czf "$objects/$key.tar.gz" -C "$TMP/good" .
fake_tree "$TMP/other" 1.0.0
mkdir -p "$TMP/bucket/v1/Linux-ARM64/objects"
tar -czf "$TMP/bucket/v1/Linux-ARM64/objects/$key.tar.gz" -C "$TMP/other" .

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$TMP/bucket" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 50); do curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 0.1; done  # sleep-ok: server start

# A hit installs the tree and downloads nothing.
out="$(RUNNER_TEMP="$TMP/hit" ZIG_TREE_R2_URL="http://127.0.0.1:$port" bash "$repo/scripts/install-zig-ci.sh" 2>&1)" \
  || fail "a cached tree did not install: $out"
grep -q "restored the patched tree $key" <<<"$out" || fail "the hit did not say so: $out"
! grep -q "$unreachable" <<<"$out" || fail "a hit still downloaded: $out"
[[ "$("$TMP/hit/$name/zig" version)" == 99.99.99 ]] || fail "the restored zig is not installed at RUNNER_TEMP"

# A tree of another version is refused, and the download runs.
out="$(RUNNER_TEMP="$TMP/wrong" RUNNER_ARCH=ARM64 ZIG_TREE_R2_URL="http://127.0.0.1:$port" bash "$repo/scripts/install-zig-ci.sh" 2>&1)" \
  && fail "a tree of another version installed: $out"
grep -q "is not a reviewed zig 99.99.99" <<<"$out" || fail "a wrong tree was not named: $out"
grep -q "$unreachable" <<<"$out" || fail "a wrong tree did not fall through to the download: $out"

# A miss and an empty URL download.
out="$(RUNNER_TEMP="$TMP/miss" RUNNER_OS=macOS ZIG_TREE_R2_URL="http://127.0.0.1:$port" bash "$repo/scripts/install-zig-ci.sh" 2>&1)" \
  && fail "a miss installed: $out"
grep -q "no cached zig tree $key" <<<"$out" || fail "a miss did not say so: $out"
out="$(RUNNER_TEMP="$TMP/off" ZIG_TREE_R2_URL='' bash "$repo/scripts/install-zig-ci.sh" 2>&1)" && fail "an empty URL installed: $out"
! grep -q "zig tree" <<<"$out" || fail "an empty URL still read the bucket: $out"

# The fast tier (cargo) job installs Zig through the script, and the seed workflow saves the tree.
grep -q 'run: ./scripts/install-zig-ci.sh' "$ROOT/.github/workflows/cmux-next.yml" || fail "cmux-next.yml no longer installs Zig through install-zig-ci.sh"
grep -q 'zig_tree_key\|tree_key' "$ROOT/scripts/ci/zig-tarball-r2.sh" || fail "zig-tarball-r2.sh seed does not save the tree"
echo "PASS install-zig-ci tree cache"
