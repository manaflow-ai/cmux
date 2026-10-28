#!/usr/bin/env bash
# The app bundle's bin/daemon-capabilities.json comes from the bundled binary:
# bundle-cmux-tui.sh (the Xcode phase) and write-cmux-tui-version.sh (release
# and nightly, after the universal client) run write-daemon-capabilities.sh,
# which records `cmux-tui __daemon-capabilities --json` and `acpmux capabilities --json`
# as {"cmuxTui": [...], "acpmux": [...]}. A binary from before `capabilities`
# leaves no file (a stale one is removed) unless the caller requires it.
# No network, no daemon: a fake multi-call binary, and CONFIGURATION=Release
# skips the identify check.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
commit=$(printf 'a%.0s' {1..40})

# One binary, like bin/cmux: argv[0] picks cmux-tui or acpmux.
mkdir -p "$TMP/new" "$TMP/old" "$TMP/fakebin"
cat > "$TMP/new/cmux-tui" <<SH
#!/bin/sh
case "\$(basename "\$0") \$*" in
  "acpmux capabilities --json") echo '{"capabilities":["acpmux-v1","queue-edit-v1"]}' ;;
  *" __daemon-capabilities --json") echo '{"capabilities":["fs-v1","ws-conversations-v1"]}' ;;
  *" --version") echo "cmux-tui 0.1.0 ($commit)" ;;
  *) exit 64 ;;
esac
SH
# A build from before the command: it refuses the unknown word.
cat > "$TMP/old/cmux-tui" <<SH
#!/bin/sh
[ "\$1" = --version ] && { echo "cmux-tui 0.1.0 ($commit)"; exit 0; }
echo "unknown command \$1" >&2
exit 2
SH
chmod 755 "$TMP/new/cmux-tui" "$TMP/old/cmux-tui"

app="$TMP/app"
bin="$app/Contents/Resources/bin"
file="$bin/daemon-capabilities.json"
bundle() { # <tui binary>
  env -u CMUX_NEXT_APP_HOST_BIN -u CMUX_NEXT_CLOUD_SERVER_BIN -u CMUX_NEXT_BROWSER_HOST_BIN \
    -u CMUX_NEXT_AGENT_SCREEN_DETECTION_BIN -u CMUX_NEXT_TERMINAL_HOST_BIN -u CMUX_NEXT_HOLDER_BIN -u CMUX_TUI_CLIENT_LOCAL \
    TARGET_BUILD_DIR="$app" UNLOCALIZED_RESOURCES_FOLDER_PATH=Contents/Resources \
    SRCROOT="$ROOT" CONFIGURATION=Release CMUX_NEXT_TUI_MODE=tree CMUX_NEXT_TUI_BIN="$1" \
    bash "$ROOT/scripts/cmux-next/bundle-cmux-tui.sh" >"$TMP/out" 2>&1 \
    || { cat "$TMP/out" >&2; fail "bundle-cmux-tui.sh failed ($1)"; }
}
want='{
  "cmuxTui": [
    "fs-v1",
    "ws-conversations-v1"
  ],
  "acpmux": [
    "acpmux-v1",
    "queue-edit-v1"
  ]
}'

# The Xcode phase records both lists from the binary it placed.
bundle "$TMP/new/cmux-tui"
[[ -f "$file" ]] || { cat "$TMP/out" >&2; fail "bundle-cmux-tui.sh wrote no bin/daemon-capabilities.json"; }
[[ "$(cat "$file")" == "$want" ]] || fail "unexpected daemon-capabilities.json: $(cat "$file")"
grep -q 'daemon-capabilities.json: cmux-tui 2, acpmux 2 capabilities' "$TMP/out" || { cat "$TMP/out" >&2; fail "no summary line"; }

# An unchanged list leaves the file alone (no needless resource change).
touch -t 202001010000 "$file"
bundle "$TMP/new/cmux-tui"
[[ "$(find "$file" -newermt '2020-01-02' 2>/dev/null)" == "" ]] || fail "an unchanged list rewrote the file"

# A binary from before `capabilities` (an override, a pin) bundles none and
# removes the stale file: the bundle never claims what its daemon may lack.
bundle "$TMP/old/cmux-tui"
[[ ! -e "$file" ]] || fail "an old binary kept a stale daemon-capabilities.json"
grep -q 'warning: daemon-capabilities.json: .cmux-tui __daemon-capabilities --json. failed' "$TMP/out" \
  || { cat "$TMP/out" >&2; fail "no warning for an old binary"; }

# --require (a same-tree binary) makes that an error.
if bash "$ROOT/scripts/cmux-next/write-daemon-capabilities.sh" --require "$bin" >"$TMP/out" 2>&1; then
  fail "--require accepted a binary without capabilities"
fi
grep -q 'error: daemon-capabilities.json' "$TMP/out" || { cat "$TMP/out" >&2; fail "no --require error"; }

# Output that is not a capability list is refused too.
mkdir -p "$TMP/bad"
printf '#!/bin/sh\necho "{\\"capabilities\\": []}"\n' > "$TMP/bad/cmux-tui"
chmod 755 "$TMP/bad/cmux-tui"
ln -s cmux-tui "$TMP/bad/acpmux"
if bash "$ROOT/scripts/cmux-next/write-daemon-capabilities.sh" --require "$TMP/bad" >"$TMP/out" 2>&1; then
  fail "an empty capability list was accepted"
fi
grep -q 'printed no capability list' "$TMP/out" || { cat "$TMP/out" >&2; fail "no reason for an empty list"; }

# Release and nightly: write-cmux-tui-version.sh rewrites it from the
# universal client they installed over the Xcode phase's one.
bundle "$TMP/old/cmux-tui"
rm -f "$bin/cmux"
cp "$TMP/new/cmux-tui" "$bin/cmux"
printf '#!/bin/sh\necho "x86_64 arm64"\n' > "$TMP/fakebin/lipo"
chmod 755 "$TMP/fakebin/lipo"
PATH="$TMP/fakebin:$PATH" bash "$ROOT/scripts/cmux-next/write-cmux-tui-version.sh" "$app" "$commit" >"$TMP/out" 2>&1 \
  || { cat "$TMP/out" >&2; fail "write-cmux-tui-version.sh failed"; }
[[ "$(cat "$file" 2>/dev/null)" == "$want" ]] || { cat "$TMP/out" >&2; fail "write-cmux-tui-version.sh did not write daemon-capabilities.json"; }
echo "write-daemon-capabilities: ok"
