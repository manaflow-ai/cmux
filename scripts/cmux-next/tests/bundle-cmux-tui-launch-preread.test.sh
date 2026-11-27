#!/usr/bin/env bash
# bundle-cmux-tui.sh places the login-time pre-read reader (app.backgroundReady
# = warmAtLogin, off by default) beside bin/cmux as bin/cmux-launch-preread:
# from beside an override cmux-tui or its own override
# (CMUX_NEXT_LAUNCH_PREREAD_BIN), recorded in cmux-tui.version; a build without
# one removes a stale copy (so the bundle carries no pre-read LaunchAgent), and
# deferred mode clears it with every other output.
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
printf 'reader one\n' > "$TMP/build/one/cmux-launch-preread"
printf 'reader override\n' > "$TMP/override-reader"
chmod 755 "$TMP/build/one/cmux-tui" "$TMP/build/two/cmux-tui"

bin="$TMP/app/Contents/Resources/bin"
bundle() { # <tui binary> <mode> [extra env...]
  local tui="$1" mode="$2"; shift 2
  env -u CMUX_NEXT_APP_HOST_BIN -u CMUX_NEXT_CLOUD_SERVER_BIN -u CMUX_NEXT_BROWSER_HOST_BIN \
    -u CMUX_NEXT_AGENT_SCREEN_DETECTION_BIN -u CMUX_NEXT_TERMINAL_HOST_BIN -u CMUX_NEXT_HOLDER_BIN \
    -u CMUX_NEXT_LAUNCH_PREREAD_BIN -u CMUX_TUI_CLIENT_LOCAL \
    TARGET_BUILD_DIR="$TMP/app" UNLOCALIZED_RESOURCES_FOLDER_PATH=Contents/Resources \
    SRCROOT="$ROOT" CONFIGURATION=Release CMUX_NEXT_TUI_MODE="$mode" CMUX_NEXT_TUI_BIN="$tui" \
    "$@" bash "$ROOT/scripts/cmux-next/bundle-cmux-tui.sh" >"$TMP/out" 2>&1 \
    || { cat "$TMP/out" >&2; fail "bundle-cmux-tui.sh failed ($mode, $tui)"; }
}

# Beside the cmux-tui source: bundled and recorded.
bundle "$TMP/build/one/cmux-tui" tree
[[ -x "$bin/cmux-launch-preread" ]] || fail "did not bundle bin/cmux-launch-preread"
cmp -s "$bin/cmux-launch-preread" "$TMP/build/one/cmux-launch-preread" || fail "bundled reader is not the one beside cmux-tui"
grep -qx "launch_preread_sha256=$(sha "$TMP/build/one/cmux-launch-preread")" "$bin/cmux-tui.version" \
  || fail "cmux-tui.version does not record the reader sha256: $(cat "$bin/cmux-tui.version")"

# Its own override wins over the sibling; a missing override fails the build.
bundle "$TMP/build/one/cmux-tui" tree CMUX_NEXT_LAUNCH_PREREAD_BIN="$TMP/override-reader"
cmp -s "$bin/cmux-launch-preread" "$TMP/override-reader" || fail "CMUX_NEXT_LAUNCH_PREREAD_BIN was not bundled"
set +e
env -u CMUX_TUI_CLIENT_LOCAL TARGET_BUILD_DIR="$TMP/app" UNLOCALIZED_RESOURCES_FOLDER_PATH=Contents/Resources \
  SRCROOT="$ROOT" CONFIGURATION=Release CMUX_NEXT_TUI_MODE=tree CMUX_NEXT_TUI_BIN="$TMP/build/one/cmux-tui" \
  CMUX_NEXT_LAUNCH_PREREAD_BIN="$TMP/nope" bash "$ROOT/scripts/cmux-next/bundle-cmux-tui.sh" >"$TMP/out" 2>&1
status=$?
set -e
(( status != 0 )) || fail "a missing CMUX_NEXT_LAUNCH_PREREAD_BIN was accepted"
grep -q 'cmux-launch-preread .* does not exist' "$TMP/out" || { cat "$TMP/out" >&2; fail "the error does not name the reader"; }

# A build without a reader removes the stale copy.
bundle "$TMP/build/two/cmux-tui" tree
[[ ! -e "$bin/cmux-launch-preread" ]] || fail "a build without a reader kept a stale bin/cmux-launch-preread"
grep -qx "launch_preread_sha256=" "$bin/cmux-tui.version" || fail "cmux-tui.version still records a reader"

# Deferred mode clears it with every other output.
bundle "$TMP/build/one/cmux-tui" tree
[[ -e "$bin/cmux-launch-preread" ]] || fail "setup: the reader was not bundled"
mkdir -p "$TMP/no-src"
env -u CMUX_NEXT_TUI_BIN -u CMUX_TUI_CLIENT_LOCAL -u CMUX_NEXT_LAUNCH_PREREAD_BIN \
  TARGET_BUILD_DIR="$TMP/app" UNLOCALIZED_RESOURCES_FOLDER_PATH=Contents/Resources \
  SRCROOT="$TMP/no-src" CONFIGURATION=Release CMUX_NEXT_TUI_MODE=deferred \
  bash "$ROOT/scripts/cmux-next/bundle-cmux-tui.sh" >"$TMP/out" 2>&1 || { cat "$TMP/out" >&2; fail "deferred run failed"; }
[[ ! -e "$bin/cmux-launch-preread" ]] || fail "the deferred exit kept a stale bin/cmux-launch-preread"
# Hosted and pinned builds verify the reader against the publication, and
# an older publication removes a stale bundled reader rather than using it.
fixture="$TMP/src"
mkdir -p "$fixture/scripts/cmux-next" "$TMP/tree"
cp "$ROOT/scripts/cmux-next/link-folded-hosts.sh" "$ROOT/scripts/cmux-next/write-daemon-capabilities.sh" \
  "$ROOT/scripts/cmux-next/write-cmux-tui-build-stamp.sh" "$fixture/scripts/cmux-next/"
cp "$TMP/build/one/cmux-tui" "$TMP/tree/cmux-tui"
cp "$TMP/build/one/cmux-launch-preread" "$TMP/tree/cmux-launch-preread"
sha "$TMP/tree/cmux-tui" > "$TMP/tree/cmux-tui.sha256"
key=$(printf 'b%.0s' {1..40})
cat > "$fixture/scripts/cmux-next/pin-cmux-tui.sh" <<'STUB'
#!/bin/sh
case "$1" in
  key) printf '%s\n' "$TEST_TREE_KEY" ;;
  path) printf '%s\n' "$TEST_TREE_BINARY" ;;
  local-build) exit 1 ;;
esac
STUB
chmod +x "$fixture/scripts/cmux-next/pin-cmux-tui.sh"
# Avoid requiring a real daemon's capabilities: this is an older fallback tree.
hosted() {
  env -u CMUX_NEXT_TUI_BIN -u CMUX_TUI_CLIENT_LOCAL -u CMUX_NEXT_LAUNCH_PREREAD_BIN \
    TARGET_BUILD_DIR="$TMP/app" UNLOCALIZED_RESOURCES_FOLDER_PATH=Contents/Resources \
    SRCROOT="$fixture" CONFIGURATION=Release CMUX_NEXT_TUI_MODE="$1" NATIVE_ARCH_ACTUAL=arm64 \
    TEST_TREE_KEY="$key" TEST_TREE_BINARY="$TMP/tree/cmux-tui" CMUX_TUI_TREE_KEY=older \
    bash "$ROOT/scripts/cmux-next/bundle-cmux-tui.sh" >"$TMP/out" 2>&1
}
sha "$TMP/tree/cmux-launch-preread" > "$TMP/tree/cmux-launch-preread.sha256"
hosted tree || { cat "$TMP/out" >&2; fail "hosted reader failed"; }
cmp -s "$bin/cmux-launch-preread" "$TMP/tree/cmux-launch-preread" || fail "hosted reader not bundled"
printf 'corrupt\n' >> "$TMP/tree/cmux-launch-preread"
if hosted tree; then fail "corrupt hosted reader accepted"; fi
grep -q 'not the published' "$TMP/out" || fail "hosted error did not name checksum"
echo none > "$TMP/tree/cmux-launch-preread.sha256"
hosted tree || { cat "$TMP/out" >&2; fail "older hosted tree failed"; }
[[ ! -e "$bin/cmux-launch-preread" ]] || fail "older hosted tree retained reader"

commit=$(printf 'a%.0s' {1..40})
pinned="$fixture/cmux-tui/target/hosted/$commit"
mkdir -p "$pinned"
cp "$TMP/build/one/cmux-tui" "$TMP/build/one/cmux-launch-preread" "$pinned/"
write_pin() {
  printf 'commit=%s\nurl=https://files.cmux.com/cmux-tui/%s/cmux-tui-aarch64-apple-darwin\nsha256=%s\nlaunch_preread_sha256=%s\n' \
    "$commit" "$commit" "$(sha "$pinned/cmux-tui")" "$1" > "$fixture/scripts/cmux-next/cmux-tui.pin"
}
write_pin "$(sha "$pinned/cmux-launch-preread")"
hosted pin || { cat "$TMP/out" >&2; fail "pinned reader failed"; }
cmp -s "$bin/cmux-launch-preread" "$pinned/cmux-launch-preread" || fail "pinned reader not bundled"
printf 'corrupt\n' >> "$pinned/cmux-launch-preread"
if hosted pin; then fail "corrupt pinned reader accepted"; fi
grep -q 'not the published' "$TMP/out" || fail "pin error did not name checksum"
write_pin ''
hosted pin || { cat "$TMP/out" >&2; fail "older pin failed"; }
[[ ! -e "$bin/cmux-launch-preread" ]] || fail "older pin retained reader"
echo "bundle-cmux-tui-launch-preread: ok"
