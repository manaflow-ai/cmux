#!/usr/bin/env bash
# scripts/sign-cmux-bundle-helpers.sh (steps 0-1 of sign-cmux-bundle.sh) signs
# every Mach-O helper under Contents/Resources/bin and libexec, the root
# cmux-server-helper with no entitlements, and stamps the server's launchd
# plists from the FINAL bundle id. codesign and file are stubs: no keychain.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/tools"
cat > "$TMP/tools/codesign" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CODESIGN_LOG"
STUB
cat > "$TMP/tools/file" <<'STUB'
#!/usr/bin/env bash
# file -b <path>
if [[ "$(head -c 5 "$2")" == MACHO ]]; then echo "Mach-O 64-bit executable arm64"; else echo "ASCII text"; fi
STUB
chmod +x "$TMP/tools/codesign" "$TMP/tools/file"

make_app() { # <app> <bundle id>
  local app="$1"
  mkdir -p "$app/Contents/Resources/bin" "$app/Contents/Resources/libexec" "$app/Contents/MacOS"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $2" "$app/Contents/Info.plist" >/dev/null
  for f in bin/cmux bin/cmux-diff-sidecar bin/cmux-app-host libexec/cmux-server-helper libexec/cmux-extra-helper; do
    printf 'MACHO\n' > "$app/Contents/Resources/$f"
    chmod +x "$app/Contents/Resources/$f"
  done
  printf '#!/bin/sh\n' > "$app/Contents/Resources/bin/cmux-shell-hook"
  chmod +x "$app/Contents/Resources/bin/cmux-shell-hook"
  ln -s cmux "$app/Contents/Resources/bin/cmux-tui"
}
sign() { # <app> <log>
  CODESIGN_LOG="$2" CMUX_CODESIGN_TOOL="$TMP/tools/codesign" CMUX_FILE_TOOL="$TMP/tools/file" \
    "$ROOT/scripts/sign-cmux-bundle-helpers.sh" "$1" "$ROOT/cmux-helper.entitlements" "Developer ID Application: Test (TEAMID1234)"
}

# 1. A nightly bundle: every Mach-O helper is listed and signed with the team identity.
APP="$TMP/nightly/cmux NIGHTLY.app"
make_app "$APP" com.cmuxterm.app.nightly
out=$(sign "$APP" "$TMP/nightly.log") || fail "signing failed: $out"
for f in "$APP"/Contents/Resources/libexec/* "$APP"/Contents/Resources/bin/cmux "$APP"/Contents/Resources/bin/cmux-diff-sidecar "$APP"/Contents/Resources/bin/cmux-app-host; do
  rel="${f#"$APP"/Contents/Resources/}"
  grep -q "^==> signing .*$rel" <<<"$out" || fail "output does not list $rel: $out"
  grep -q -- "--sign Developer ID Application: Test (TEAMID1234) .*$f\$" "$TMP/nightly.log" \
    || fail "$rel was not signed with the team identity"
done
[[ "$(grep -c -- '--sign' "$TMP/nightly.log")" == 5 ]] || fail "expected 5 signatures: $(cat "$TMP/nightly.log")"
helper_line=$(grep -- '/libexec/cmux-server-helper$' "$TMP/nightly.log")
[[ "$helper_line" == *"--options runtime --timestamp"*"--identifier cmux-server-helper"* ]] \
  || fail "root helper not signed with the hardened runtime, a timestamp and its identifier: $helper_line"
[[ "$helper_line" != *--entitlements* ]] || fail "root helper got entitlements: $helper_line"
grep -q -- "--entitlements .*cmux-helper.entitlements .*/libexec/cmux-extra-helper\$" "$TMP/nightly.log" \
  || fail "other libexec helpers must get the helper entitlements"
grep -q 'cmux-shell-hook\|bin/cmux-tui$' "$TMP/nightly.log" && fail "a script or symlink was codesigned"

# The launchd plists follow the final bundle id (they are sealed by the app signature).
label() { /usr/libexec/PlistBuddy -c 'Print :Label' "$1"; }
[[ "$(label "$APP/Contents/Library/LaunchDaemons/com.cmux.server.helper.plist")" == com.cmuxterm.app.nightly.server-helper ]] \
  || fail "helper plist label"
[[ "$(label "$APP/Contents/Library/LaunchAgents/com.cmux.server.plist")" == com.cmuxterm.app.nightly.server ]] \
  || fail "server agent plist label"

# 2. A stable bundle carries no server helper and no server agent.
APP="$TMP/stable/cmux.app"
make_app "$APP" com.cmuxterm.app
sign "$APP" "$TMP/stable.log" >/dev/null || fail "stable signing failed"
[[ ! -e "$APP/Contents/Resources/libexec/cmux-server-helper" ]] || fail "stable keeps the server helper"
[[ ! -e "$APP/Contents/Library/LaunchDaemons" && ! -e "$APP/Contents/Library/LaunchAgents" ]] || fail "stable keeps server plists"
grep -q 'cmux-server-helper' "$TMP/stable.log" && fail "stable signed a removed helper"
grep -q -- '/libexec/cmux-extra-helper$' "$TMP/stable.log" || fail "stable did not sign the other libexec helper"

echo "sign-cmux-bundle-helpers tests: ok"
