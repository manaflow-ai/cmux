#!/usr/bin/env bash
# Clears the cmux DEV app's persistent defaults before a CI test launch.
#
# cfprefsd keeps an app's defaults in the runner account's own domain: the
# per-run home the app host gets (HOME, CFFIXED_USER_HOME) does not move it.
# Every job on a Mac reads and writes that one domain, and it outlives the job,
# so values earlier runs left there reached later tests on that Mac only. The
# fleet Macs carried a visible right sidebar (on some in Dock mode), a saved
# window frame and a 75% terminal font magnification, and the tests that ran
# there failed their splits, created a Dock at window creation and measured
# the wrong font sizes (#15488). Start each launch from the app's defaults.
#
# Callers hold the Mac's GUI token, so no other test run uses the domain.
#
#   scripts/ci/reset-app-defaults.sh <DerivedData path>
set -euo pipefail

derived_data="${1:?usage: reset-app-defaults.sh <DerivedData path>}"
# A local run would wipe the settings of the tagged build it tests.
if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
  echo "reset-app-defaults: not a CI runner; leaving defaults alone" >&2
  exit 0
fi
app="$derived_data/Build/Products/Debug/cmux DEV.app"
if [ ! -d "$app" ]; then
  app="$(find "$derived_data" -path "*/Build/Products/Debug/cmux DEV.app" -print -quit 2>/dev/null || true)"
fi
if [ -z "$app" ]; then
  echo "reset-app-defaults: no cmux DEV.app under $derived_data; nothing reset" >&2
  exit 0
fi
info_plist="$app/Contents/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
# Only a DEV build's own domain: never a release app's settings.
case "$bundle_id" in
  com.cmuxterm.app.debug | com.cmuxterm.app.debug.*) ;;
  *)
    echo "reset-app-defaults: no cmux DEV bundle identifier in $info_plist; nothing reset" >&2
    exit 0
    ;;
esac
if defaults delete "$bundle_id" >/dev/null 2>&1; then
  echo "Cleared the persistent defaults earlier runs left in $bundle_id"
fi
