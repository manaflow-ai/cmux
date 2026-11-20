#!/usr/bin/env bash
# nightly.yml verify-nightly-identity-legacy: "Hand the tested app's Info.plist to publish". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# publish-nightly-identity-legacy runs on Linux, which cannot mount the
# DMG: it writes the appcast item (scripts/ci/tip_appcast_linux.py) from
# the Info.plist of the app in the DMG this job tested. Read-only data.
set -euo pipefail
dmg="legacy-signed/${LEGACY_DMG_PREFIX}${NIGHTLY_BUILD}.dmg"
[ "$(shasum -a 256 "$dmg" | awk '{print $1}')" = "${VERIFIED_DMG_SHA256}" ] || { echo "the DMG changed after its verification" >&2; exit 1; }
mnt="$(mktemp -d "$RUNNER_TEMP/legacy-plist.XXXXXX")"
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null
mkdir -p tested-plist
cp "$mnt/cmux NIGHTLY.app/Contents/Info.plist" tested-plist/Info.plist
hdiutil detach "$mnt" >/dev/null || hdiutil detach -force "$mnt" >/dev/null
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" tested-plist/Info.plist | grep -Fxq "$NIGHTLY_BUILD"
