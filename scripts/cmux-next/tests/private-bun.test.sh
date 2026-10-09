#!/usr/bin/env bash
# private-bun.sh: a cmux-next Mac job runs on its own copy of the bun that
# webviews/package.json pins. The minis share ~/.bun between runner instances,
# and ci-macos.yml and ci-guards.yml install bun 1.3.6 there, so a concurrent
# job swapped the binary under #18124's swift test after setup-bun had checked
# 1.4.2 ("webviews needs bun 1.4.2 ... /Users/cmux/.bun/bin/bun is bun 1.3.6").
# No network: the release is served from file://.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

src="$TMP/src"
mkdir -p "$src/scripts/cmux-next" "$src/webviews"
cp "$ROOT/scripts/cmux-next/private-bun.sh" "$src/scripts/cmux-next/"
printf '{"devEngines":{"packageManager":{"name":"bun","version":"9.9.9","onFail":"error"}}}\n' > "$src/webviews/package.json"

shim() { printf '#!/bin/sh\necho %s\n' "$2" > "$1"; chmod +x "$1"; }
mkdir -p "$TMP/shared"
# run -> status, out; RUNNER_TEMP and GITHUB_PATH are fresh per run.
run() {
  rm -rf "$TMP/runner"; mkdir -p "$TMP/runner"; : > "$TMP/runner/path"
  status=0
  out=$(PATH="$TMP/shared:$PATH" RUNNER_TEMP="$TMP/runner" GITHUB_PATH="$TMP/runner/path" \
    CMUX_BUN_RELEASE_BASE="file://$TMP/release" bash "$src/scripts/cmux-next/private-bun.sh" 2>&1) || status=$?
}
private() { head -n 1 "$TMP/runner/path"; }

# The shared bun is the pinned one: the job gets a private copy of it, which a
# later swap of the shared binary does not reach.
shim "$TMP/shared/bun" 9.9.9
run
[[ "$status" == 0 ]] || fail "a pinned shared bun must be copied (exit $status): $out"
[[ -n "$(private)" && "$(private)" != "$TMP/shared" ]] || fail "GITHUB_PATH must name a private directory: $(cat "$TMP/runner/path")"
shim "$TMP/shared/bun" 1.3.6
[[ "$("$(private)/bun" --version)" == 9.9.9 ]] || fail "the private copy must keep the pinned version after the shared one changes"
[[ -x "$(private)/bunx" ]] || fail "the private directory needs bunx"

# The shared bun was already swapped: the pinned release is downloaded and
# checked against the release's SHASUMS256.txt.
mkdir -p "$TMP/release/bun-v9.9.9"
for platform in darwin-aarch64 darwin-x64 linux-x64 linux-aarch64; do
  mkdir -p "$TMP/zip/bun-$platform"
  shim "$TMP/zip/bun-$platform/bun" 9.9.9
  (cd "$TMP/zip" && zip -qr "$TMP/release/bun-v9.9.9/bun-$platform.zip" "bun-$platform")
done
(cd "$TMP/release/bun-v9.9.9" && shasum -a 256 ./*.zip | sed 's# \./# #' > SHASUMS256.txt)
run
[[ "$status" == 0 ]] || fail "a swapped shared bun must be replaced by the pinned release (exit $status): $out"
[[ "$("$(private)/bun" --version)" == 9.9.9 ]] || fail "the downloaded bun must be the pinned version"

# A release that does not match its checksums is refused.
(cd "$TMP/release/bun-v9.9.9" && sed -i.bak 's/^[0-9a-f]/0/' SHASUMS256.txt && rm SHASUMS256.txt.bak)
run
[[ "$status" != 0 ]] || fail "a checksum mismatch must fail: $out"
[[ ! -s "$TMP/runner/path" ]] || fail "a refused download must not reach GITHUB_PATH"

echo "private-bun tests: ok"
