#!/usr/bin/env bash
# bundle-cmux-tui.sh places the agent screen-detection plugin beside bin/cmux
# (the daemon runs that sibling by default, cmux-tui spec/plugins.md "Bundled
# default"): from beside the cmux-tui source or its own override in tree mode,
# recorded in cmux-tui.version; a build without one removes a stale copy; pin
# mode (Release) bundles the one its pin names (agent_screen_detection_* fields,
# sha256-checked), and an old pin without those fields bundles none.
# No network, no daemon: a fake cmux-tui and CONFIGURATION=Release skip the
# capability check.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

mkdir -p "$TMP/build/one" "$TMP/build/two" "$TMP/app"
printf '#!/bin/sh\necho "cmux-tui 0.1.0 (%s)"\n' "$(printf 'a%.0s' {1..40})" > "$TMP/build/one/cmux-tui"
cp "$TMP/build/one/cmux-tui" "$TMP/build/two/cmux-tui"
printf 'detector one\n' > "$TMP/build/one/cmux-agent-screen-detection"
printf 'detector override\n' > "$TMP/override-detector"
chmod 755 "$TMP/build/one/cmux-tui" "$TMP/build/two/cmux-tui"

bin="$TMP/app/Contents/Resources/bin"
bundle() { # <tui binary> <mode> [extra env...]
  local tui="$1" mode="$2"; shift 2
  env -u CMUX_NEXT_APP_HOST_BIN -u CMUX_NEXT_CLOUD_SERVER_BIN -u CMUX_NEXT_BROWSER_HOST_BIN \
    -u CMUX_NEXT_AGENT_SCREEN_DETECTION_BIN -u CMUX_NEXT_TERMINAL_HOST_BIN -u CMUX_NEXT_HOLDER_BIN -u CMUX_TUI_CLIENT_LOCAL \
    TARGET_BUILD_DIR="$TMP/app" UNLOCALIZED_RESOURCES_FOLDER_PATH=Contents/Resources \
    SRCROOT="$ROOT" CONFIGURATION=Release CMUX_NEXT_TUI_MODE="$mode" CMUX_NEXT_TUI_BIN="$tui" \
    "$@" bash "$ROOT/scripts/cmux-next/bundle-cmux-tui.sh" >"$TMP/out" 2>&1 \
    || { cat "$TMP/out" >&2; fail "bundle-cmux-tui.sh failed ($mode, $tui)"; }
}

# Tree mode: the detector beside the cmux-tui source is bundled and recorded.
bundle "$TMP/build/one/cmux-tui" tree
[[ -x "$bin/cmux-agent-screen-detection" ]] || fail "tree mode did not bundle bin/cmux-agent-screen-detection"
cmp -s "$bin/cmux-agent-screen-detection" "$TMP/build/one/cmux-agent-screen-detection" \
  || fail "bundled detector is not the one beside cmux-tui"
grep -qx "agent_screen_detection_sha256=$(sha "$TMP/build/one/cmux-agent-screen-detection")" "$bin/cmux-tui.version" \
  || fail "cmux-tui.version does not record the detector sha256: $(cat "$bin/cmux-tui.version")"

# Its own override wins over the sibling.
bundle "$TMP/build/one/cmux-tui" tree CMUX_NEXT_AGENT_SCREEN_DETECTION_BIN="$TMP/override-detector"
cmp -s "$bin/cmux-agent-screen-detection" "$TMP/override-detector" || fail "CMUX_NEXT_AGENT_SCREEN_DETECTION_BIN was not bundled"

# A build without a detector removes the stale copy, so the daemon runs no
# detector from another build.
bundle "$TMP/build/two/cmux-tui" tree
[[ ! -e "$bin/cmux-agent-screen-detection" ]] || fail "a build without a detector kept a stale bin/cmux-agent-screen-detection"
grep -qx "agent_screen_detection_sha256=" "$bin/cmux-tui.version" || fail "cmux-tui.version still records a detector"

# Pin mode with an override binary takes the detector beside it, like tree mode.
bundle "$TMP/build/one/cmux-tui" pin
cmp -s "$bin/cmux-agent-screen-detection" "$TMP/build/one/cmux-agent-screen-detection" \
  || fail "pin mode with CMUX_NEXT_TUI_BIN did not bundle the detector beside it"

# Pin mode with the pinned binary: the pin's agent_screen_detection_sha256 names
# the detector pin-cmux-tui.sh fetch --pin put beside it. An old pin without the
# fields bundles none and removes a stale copy; a wrong sha256 fails the build.
pin_commit=$(printf '1%.0s' {1..40})
src="$TMP/src"
mkdir -p "$src/scripts/cmux-next"
cp "$ROOT/scripts/cmux-next/write-daemon-capabilities.sh" "$src/scripts/cmux-next/"
pinned_dir="$src/cmux-tui/target/hosted/$pin_commit"
mkdir -p "$pinned_dir"
printf '#!/bin/sh\necho "cmux-tui 0.1.0 (%s)"\n' "$pin_commit" > "$pinned_dir/cmux-tui"
chmod 755 "$pinned_dir/cmux-tui"
printf 'pinned detector\n' > "$pinned_dir/cmux-agent-screen-detection"
chmod 755 "$pinned_dir/cmux-agent-screen-detection"
write_pin() { # [detector sha256]
  {
    printf 'commit=%s\nurl=https://files.cmux.com/cmux-tui/%s/cmux-tui-aarch64-apple-darwin\nrun=1\nsha256=%s\n' \
      "$pin_commit" "$pin_commit" "$(sha "$pinned_dir/cmux-tui")"
    if [[ -n "${1:-}" ]]; then
      printf 'agent_screen_detection_url=https://files.cmux.com/cmux-tui/%s/cmux-tui-agent-screen-detection-aarch64-apple-darwin\n' "$pin_commit"
      printf 'agent_screen_detection_sha256=%s\n' "$1"
    fi
  } > "$src/scripts/cmux-next/cmux-tui.pin"
}
bundle_pinned() { # sets status; output in $TMP/out
  set +e
  env -u CMUX_NEXT_TUI_BIN -u CMUX_NEXT_APP_HOST_BIN -u CMUX_NEXT_CLOUD_SERVER_BIN -u CMUX_NEXT_BROWSER_HOST_BIN \
    -u CMUX_NEXT_AGENT_SCREEN_DETECTION_BIN -u CMUX_NEXT_TERMINAL_HOST_BIN -u CMUX_NEXT_HOLDER_BIN -u CMUX_TUI_CLIENT_LOCAL \
    TARGET_BUILD_DIR="$TMP/app" UNLOCALIZED_RESOURCES_FOLDER_PATH=Contents/Resources \
    SRCROOT="$src" CONFIGURATION=Release CMUX_NEXT_TUI_MODE=pin NATIVE_ARCH_ACTUAL=arm64 HOME="$TMP/home" \
    bash "$ROOT/scripts/cmux-next/bundle-cmux-tui.sh" >"$TMP/out" 2>&1
  status=$?
  set -e
}
write_pin "$(sha "$pinned_dir/cmux-agent-screen-detection")"
bundle_pinned
(( status == 0 )) || { cat "$TMP/out" >&2; fail "pin mode with plugin fields failed"; }
cmp -s "$bin/cmux-agent-screen-detection" "$pinned_dir/cmux-agent-screen-detection" \
  || fail "pin mode did not bundle the pinned detector"
grep -qx "agent_screen_detection_sha256=$(sha "$pinned_dir/cmux-agent-screen-detection")" "$bin/cmux-tui.version" \
  || fail "pin mode did not record the pinned detector: $(cat "$bin/cmux-tui.version")"
write_pin
bundle_pinned
(( status == 0 )) || { cat "$TMP/out" >&2; fail "pin mode with an old pin (no plugin fields) failed"; }
[[ ! -e "$bin/cmux-agent-screen-detection" ]] || fail "an old pin without plugin fields kept a stale bin/cmux-agent-screen-detection"
write_pin "$(printf '3%.0s' {1..64})"
bundle_pinned
(( status != 0 )) || fail "pin mode accepted a detector with another sha256"
grep -q 'cmux-agent-screen-detection has sha256' "$TMP/out" || { cat "$TMP/out" >&2; fail "the sha256 error does not name the detector"; }

# Deferred mode (the job installs the client after the build) clears every
# output the phase owns (#24979): a kept bin/cmux could pair with companions
# from another tree, and a detector a dev build left there must not run from a
# Release app. Pin mode without its pin fails and clears them the same way
# (bundle-cmux-tui-pin-no-fallback.test.sh).
bundle "$TMP/build/one/cmux-tui" tree
[[ -e "$bin/cmux-agent-screen-detection" ]] || fail "setup: tree mode did not bundle the detector"
mkdir -p "$TMP/no-src"
env -u CMUX_NEXT_TUI_BIN -u CMUX_TUI_CLIENT_LOCAL -u CMUX_NEXT_AGENT_SCREEN_DETECTION_BIN \
  TARGET_BUILD_DIR="$TMP/app" UNLOCALIZED_RESOURCES_FOLDER_PATH=Contents/Resources \
  SRCROOT="$TMP/no-src" CONFIGURATION=Release CMUX_NEXT_TUI_MODE=deferred \
  bash "$ROOT/scripts/cmux-next/bundle-cmux-tui.sh" >"$TMP/out" 2>&1 || { cat "$TMP/out" >&2; fail "deferred run failed"; }
grep -q 'CMUX_NEXT_TUI_MODE=deferred: bundled no cmux-tui' "$TMP/out" || { cat "$TMP/out" >&2; fail "setup: the deferred path did not run"; }
[[ ! -e "$bin/cmux" ]] || fail "the deferred exit kept a stale bin/cmux"
[[ ! -e "$bin/cmux-agent-screen-detection" ]] || fail "the deferred exit kept a stale bin/cmux-agent-screen-detection"

# Publication stages the detector per macOS and Linux musl target with
# scripts/ci/stage-agent-detector.sh (cmux-tui-build-package.yml, macos-cross.sh).
# The detector is required on those targets: a target without one fails the
# artifacts build with a GitHub error annotation and leaves no stale copy.
stage="$ROOT/scripts/ci/stage-agent-detector.sh"
mkdir -p "$TMP/release-empty" "$TMP/release-built" "$TMP/dist"
printf 'built detector\n' > "$TMP/release-built/cmux-agent-screen-detection"
printf 'stale\n' > "$TMP/dist/cmux-tui-agent-screen-detection-aarch64-apple-darwin"
if out=$(bash "$stage" "$TMP/release-empty" aarch64-apple-darwin "$TMP/dist/cmux-tui-agent-screen-detection-aarch64-apple-darwin" 2>&1); then
  fail "stage-agent-detector.sh passed for a missing detector: $out"
fi
[[ "$out" == "::error title=agent screen detector missing::aarch64-apple-darwin" ]] \
  || fail "a missing detector did not print exactly the error annotation: '$out'"
[[ ! -e "$TMP/dist/cmux-tui-agent-screen-detection-aarch64-apple-darwin" ]] || fail "a missing detector left a stale staged copy"
out=$(bash "$stage" "$TMP/release-built" x86_64-apple-darwin "$TMP/dist/cmux-tui-agent-screen-detection-x86_64-apple-darwin" 2>&1) \
  || fail "stage-agent-detector.sh failed for a built detector: $out"
[[ -z "$out" ]] || fail "a built detector printed: '$out'"
cmp -s "$TMP/release-built/cmux-agent-screen-detection" "$TMP/dist/cmux-tui-agent-screen-detection-x86_64-apple-darwin" \
  || fail "a built detector was not staged"
[[ -x "$TMP/dist/cmux-tui-agent-screen-detection-x86_64-apple-darwin" ]] || fail "the staged detector is not executable"
echo "bundle-cmux-tui-screen-detection: ok"
