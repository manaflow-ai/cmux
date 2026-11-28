#!/usr/bin/env bash
# The "Bundle server helper" Xcode phase must not depend on the app's
# processed Info.plist: Xcode may write it after the script phases, so a
# rebuild of an existing tag failed with "Print: Entry, ':CFBundleIdentifier',
# Does Not Exist". The phase names the build's own PRODUCT_BUNDLE_IDENTIFIER.
# The same phase writes the server LaunchAgent plist that ServerLaunchAgent
# registers with SMAppService.agent (server.md 4.3), and `--stamp` (run by
# scripts/sign-cmux-bundle.sh) rewrites both plists from the final bundle id.
# swiftc is a stub here: no compiler, no network, no signing.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/build/app.app/Contents/MacOS" "$TMP/build/app.app/Contents/Resources/bin" "$TMP/temp"
# The bundled cmux CLI ("Bundle cmux-tui" runs before this phase).
printf '#!/bin/sh\nexit 0\n' > "$TMP/build/app.app/Contents/Resources/bin/cmux"
chmod +x "$TMP/build/app.app/Contents/Resources/bin/cmux"
cat > "$TMP/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
# xcrun swiftc ... -o <out> ...: create every -o / -emit-module-path output.
shift
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" || "$prev" == "-emit-module-path" ]]; then mkdir -p "$(dirname "$arg")"; : > "$arg"; fi
  prev="$arg"
done
STUB
chmod +x "$TMP/bin/xcrun"
run() {
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TARGET_BUILD_DIR="$TMP/build" WRAPPER_NAME=app.app \
    TARGET_TEMP_DIR="$TMP/temp" SRCROOT="$ROOT" ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CONFIGURATION=Debug \
    PRODUCT_BUNDLE_IDENTIFIER=com.cmuxterm.app.debug.testtag \
    /bin/bash "$ROOT/scripts/cmux-next/bundle-server-helper.sh" 2>&1
}
# No processed Info.plist yet (Xcode writes it later on a rebuild).
if ! out=$(run); then printf 'phase failed without the processed Info.plist:\n%s\n' "$out" >&2; exit 1; fi
plist="$TMP/build/app.app/Contents/Library/LaunchDaemons/com.cmux.server.helper.plist"
label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist")
[[ "$label" == "com.cmuxterm.app.debug.testtag.server-helper" ]] || { echo "label: $label" >&2; exit 1; }
# A stale processed Info.plist from another bundle id does not win.
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.example.stale' "$TMP/build/app.app/Contents/Info.plist" >/dev/null
run >/dev/null
label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist")
[[ "$label" == "com.cmuxterm.app.debug.testtag.server-helper" ]] || { echo "stale label: $label" >&2; exit 1; }

agent="$TMP/build/app.app/Contents/Library/LaunchAgents/com.cmux.server.plist"
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null; }
expect() { # <plist> <key> <value>
  local got
  got=$(pb "$2" "$1") || { echo "$1: missing $2" >&2; exit 1; }
  [[ "$got" == "$3" ]] || { printf '%s: %s is %q, want %q\n' "$1" "$2" "$got" "$3" >&2; exit 1; }
}
check_agent() { # <bundle id>
  [[ -f "$agent" ]] || { echo "no server LaunchAgent plist for $1" >&2; exit 1; }
  plutil -lint "$agent" >/dev/null
  expect "$agent" Label "$1.server"
  expect "$agent" BundleProgram "Contents/Resources/bin/cmux"
  expect "$agent" ProgramArguments:0 "Contents/Resources/bin/cmux"
  expect "$agent" ProgramArguments:1 host
  expect "$agent" ProgramArguments:2 run
  # The mode is an argument, not an environment variable: launchd passes a
  # plist environment to every child, including the user's shells.
  expect "$agent" ProgramArguments:3 --mode
  expect "$agent" ProgramArguments:4 user
  if pb ProgramArguments:5 "$agent" >/dev/null; then echo "extra ProgramArguments" >&2; exit 1; fi
  # Restart only after a failure: a clean `cmux host run` exit (the host was
  # disabled) stays down. At most one restart per 10 s.
  keepalive=$(plutil -extract KeepAlive json -o - "$agent") || { echo "no KeepAlive" >&2; exit 1; }
  [[ "$keepalive" == '{"SuccessfulExit":false}' ]] || { echo "KeepAlive is $keepalive" >&2; exit 1; }
  throttle=$(pb ThrottleInterval "$agent") || { echo "no ThrottleInterval" >&2; exit 1; }
  [[ "$(plutil -type ThrottleInterval "$agent")" == integer && "$throttle" -ge 10 ]] \
    || { echo "ThrottleInterval $throttle is not an integer >= 10" >&2; exit 1; }
  expect "$agent" RunAtLoad true
  expect "$agent" ProcessType Standard
  expect "$agent" AssociatedBundleIdentifiers:0 "$1"
  # No environment, no secrets, no per-user paths: the plist is sealed in a
  # signed bundle that every user of the Mac shares.
  for key in EnvironmentVariables StandardOutPath StandardErrorPath UserName MachServices; do
    if pb "$key" "$agent" >/dev/null; then echo "agent plist carries $key" >&2; exit 1; fi
  done
}
check_agent com.cmuxterm.app.debug.testtag
# One golden, two writers: cmux-server-core's app_service_agent_plist renders
# the same bytes for this bundle id (tests/units_golden.rs). plutil writes the
# canonical form (sorted keys, tab indent), so the files compare byte for byte.
golden="$ROOT/cmux-tui/crates/cmux-server-core/tests/fixtures/app-service-agent.plist"
# On a byte mismatch, the parsed content tells a plutil format change (same
# JSON) apart from a real content change.
if ! cmp -s "$golden" "$agent"; then
  diff "$golden" "$agent" >&2 || true
  if [[ "$(plutil -convert json -o - "$golden")" == "$(plutil -convert json -o - "$agent")" ]]; then
    echo "plutil format drift: $agent has the golden's content in other bytes ($golden)" >&2
  else
    echo "content drift: $agent differs from $golden" >&2
  fi
  exit 1
fi

# --stamp follows the FINAL bundle id (nightly renames the bundle after the build).
stamp() { env -i PATH="/usr/bin:/bin" /bin/bash "$ROOT/scripts/cmux-next/bundle-server-helper.sh" --stamp "$TMP/build/app.app" >/dev/null; }
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.cmuxterm.app.nightly' "$TMP/build/app.app/Contents/Info.plist" >/dev/null
stamp
check_agent com.cmuxterm.app.nightly
label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist")
[[ "$label" == "com.cmuxterm.app.nightly.server-helper" ]] || { echo "stamp helper label: $label" >&2; exit 1; }

# No bundled CLI: no agent plist (ServerLaunchAgent then reports "not in this
# build"); the helper is independent of the CLI.
mv "$TMP/build/app.app/Contents/Resources/bin/cmux" "$TMP/cmux.saved"
stamp
[[ ! -e "$agent" ]] || { echo "agent plist kept without a bundled cmux" >&2; exit 1; }
[[ -f "$plist" ]] || { echo "helper plist dropped without a bundled cmux" >&2; exit 1; }
mv "$TMP/cmux.saved" "$TMP/build/app.app/Contents/Resources/bin/cmux"

# Stable carries neither the helper nor the agent: the server is DEV and NIGHTLY only.
stamp
[[ -f "$agent" ]] || { echo "agent plist not restored" >&2; exit 1; }
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.cmuxterm.app' "$TMP/build/app.app/Contents/Info.plist" >/dev/null
stamp
for f in "$agent" "$plist" "$TMP/build/app.app/Contents/Resources/libexec/cmux-server-helper"; do
  [[ ! -e "$f" ]] || { echo "stable bundle keeps $f" >&2; exit 1; }
done
[[ ! -d "$TMP/build/app.app/Contents/Library/LaunchAgents" ]] || { echo "stable bundle keeps an empty LaunchAgents" >&2; exit 1; }
printf 'bundle-server-helper tests: ok\n'
