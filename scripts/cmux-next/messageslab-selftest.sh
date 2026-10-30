#!/usr/bin/env bash
# MessagesLab's own self-test on the vendored pin's upstream sources, for the Home pin gate.
# Run it on cmux-lawrence-2 (GUI host), never on a laptop.
#
#   messageslab-selftest.sh SRC [--key]
#       SRC: a `git archive` of the pinned MessagesLab commit with appkit-native, catalyst,
#       appkit-port, tools/diff-harness, tools/interactions/vdisplay.m, shared/conversation.json and
#       shared/assets (the vendor.tsv pin, see sync-messageslab.sh).
#       Builds MessagesLabAppKitNative with swiftc as home-messageslab-harness.sh's oracle does, plus
#       MESSAGESLAB_SELFTEST (upstream's SELFTEST=1 build.sh): its link-preview fallback step serves a
#       local page and LinkGuard.testOrigin lets that one 127.0.0.1 origin through. A release build has
#       no such exception, so this build is gate-only: it goes to its own mktemp directory, never to a
#       DerivedData or product an app build uses, and is not shipped. The run fails when the link
#       fallback step skipped its page.
#       Default: `--selftest` on a private 2x virtual display (every step but the "key: " ones; the
#       window never becomes key). Pass when every step passes.
#       --key: `--selftest-key`, only the "key: " steps (the field's caret needs a key window). The
#       app is launched active with `open -n -W`, so it takes the key window on the host: run it in
#       `nx-remote --needs input` (the input lock). It is stopped by its own PID after 120 s
#       (SIGTERM, then SIGKILL). Pass when every key step passes and there is at least one.
#   Prints "selftest PASSED / TOTAL" and each failing step.
set -uo pipefail
src="${1:?usage: messageslab-selftest.sh SRC [--key]}"; key="${2:-}"
# The real path: an app launched by open runs as /private/tmp/..., and the PID lookup matches its path.
out="$(cd "$(mktemp -d /tmp/messageslab-selftest.XXXX)" && pwd -P)"
app="$out/MessagesLabAppKitNative.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
files=( "$src"/appkit-native/Sources/*.swift )
while IFS= read -r f; do files+=( "$src/catalyst/Sources/$f" ); done \
  < <(sed -n 's|.*path: \.\./catalyst/Sources/\([A-Za-z0-9_]*\.swift\).*|\1|p' "$src/appkit-native/project.yml")
files+=( "$src"/appkit-port/Sources/Shim/{UIKitNames,RoundedRect,LayerViews}.swift "$src"/tools/diff-harness/{Harness,LiveProbes}.swift )
xcrun swiftc -swift-version 5 -Onone -D APPKIT_NATIVE -D MESSAGESLAB_SELFTEST -target arm64-apple-macos14.0 -lsqlite3 -module-name MessagesLabAppKitNative \
  -o "$app/Contents/MacOS/MessagesLabAppKitNative" "${files[@]}" > "$out/build.log" 2>&1 || { grep -m10 'error:' "$out/build.log"; exit 3; }
cp "$src/catalyst/springs.json" "$src/shared/conversation.json" "$app/Contents/Resources/" || exit 3
cp -R "$src/shared/assets" "$app/Contents/Resources/assets" && cp -R "$src/catalyst/Fixtures/real" "$app/Contents/Resources/real" || exit 3
# Its own bundle id per run: `open -n` and the PID lookup below can only find this build.
id="com.cmux.prototype.MessagesLab.appkit-native.gate$$"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>MessagesLabAppKitNative</string><key>CFBundleIdentifier</key><string>$id</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
exe="$app/Contents/MacOS/MessagesLabAppKitNative"
json="$out/selftest.json"
vd=""
# On every exit (also when nx-remote stops this script): this run's app (only its own unique path, by
# PID) and the virtual display end.
cleanup() {
  for p in $(pgrep -f "^$exe"); do kill -TERM "$p" 2>/dev/null; done
  [ -n "$vd" ] && kill "$vd" 2>/dev/null
  return 0
}
trap cleanup EXIT

# Waits for PID up to SECS (a test harness bound on an external process, not app code), then stops it.
stop_after() {
  local pid=$1 secs=$2 k=0
  while kill -0 "$pid" 2>/dev/null && [ $k -lt $((secs * 4)) ]; do sleep 0.25; k=$((k + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    echo "selftest: still running after ${secs} s, stopping pid $pid"
    kill -TERM "$pid" 2>/dev/null; sleep 2
    pgrep -f "^$exe" | grep -qx "$pid" && kill -KILL "$pid" 2>/dev/null
  fi
  return 0
}

if [ "$key" = "--key" ]; then
  # Launched active (the key window); `open -W` returns when the app exits.
  open -n -W --stdout "$out/app.log" --stderr "$out/app.log" "$app" --args -ApplePersistenceIgnoreState YES --selftest "$json" --selftest-key &
  opener=$!
  pid=""
  for _ in $(seq 40); do pid="$(pgrep -f "^$exe" | head -1)"; [ -n "$pid" ] && break; sleep 0.25; done
  [ -n "$pid" ] || { echo "selftest: the app did not start ($exe)"; cat "$out/app.log" 2>/dev/null; kill "$opener" 2>/dev/null; exit 3; }
  stop_after "$pid" 120
  wait "$opener" 2>/dev/null
else
  clang -fobjc-arc -framework Foundation -framework CoreGraphics -framework AppKit "$src/tools/interactions/vdisplay.m" -o "$out/vdisplay" || exit 3
  # The 4th argument is the display's own lifetime (s): it ends by itself even if this script is killed.
  "$out/vdisplay" 1800 1169 60 400 > "$out/vd.log" 2>&1 & vd=$!
  for _ in $(seq 80); do grep -q origin "$out/vd.log" && break; sleep 0.25; done  # test harness: wait for the display
  "$exe" -ApplePersistenceIgnoreState YES --selftest "$json" > "$out/app.log" 2>&1 & p=$!
  stop_after "$p" 300
  wait "$p" 2>/dev/null
fi

/usr/bin/python3 - "$json" "$key" <<'PY'
import json, os, sys
if not os.path.exists(sys.argv[1]):
    print("selftest: no result (the app wrote no", sys.argv[1] + ")"); sys.exit(1)
d = json.load(open(sys.argv[1])); steps = d["steps"]
print("selftest" + (" (key)" if sys.argv[2] == "--key" else ""), len(steps) - d["failed"], "/", len(steps))
for s in steps:
    if not s["pass"]: print("  FAIL", s["step"], "->", s["error"])
m = d.get("measures") or {}
link = [s for s in steps if s["step"].startswith("link fallback:")]
# A normal run must have the link step (a renamed step would otherwise pass unchecked); a key run has none.
full = bool(link) or sys.argv[2] == "--key"
if not full:
    print("link fallback: step missing (renamed upstream?)")
if link:
    # The self-test build serves a local page (fallbackPageRequests); a release-like build skips it.
    full = "fallbackSkipped" not in m and int(m.get("fallbackPageRequests") or 0) > 0
    print("link fallback:", "pass" if link[0]["pass"] else "FAIL", "| full form (local page served):", full,
          "| page requests:", m.get("fallbackPageRequests"), "| skipped:", m.get("fallbackSkipped"),
          "| fallback log:", len(m.get("fallbackLog") or []))
sys.exit(0 if steps and d["failed"] == 0 and full else 1)
PY
