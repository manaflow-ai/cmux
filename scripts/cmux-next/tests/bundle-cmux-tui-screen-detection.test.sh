#!/usr/bin/env bash
# bundle-cmux-tui.sh places the agent screen-detection plugin beside bin/cmux
# (the daemon runs that sibling by default, cmux-tui spec/plugins.md "Bundled
# default"): from beside the cmux-tui source or its own override in tree mode,
# recorded in cmux-tui.version; a build without one removes a stale copy; pin
# mode (Release) bundles none until its notices are mapped.
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
    -u CMUX_NEXT_AGENT_SCREEN_DETECTION_BIN -u CMUX_TUI_CLIENT_LOCAL \
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

# Pin mode (Release) bundles none, even with one beside the binary, and removes a copy.
bundle "$TMP/build/one/cmux-tui" tree
[[ -e "$bin/cmux-agent-screen-detection" ]] || fail "setup: tree mode did not bundle the detector"
bundle "$TMP/build/one/cmux-tui" pin
[[ ! -e "$bin/cmux-agent-screen-detection" ]] || fail "pin mode bundled bin/cmux-agent-screen-detection"

# Pin mode with no cmux-tui source keeps the bundled bin/cmux, but still drops a
# detector a dev build left there: the daemon must not run it from a Release app.
bundle "$TMP/build/one/cmux-tui" tree
[[ -e "$bin/cmux-agent-screen-detection" ]] || fail "setup: tree mode did not bundle the detector"
mkdir -p "$TMP/no-src" "$TMP/empty-cache"
env -u CMUX_NEXT_TUI_BIN -u CMUX_TUI_CLIENT_LOCAL -u CMUX_NEXT_AGENT_SCREEN_DETECTION_BIN \
  TARGET_BUILD_DIR="$TMP/app" UNLOCALIZED_RESOURCES_FOLDER_PATH=Contents/Resources \
  SRCROOT="$TMP/no-src" CONFIGURATION=Release CMUX_NEXT_TUI_MODE=pin CMUX_TUI_CLIENT_CACHE="$TMP/empty-cache" \
  bash "$ROOT/scripts/cmux-next/bundle-cmux-tui.sh" >"$TMP/out" 2>&1 || { cat "$TMP/out" >&2; fail "keep-bundled run failed"; }
grep -q 'keeping bundled' "$TMP/out" || { cat "$TMP/out" >&2; fail "setup: the keep-bundled path did not run"; }
[[ ! -e "$bin/cmux-agent-screen-detection" ]] || fail "the keep-bundled exit kept a stale bin/cmux-agent-screen-detection"
echo "bundle-cmux-tui-screen-detection: ok"
