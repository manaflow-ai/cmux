#!/usr/bin/env bash
# Install-and-open check for a nightly-next DMG built without the app's own stapled
# ticket (CMUX_STAPLE_APP_IN_DMG=false). CLI only; builds nothing; touches no installed app.
#   usage: scripts/ci/check-unstapled-nightly-install.sh DMG_URL   (by hand on a Mac; no CI job runs it)
# Downloads into a fresh temp dir with a quarantine flag (as a browser download), checks
# the DMG and the copied-out app with Gatekeeper, then opens the quarantined copy and checks
# it stays up for 20 s. It refuses the launch (Gatekeeper checks still run) while any app
# with the same bundle id runs: cmux keeps one instance per bundle id, so a launch would end
# the person's own copy. It stops only the PID it launched, and deletes only its temp dir.
set -uo pipefail
url="${1:?usage: check-unstapled-nightly-install.sh DMG_URL}"
work="$(mktemp -d /tmp/nightly-no-staple-check.XXXXXX)"
dmg="$work/check.dmg"
mnt="$work/mnt"
mkdir -p "$mnt" "$work/Applications"
pass=0; fail=0
step() { local what=$1; shift; echo "== $what: $*"; if "$@"; then echo "PASS $what"; pass=$((pass+1)); else echo "FAIL $what (exit $?)"; fail=$((fail+1)); fi; }
cleanup() { hdiutil detach "$mnt" -force >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

curl -fsSL --retry 3 -o "$dmg" "$url" || { echo "FAIL download $url"; exit 1; }
shasum -a 256 "$dmg"
# What Safari or Chrome sets on a download: Gatekeeper then assesses it on first open.
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;" "$dmg"

step "DMG ticket" xcrun stapler validate "$dmg"
step "DMG Gatekeeper (open)" spctl -a -vv -t open --context context:primary-signature "$dmg"
hdiutil attach "$dmg" -nobrowse -readonly -noautofsck -mountpoint "$mnt" >/dev/null || { echo "FAIL attach"; exit 1; }
app_in="$(find "$mnt" -maxdepth 1 -name '*.app' -type d -print -quit)"
[ -n "$app_in" ] || { echo "FAIL no app in the DMG"; exit 1; }
echo "== app's own ticket (expected absent with one notary round):"
xcrun stapler validate "$app_in" && echo "INFO the app carries its own ticket" || echo "INFO the app has no ticket of its own"
# A drag install: Finder's copy keeps the quarantine flag the DMG gave its contents.
app="$work/Applications/$(basename "$app_in")"
ditto "$app_in" "$app"
hdiutil detach "$mnt" -force >/dev/null 2>&1 || true
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;" "$app"
step "codesign" codesign --verify --deep --strict "$app"
out="$(spctl -a -vv --type execute "$app" 2>&1)"; rc=$?; echo "$out"
if [ "$rc" = 0 ] && grep -Fq 'source=Notarized Developer ID' <<<"$out"; then echo "PASS app Gatekeeper (notarized, online)"; pass=$((pass+1)); else echo "FAIL app Gatekeeper"; fail=$((fail+1)); fi
step "syspolicy_check distribution" syspolicy_check distribution "$app"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
if [ -n "$(lsappinfo find bundleid="$bundle_id" 2>/dev/null)" ]; then
  echo "SKIP launch: $bundle_id is running on this Mac (a launch would end it); run again when it is quit"
else
  echo "== launch the quarantined copy (Gatekeeper's first-open check)"
  open -g -n "$app" || { echo "FAIL open"; fail=$((fail+1)); }
  pid=""
  for _ in $(seq 1 20); do pid="$(pgrep -f "^$app/Contents/MacOS/$exe" | head -1)"; [ -n "$pid" ] && break; sleep 1; done
  if [ -z "$pid" ]; then
    echo "FAIL launch: no process within 20 s"; fail=$((fail+1))
    log show --last 2m --style compact --predicate 'process == "syspolicyd" OR subsystem == "com.apple.syspolicy"' 2>/dev/null | tail -20
  else
    sleep 20  # sleep-ok: the check is that the app stays up 20 s after launch
    if kill -0 "$pid" 2>/dev/null; then echo "PASS launch: pid $pid up 20 s"; pass=$((pass+1)); else echo "FAIL launch: pid $pid exited"; fail=$((fail+1)); fi
    kill "$pid" 2>/dev/null; for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
  fi
fi
echo "RESULT pass=$pass fail=$fail"
[ "$fail" = 0 ]
