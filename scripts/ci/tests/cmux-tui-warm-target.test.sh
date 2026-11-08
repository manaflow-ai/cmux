#!/usr/bin/env bash
# scripts/ci/cmux-tui-warm-target.sh: the macOS job's Cargo target. An owned Mac keeps one
# per runner across jobs; any other runner keeps cmux-tui/target. A stub xcrun stands in for
# the SDK build.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HELPER="$ROOT/scripts/ci/cmux-tui-warm-target.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
printf '#!/bin/bash\necho "${STUB_SDK:-25A100}"\n' > "$TMP/bin/xcrun"
chmod +x "$TMP/bin/xcrun"
run() { PATH="$TMP/bin:$PATH" HOME="$TMP/home" "$@" "$HELPER"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

got=$(run env RUNNER_NAME=blacksmith-6vcpu-macos-15)
[[ "$got" == "$ROOT/cmux-tui/target" ]] || fail "a hosted runner keeps cmux-tui/target, got $got"
got=$(run env -u RUNNER_NAME)
[[ "$got" == "$ROOT/cmux-tui/target" ]] || fail "no runner name keeps cmux-tui/target, got $got"

first=$(run env RUNNER_NAME=ultra1-glaeda-4)
[[ "$first" == "$TMP/home/Library/Caches/cmux-next-ci/cmux-tui-cargo/"*/rust-* ]] \
  || fail "an owned Mac's target sits under cmux-next-ci, got $first"
[[ -d "$first" ]] || fail "the target directory exists"
touch "$first/kept"
again=$(run env RUNNER_NAME=ultra1-glaeda-4)
[[ "$again" == "$first" && -f "$again/kept" ]] || fail "the same runner gets its kept target back"

other=$(run env RUNNER_NAME=ultra1-glaeda-2)
[[ "$other" != "$first" && -f "$first/kept" ]] || fail "another runner slot gets its own tree"

# An SDK update is a new toolchain: the old tree goes, the new one starts empty.
updated=$(run env RUNNER_NAME=ultra1-glaeda-4 STUB_SDK=25B200)
[[ "$updated" != "$first" && ! -e "$first" && ! -e "$updated/kept" ]] \
  || fail "another toolchain's tree is removed"

# Another Xcode with the same SDK build is a new toolchain too.
xcode=$(run env RUNNER_NAME=ultra1-glaeda-4 STUB_SDK=25B200 DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer)
[[ "$xcode" != "$updated" && ! -e "$updated" ]] || fail "another Xcode's tree is separate"
updated=$(run env RUNNER_NAME=ultra1-glaeda-4 STUB_SDK=25B200)

# A tree over the cap starts over cold.
head -c 2048 /dev/zero > "$updated/big"
capped=$(run env RUNNER_NAME=ultra1-glaeda-4 STUB_SDK=25B200 CMUX_TUI_WARM_TARGET_MAX_GIB=0 2>"$TMP/err")
[[ "$capped" == "$updated" && -d "$capped" && ! -e "$capped/big" ]] || fail "an oversized tree is reset"
grep -q "building cold" "$TMP/err" || fail "the reset says so"
echo "cmux-tui-warm-target: ok"
