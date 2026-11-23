#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Screen Recording and Accessibility grants of a signed cmux NEXT app belong to one holder: its
# Screen Sharing helper ("<app> Helper.app", executable cmux-screen-sharing, plans/cmux-next/screen-sharing-helper.md). macOS
# keeps a grant under the holder's bundle id and designated requirement, so a build that changes
# either, or ships a second holder, asks the person again. This fails such a build before it ships.
#
#   scripts/ci/check-screen-share-identity.sh <signed app>
#
# Checks: exactly one helper in Contents/Library, named "<app> Helper.app" (a legacy "<app> Screen
# Sharing.app", the name before 2026-11-22, counts as a helper but fails: the stamp renames it); its
# bundle id is "<app id>.screen-sharing" (and, for a channel pinned below, that exact id); its
# designated requirement names that id and the app's Developer ID team, with no cdhash
# (an ad-hoc signature's requirement is its cdhash, which every build changes); and no second
# holder (cmux Computer Use.app, com.cmuxterm.cua) beside it.
# The team is the app's own (pinned to the shipped team for a pinned channel). sign-cmux-bundle.sh
# runs it on every Developer ID signing; check-signed-app.sh again on the signed NIGHTLY.
# CMUX_PLISTBUDDY and CMUX_CODESIGN_TOOL stand in for the tools in
# scripts/ci/tests/check-screen-share-identity.test.sh, which runs on Linux.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <signed app>" >&2; exit 2; }
APP_PATH="$1"
PLISTBUDDY="${CMUX_PLISTBUDDY:-/usr/libexec/PlistBuddy}"
CODESIGN="${CMUX_CODESIGN_TOOL:-/usr/bin/codesign}"
SHIPPED_TEAM=7WLXT3NR37

# The helper id each shipped channel's grants live under today (signed by $SHIPPED_TEAM). Changing
# one re-asks every person on that channel for Screen Recording: change it here on purpose, in the
# same PR, or not at all.
pinned_helper_id() {
  case "$1" in
    com.cmuxterm.app.nightly) echo com.cmuxterm.app.nightly.screen-sharing ;;
    com.cmuxterm.app.nightly.cmux-next-stable) echo com.cmuxterm.app.nightly.cmux-next-stable.screen-sharing ;;
    *) echo "" ;;
  esac
}

fail() { echo "error: $*" >&2; exit 1; }

[[ -f "$APP_PATH/Contents/Info.plist" ]] || fail "no Info.plist in $APP_PATH"
app_id="$("$PLISTBUDDY" -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist")"

helpers=()
for helper in "$APP_PATH/Contents/Library/"*" Helper.app"; do
  # Another bundle may end in " Helper.app"; the helper is the one with its executable.
  [[ -e "$helper/Contents/MacOS/cmux-screen-sharing" ]] && helpers+=("$helper")
done
for helper in "$APP_PATH/Contents/Library/"*" Screen Sharing.app"; do
  [[ -d "$helper" ]] && helpers+=("$helper")
done
# Without a helper the app asks for Screen Recording itself (MacScreenShareHost.requestInApp): the
# app becomes a second holder, and granting it needs the app to relaunch.
[[ ${#helpers[@]} -eq 1 ]] || fail "$APP_PATH holds ${#helpers[@]} Screen Sharing helpers, not 1"
helper="${helpers[0]}"
[[ "$helper" == *" Helper.app" ]] \
  || fail "$(basename "$helper") has the name from before the rename; bundle-screen-sharing-helper.sh --stamp names it '<app> Helper.app'"

other="$APP_PATH/Contents/Library/cmux Computer Use.app"
[[ ! -e "$other" ]] || fail "$other ships beside $(basename "$helper"): a second Screen Recording holder asks the person twice"

helper_id="$("$PLISTBUDDY" -c "Print :CFBundleIdentifier" "$helper/Contents/Info.plist")"
[[ "$helper_id" == "$app_id.screen-sharing" ]] \
  || fail "$(basename "$helper") is $helper_id, not $app_id.screen-sharing"
pinned="$(pinned_helper_id "$app_id")"
[[ -z "$pinned" || "$helper_id" == "$pinned" ]] \
  || fail "$app_id's helper is $helper_id; its grants live under $pinned (pinned in $0)"

# The helper's team is the app's: a shipped channel's is $SHIPPED_TEAM, another signer's build its own.
TEAM="$("$CODESIGN" -dv "$APP_PATH" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ -n "$TEAM" && "$TEAM" != "not set" ]] || fail "$APP_PATH has no team: it is not Developer ID signed"
[[ -z "$pinned" || "$TEAM" == "$SHIPPED_TEAM" ]] || fail "$app_id is signed by team $TEAM, not $SHIPPED_TEAM"

requirement="$("$CODESIGN" -d -r- "$helper" 2>&1 | sed -n 's/^designated => //p')"
[[ -n "$requirement" ]] || fail "$(basename "$helper") has no designated requirement"
case "$requirement" in
  *cdhash*) fail "$(basename "$helper")'s requirement is a cdhash (ad-hoc): $requirement" ;;
esac
[[ "$requirement" == *"identifier \"$helper_id\""* ]] \
  || fail "$(basename "$helper")'s requirement does not name $helper_id: $requirement"
[[ "$requirement" == *"anchor apple generic"* && "$requirement" == *"certificate leaf[subject.OU] = \"$TEAM\""* ]] \
  || fail "$(basename "$helper")'s requirement is not Developer ID team $TEAM: $requirement"

echo "==> Screen Sharing helper identity: $helper_id, Developer ID $TEAM, no cdhash"
