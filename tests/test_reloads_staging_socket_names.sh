#!/usr/bin/env bash
# Per-build isolation (cx-is1kf.4): a tagged staging build
# (`com.cmuxterm.app.staging.<tag>`) listens on the control socket of its build
# key (`cmux-staging--<key hash>.sock` in ~/.local/state/cmux, the shared
# vectors in schemas/build-identity/vectors.json), and the app ignores an
# inherited CMUX_SOCKET_PATH. scripts/reloads.sh still wrote
# /tmp/cmux-staging-<tag>.sock into the bundle's LSEnvironment, the launch
# environment and the last-socket-path markers, so every tool that followed
# them reached no app.
#
# The test runs reloads.sh itself with xcodebuild and open replaced by stubs
# (a fake built cmux.app; nothing is built or launched) and checks what it
# writes against the vectors.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
TAG="x1"
BUNDLE_ID="com.cmuxterm.app.staging.${TAG}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-reloads-socket.XXXXXX")"
# reloads.sh writes the markers under the account home (getpwuid), as the app reads them.
ACCOUNT_HOME="$(perl -e 'print((getpwuid($<))[7])')"
MARKERS=("$ACCOUNT_HOME/.local/state/cmux/staging-${TAG}-last-socket-path" "/tmp/cmux-staging-${TAG}-last-socket-path")
for marker in "${MARKERS[@]}"; do
  if [[ -e "$marker" ]]; then cp -p "$marker" "$TMP_DIR/saved-$(basename "$marker")"; fi
done
cleanup() {
  for marker in "${MARKERS[@]}"; do
    saved="$TMP_DIR/saved-$(basename "$marker")"
    if [[ -e "$saved" ]]; then cp -p "$saved" "$marker"; else rm -f "$marker"; fi
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# reloads.sh stops a running app of the bundle id and removes its socket.
if pgrep -f "cmux STAGING ${TAG}.app/Contents/MacOS/" >/dev/null 2>&1 \
  || [[ -n "$(/usr/bin/lsappinfo find "bundleid=${BUNDLE_ID}" 2>/dev/null)" ]]; then
  fail "a ${BUNDLE_ID} app runs on this host; the test would stop it"
fi

# The socket the app uses: the vector's pre-move name, moved into the state
# folder when the path fits sun_path (ControlSocketPath.moved).
old="$(python3 -I - "$ROOT_DIR/schemas/build-identity/vectors.json" "$BUNDLE_ID" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
[case] = [c for c in doc["cases"] if c["bundle_id"] == sys.argv[2] and c["bundled_tag"] is None]
print(case["app_daemon"]["control_socket"])
PY
)"
expected="$ACCOUNT_HOME/.local/state/cmux/${old#/tmp/}"
if (( $(printf '%s' "$expected" | LC_ALL=C wc -c) > 103 )); then expected="$old"; fi

# Stubs: xcodebuild leaves a fake product, open records its environment.
STUBS="$TMP_DIR/bin"
DERIVED="$TMP_DIR/dd"
mkdir -p "$STUBS" "$TMP_DIR/home" "$TMP_DIR/cwd"
cat > "$STUBS/xcodebuild" <<STUB
#!/bin/sh
app="$DERIVED/Build/Products/Release/cmux.app"
mkdir -p "\$app/Contents/MacOS"
printf '#!/bin/sh\n' > "\$app/Contents/MacOS/cmux"
chmod +x "\$app/Contents/MacOS/cmux"
cat > "\$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.cmuxterm.app</string>
  <key>CFBundleExecutable</key><string>cmux</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
STUB
cat > "$STUBS/open" <<STUB
#!/bin/sh
printf '%s\n' "\${CMUX_SOCKET_PATH:-}" > "$TMP_DIR/open-socket"
STUB
chmod +x "$STUBS/xcodebuild" "$STUBS/open"

# CMUX_NEXT_TUI_BIN: reloads.sh fetches no same-tree cmux-tui (xcodebuild is a stub).
(cd "$TMP_DIR/cwd" && HOME="$TMP_DIR/home" PATH="$STUBS:$PATH" CMUX_NEXT_TUI_BIN="$TMP_DIR/cmux-tui" \
  bash "$ROOT_DIR/scripts/reloads.sh" --tag "$TAG" --derived-data "$DERIVED" >"$TMP_DIR/out" 2>&1) \
  || fail "reloads.sh failed: $(tail -20 "$TMP_DIR/out")"

plist="$DERIVED/Build/Products/Release/cmux STAGING ${TAG}.app/Contents/Info.plist"
[[ -f "$plist" ]] || fail "reloads.sh staged no app: $(tail -20 "$TMP_DIR/out")"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == "$BUNDLE_ID" ]] \
  || fail "staged bundle id is not $BUNDLE_ID"
lsenv="$(/usr/libexec/PlistBuddy -c 'Print :LSEnvironment:CMUX_SOCKET_PATH' "$plist" 2>/dev/null || true)"
[[ "$lsenv" == "$expected" ]] || fail "LSEnvironment CMUX_SOCKET_PATH is '$lsenv', the app listens on '$expected'"
echo "PASS: LSEnvironment names $expected"
launched="$(cat "$TMP_DIR/open-socket" 2>/dev/null || true)"
[[ "$launched" == "$expected" ]] || fail "the launch environment names '$launched', the app listens on '$expected'"
echo "PASS: the launch environment names $expected"
for marker in "${MARKERS[@]}"; do
  [[ "$(cat "$marker" 2>/dev/null || true)" == "$expected" ]] \
    || fail "marker $marker names '$(cat "$marker" 2>/dev/null || true)', the app listens on '$expected'"
done
echo "PASS: the last-socket-path markers name $expected"
