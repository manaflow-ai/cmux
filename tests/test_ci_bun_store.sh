#!/usr/bin/env bash
# scripts/ci/toolchain-r2.sh restore bun keeps a version-keyed store of every bun it sees at ~/.bun/bin/bun and
# puts the pinned one back before setup-bun runs, on any runner (Macs included), so a shared ~/.bun left at
# another version (cmux7s-mac-mini 11-26: 1.4.5) no longer sends setup-bun to github.com (403, run 45771452504).
# scripts/cmux-next/private-bun.sh takes the pinned bun from the same store before it would download.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
fake() { mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\necho %s\n' "$2" > "$1"; chmod +x "$1"; }
export HOME="$TMP/home" TOOLCHAIN_R2_URL="" RUNNER_NAME=cmux7s-mac-mini-glaeda-nightly-only-6
unset TOOLCHAIN_BUN_STORE
store="$HOME/.cache/cmux-toolchains/bun"
r2() { bash "$ROOT/scripts/ci/toolchain-r2.sh" restore bun "$1"; }

# A matching shared bun is kept in the store and left alone.
fake "$HOME/.bun/bin/bun" 1.4.4
out="$(r2 1.4.4)"; grep -q "is at" <<<"$out" || fail "matching bun not reported: $out"
[[ "$("$store/1.4.4/bun")" == 1.4.4 ]] || fail "matching bun not kept in the store"

# Another job leaves 1.4.5: the restore keeps 1.4.5 too and puts 1.4.4 back with no download.
fake "$HOME/.bun/bin/bun" 1.4.5
out="$(r2 1.4.4)"; grep -q "no download" <<<"$out" || fail "pinned bun not put back: $out"
[[ "$("$HOME/.bun/bin/bun")" == 1.4.4 ]] || fail "shared bun is not the pin after restore"
[[ "$("$store/1.4.5/bun")" == 1.4.5 ]] || fail "1.4.5 not kept"

# A version the store lacks falls through to the old path (setup-bun installs it): nothing faked.
out="$(r2 9.9.9)"; [[ "$("$HOME/.bun/bin/bun")" == 1.4.4 ]] || fail "unknown version touched the shared bun: $out"

# private-bun.sh: shared bun is the wrong version; the store has the pin; no download is attempted.
mkdir -p "$TMP/pin/webviews" "$TMP/pin/scripts/cmux-next"
cp "$ROOT/scripts/cmux-next/private-bun.sh" "$TMP/pin/scripts/cmux-next/"
cp "$ROOT/scripts/webviews_bun_version.py" "$TMP/pin/scripts/"
want="$(python3 -I "$ROOT/scripts/webviews_bun_version.py" "$ROOT/webviews/package.json")"
cp "$ROOT/webviews/package.json" "$TMP/pin/webviews/"
fake "$TMP/shared/bun" 0.0.1
fake "$store/$want/bun" "$want"
export RUNNER_TEMP="$TMP/rt" GITHUB_PATH="$TMP/ghpath" CMUX_BUN_RELEASE_BASE="file://$TMP/no-such-release"
mkdir -p "$RUNNER_TEMP"; : > "$GITHUB_PATH"
out="$(PATH="$TMP/shared:$PATH" bash "$TMP/pin/scripts/cmux-next/private-bun.sh" 2>&1)" || fail "private-bun failed: $out"
grep -q "from $store/$want/bun" <<<"$out" || fail "private-bun did not use the store: $out"
[[ "$("$RUNNER_TEMP/private-bun/bun")" == "$want" ]] || fail "private bun is not the pin"
echo "PASS: bun store puts the pinned bun back with no download (toolchain-r2 and private-bun)"
