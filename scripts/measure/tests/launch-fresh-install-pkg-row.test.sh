#!/usr/bin/env bash
# launch-fresh-install.sh row k: pkg_postinstall runs the installer package's own postinstall
# (scripts/cmux-next/pkg/postinstall) on a copy as this user, with no root: the shims stand in for launchctl asuser,
# sudo -u and chown. A stand-in app records every run of its executable and helper; the test checks the postinstall
# ran its waves on the copy (exec pre-warm, CLI, helper, Chromium start) and left the launch marker in the launch's
# HOME. No Mac: PlistBuddy and console are stand-ins, so this proves the wiring, NOT the timing on a fleet Mac.
# Run: bash scripts/measure/tests/launch-fresh-install-pkg-row.test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
fail() { echo "launch-fresh-install pkg row: $*" >&2; exit 1; }

app="$root/copy/cmux NEXT.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin" "$app/Contents/Frameworks/cmux NEXT Helper.app/Contents/MacOS"
cat >"$root/plist" <<'P'
CFBundleExecutable=cmux-next
CFBundleIdentifier=com.cmuxterm.next.test
CFBundleVersion=4242
P
# PlistBuddy -c 'Print :KEY' PLIST, from the flat file above.
cat >"$root/plistbuddy" <<P
#!/bin/sh
k="\${2#Print :}"; sed -n "s/^\$k=//p" "$root/plist"
P
rec() { printf '#!/bin/sh\necho "%s $*" >>"%s"\n' "$1" "$root/runs" >"$2"; chmod 0755 "$2"; }
rec exe "$app/Contents/MacOS/cmux-next"
rec cli "$app/Contents/Resources/bin/cmux"
rec helper "$app/Contents/Frameworks/cmux NEXT Helper.app/Contents/MacOS/cmux NEXT Helper"
chmod 0755 "$root/plistbuddy"

OUT="$root/out"
mkdir -p "$OUT/home-k-1"
env -u RUNNER_TEMP OUT="$OUT" LF_PLISTBUDDY="$root/plistbuddy" APP="$app" bash -c '
  source "$1"
  console() { "$@"; }
  pkg_postinstall "$APP" k-1
' _ "$here/launch-fresh-install.sh" >"$root/log" 2>&1 || { cat "$root/log"; fail "pkg_postinstall failed"; }

grep -q 'cmux pkg pre-warm: done' "$root/log" || { cat "$root/log"; fail "the postinstall did not finish"; }
for want in "exe --cmux-prewarm-launch" "exe --cmux-prewarm-chromium" "cli --version" "helper --version"; do
  grep -qx -- "$want" "$root/runs" || { cat "$root/runs" "$root/log"; fail "no run: $want"; }
done
marker="$OUT/home-k-1/h/Library/Application Support/com.cmuxterm.next.test/launch-prewarm"
[[ "$(cat "$marker" 2>/dev/null)" == 4242 ]] || { cat "$root/log"; fail "launch marker not in the launch's HOME"; }
grep -q '^EXECUTABLE=cmux-next$' "$OUT/pkgscripts-k-1/pkg.env" || fail "pkg.env does not name the executable"
echo "launch-fresh-install pkg row: all passed"
