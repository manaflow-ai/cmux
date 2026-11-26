#!/usr/bin/env bash
# scripts/ci/zig-tarball-r2.sh keeps every pinned Zig tarball, for every platform, in the CI cache bucket, and
# install-zig-ci.sh reads it before the third-party mirrors: job 137551791655 (a fresh Freestyle runner) and
# the NIGHTLY signer's job 138863767001 each spent the whole 480 s Zig budget on those mirrors and failed. A
# miss, an unreachable bucket or an unpinned name is never an error.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/ci/zig-tarball-r2.sh"
PINS="$ROOT/scripts/ci/zig-tarballs.sha256"
TMP="$(mktemp -d)"
server_pid=""
cleanup() { [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

pin_of() { awk -v name="$1.tar.xz" '$1 !~ /^#/ && $2 == name { print $1; exit }' "$PINS"; }
key_of() { echo "zig-tarball-v2-$1-$(pin_of "$1" | cut -c1-16)"; }
mac="$(awk '$1 !~ /^#/ && $2 ~ /^zig-aarch64-macos-/ { sub(/\.tar\.xz$/, "", $2); print $2; exit }' "$PINS")"
[[ -n "$mac" ]] || fail "no aarch64 macOS tarball is pinned"

# The bucket holds the Mac tarball (and its signature) under the Mac namespace.
mkdir -p "$TMP/bucket/v1/macOS-ARM64/objects" "$TMP/src"
echo tarball > "$TMP/src/$mac.tar.xz"
echo sig > "$TMP/src/$mac.tar.xz.minisig"
tar -czf "$TMP/bucket/v1/macOS-ARM64/objects/$(key_of "$mac").tar.gz" -C "$TMP/src" .

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$TMP/bucket" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 50); do curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 0.1; done
export PATH="/usr/bin:/bin:$PATH" CMUX_LAN_CACHE_SOCKET="$TMP/none.sock" ZIG_TARBALL_R2_URL="http://127.0.0.1:$port"

# fetch: a Linux runner fetches the Mac tarball by name (the namespace comes from the name, not the host).
out="$(RUNNER_OS=Linux RUNNER_ARCH=X64 bash "$SCRIPT" fetch "$mac" "$TMP/fetch")"
[[ "$(cat "$TMP/fetch/$mac.tar.xz")" == tarball && -f "$TMP/fetch/$mac.tar.xz.minisig" ]] || fail "fetch left no tarball: $out"
grep -q "restored $(key_of "$mac")" <<<"$out" || fail "fetch did not say it restored: $out"

# fetch: an unpinned name fetches nothing, exit 0.
out="$(bash "$SCRIPT" fetch zig-aarch64-macos-99.99.99 "$TMP/unpinned")"
[[ ! -e "$TMP/unpinned" ]] || fail "an unpinned name was fetched: $out"
grep -q "has no pin" <<<"$out" || fail "an unpinned name did not say so: $out"

# restore: a Mac runner's directory gains its missing tarballs and keeps the files it holds.
mkdir -p "$TMP/mac"; echo mine > "$TMP/mac/own.tar.xz"
RUNNER_OS=macOS RUNNER_ARCH=ARM64 bash "$SCRIPT" restore "$TMP/mac" >/dev/null
[[ -f "$TMP/mac/$mac.tar.xz" && -f "$TMP/mac/$mac.tar.xz.minisig" ]] || fail "restore did not fill the Mac directory"
[[ "$(cat "$TMP/mac/own.tar.xz")" == mine ]] || fail "restore replaced a file the directory held"
# A tarball the directory already holds is not fetched again.
echo kept > "$TMP/mac/$mac.tar.xz"
RUNNER_OS=macOS RUNNER_ARCH=ARM64 bash "$SCRIPT" restore "$TMP/mac" >/dev/null
[[ "$(cat "$TMP/mac/$mac.tar.xz")" == kept ]] || fail "restore replaced a tarball the directory held"

# restore: another platform (Linux arm64 here) is a miss, exit 0.
RUNNER_OS=Linux RUNNER_ARCH=ARM64 bash "$SCRIPT" restore "$TMP/miss" >/dev/null
[[ -z "$(ls -A "$TMP/miss")" ]] || fail "a miss restored something"

# An unreachable bucket and an empty URL are misses too.
ZIG_TARBALL_R2_URL="http://127.0.0.1:1" bash "$SCRIPT" fetch "$mac" "$TMP/down" >/dev/null || fail "an unreachable bucket failed fetch"
ZIG_TARBALL_R2_URL='' bash "$SCRIPT" restore "$TMP/off" | grep -q "no cache URL" || fail "an empty URL did not turn it off"

# seed refuses without write credentials while the bucket lacks a pinned tarball.
if env -u AWS_ACCESS_KEY_ID bash "$SCRIPT" seed >/dev/null 2>&1; then
  fail "seed ran without credentials"
fi
# seed needs nothing once the bucket holds every pinned tarball, each under its own platform.
while read -r name ns; do
  mkdir -p "$TMP/bucket/v1/$ns/objects"
  : > "$TMP/bucket/v1/$ns/objects/$(key_of "$name").tar.gz"
done < <(awk '$1 !~ /^#/ && NF == 2 { n = $2; sub(/\.tar\.xz$/, "", n); split(n, p, "-");
  os = p[3] == "macos" ? "macOS" : "Linux"; arch = p[2] == "aarch64" ? "ARM64" : "X64"; print n, os "-" arch }' "$PINS")
out="$(env -u AWS_ACCESS_KEY_ID bash "$SCRIPT" seed)" || fail "seed failed with every key held: $out"
[[ "$(grep -c "already holds" <<<"$out")" == "$(awk '$1 !~ /^#/ && NF == 2' "$PINS" | wc -l | tr -d ' ')" ]] \
  || fail "seed did not check every pinned tarball: $out"
grep -q "already holds macOS-ARM64/$(key_of "$mac")" <<<"$out" || fail "seed did not check the Mac tarball: $out"

# install-zig-ci.sh reads the bucket before the mirrors, only for a pinned tarball.
installer="$ROOT/scripts/install-zig-ci.sh"
# shellcheck disable=SC2016 # the installer's own text, matched literally
fetch_line="$(grep -n 'bash "$ZIG_R2_SCRIPT" fetch "$ZIG_NAME"' "$installer" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016
mirror_line="$(grep -nE '^ +download_zig_artifact "" "[$]ZIG_TAR"' "$installer" | head -1 | cut -d: -f1)"
[[ -n "$fetch_line" && -n "$mirror_line" && "$fetch_line" -lt "$mirror_line" ]] || fail "install-zig-ci.sh does not read the bucket before the mirrors"

# The daemon tests job restores before it installs, and inits ghostty-next through the cache.
wf="$ROOT/.github/workflows/cmux-tui-artifacts.yml"
job="$(awk '/^  cmux-next-daemon-tests:/{on=1} on&&/^  publish-ref-notice:/{exit} on' "$wf")"
grep -q 'run: bash scripts/ci/init-submodule.sh ghostty-next' <<<"$job" || fail "daemon tests does not init ghostty-next through init-submodule.sh"
restore_line="$(grep -n 'zig-tarball-r2.sh restore' <<<"$job" | cut -d: -f1)"
install_line="$(grep -n 'name: Install zig$' <<<"$job" | cut -d: -f1)"
[[ -n "$restore_line" && -n "$install_line" && "$restore_line" -lt "$install_line" ]] || fail "the Zig restore does not run before Install zig"
grep -q 'run: bash scripts/ci/zig-tarball-r2.sh seed$' "$ROOT/.github/workflows/cmux-next-fast-tier-seed.yml" || fail "nothing seeds the Zig tarballs"
echo "PASS zig-tarball-r2"
