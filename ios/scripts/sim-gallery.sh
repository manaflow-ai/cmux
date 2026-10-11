#!/usr/bin/env bash
# Builds the iOS app for the simulator, installs it into an isolated simulator
# ($NX_SIM_UDID, e.g. from `nx-remote --sim`), and captures screenshots:
# the sign-in screen, Home in DEV preview (mock owner, no account), and the
# app's own prototype gallery (CMUX_IOS_GALLERY=1). Output: $NX_ARTIFACTS or ./artifacts/sim-gallery.
# Never targets a shared or user-visible simulator: it requires an explicit UDID.
set -euo pipefail
udid="${NX_SIM_UDID:?set NX_SIM_UDID to an isolated simulator}"
out="${NX_ARTIFACTS:-$PWD/artifacts/sim-gallery}"
derived="${SIM_GALLERY_DERIVED:-${NX_DERIVED_DATA:-/tmp}/cmux-ios-sim-gallery}"
bundle="dev.cmux.ios"
mkdir -p "$out"
xcodebuild -workspace ios/cmux.xcworkspace -scheme cmux-ios -configuration Debug \
  -destination "id=$udid" -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build \
  >"$out/build.log" 2>&1 || { grep -E "error:" "$out/build.log" | sort -u | head -40; exit 1; }
app="$derived/Build/Products/Debug-iphonesimulator/cmux.app"
xcrun simctl install "$udid" "$app"
shot() { xcrun simctl io "$udid" screenshot --type=png "$out/$1.png" >/dev/null; }
settle() { sleep "${1:-4}"; }  # capture script only: wait for launch animations

# SIM_GALLERY_ONLY=conversation: the Chief and group conversations on the
# shared render core (mock owner), light and dark, as real simulator frames.
if [[ "${SIM_GALLERY_ONLY:-}" == conversation ]]; then
  for kind in chief group; do
    for appearance in light dark; do
      xcrun simctl ui "$udid" appearance "$appearance"
      SIMCTL_CHILD_CMUX_IOS_HOME_PREVIEW=1 SIMCTL_CHILD_CMUX_IOS_OPEN_CONVERSATION="$kind" \
        xcrun simctl launch --terminate-running-process "$udid" "$bundle" >/dev/null
      settle 7; shot "conversation-$kind-$appearance"
    done
  done
  xcrun simctl ui "$udid" appearance light
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  ls -1 "$out"; exit 0
fi

# SIM_GALLERY_ONLY=homehost: the UIKit host on the render core: a group
# conversation (run grouping, sender names) at the default text size and at
# the largest accessibility size, and a search hit about 200 messages back
# (three older pages) opened from search, scrolled to the hit.
if [[ "${SIM_GALLERY_ONLY:-}" == homehost ]]; then
  xcrun simctl ui "$udid" appearance light
  for size in large accessibility-extra-extra-extra-large; do
    xcrun simctl ui "$udid" content_size "$size"
    SIMCTL_CHILD_CMUX_IOS_HOME_PREVIEW=1 SIMCTL_CHILD_CMUX_IOS_OPEN_CONVERSATION=group \
      xcrun simctl launch --terminate-running-process "$udid" "$bundle" >/dev/null
    settle 7; shot "homehost-group-$size"
  done
  xcrun simctl ui "$udid" content_size large
  SIMCTL_CHILD_CMUX_IOS_HOME_PREVIEW=1 SIMCTL_CHILD_CMUX_IOS_OPEN_SEARCH="blocking" \
    SIMCTL_CHILD_CMUX_IOS_OPEN_SEARCH_HIT="${SIM_GALLERY_SEARCH_HIT:-10}" \
    xcrun simctl launch --terminate-running-process "$udid" "$bundle" >/dev/null
  settle 9; shot "homehost-search-hit"
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  ls -1 "$out"; exit 0
fi

# SIM_GALLERY_ONLY=tapback: the tapback picker on the group conversation's
# newest incoming message (light, dark), then after a Heart sent through the
# store (the badge comes from the owner's update; Heart shows selected).
if [[ "${SIM_GALLERY_ONLY:-}" == tapback ]]; then
  for appearance in light dark; do
    xcrun simctl ui "$udid" appearance "$appearance"
    SIMCTL_CHILD_CMUX_IOS_HOME_PREVIEW=1 SIMCTL_CHILD_CMUX_IOS_OPEN_CONVERSATION=group \
      SIMCTL_CHILD_CMUX_IOS_OPEN_TAPBACK=open \
      xcrun simctl launch --terminate-running-process "$udid" "$bundle" >/dev/null
    settle 7; shot "tapback-open-$appearance"
  done
  xcrun simctl ui "$udid" appearance light
  SIMCTL_CHILD_CMUX_IOS_HOME_PREVIEW=1 SIMCTL_CHILD_CMUX_IOS_OPEN_CONVERSATION=group \
    SIMCTL_CHILD_CMUX_IOS_OPEN_TAPBACK=love \
    xcrun simctl launch --terminate-running-process "$udid" "$bundle" >/dev/null
  settle 8; shot "tapback-sent-love-light"
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  ls -1 "$out"; exit 0
fi

# SIM_GALLERY_ONLY=clientver: Home's update-required banner (the team's
# minimum version refuses this app, enterprise P17), light, dark, Japanese,
# the variant without a named version, and with the offline banner below it.
if [[ "${SIM_GALLERY_ONLY:-}" == clientver ]]; then
  for appearance in light dark; do
    xcrun simctl ui "$udid" appearance "$appearance"
    SIMCTL_CHILD_CMUX_IOS_HOME_PREVIEW=1 SIMCTL_CHILD_CMUX_IOS_PREVIEW_UPDATE_REQUIRED=2.4.0 \
      xcrun simctl launch --terminate-running-process "$udid" "$bundle" >/dev/null
    settle 6; shot "clientver-$appearance"
  done
  xcrun simctl ui "$udid" appearance light
  SIMCTL_CHILD_CMUX_IOS_HOME_PREVIEW=1 SIMCTL_CHILD_CMUX_IOS_PREVIEW_UPDATE_REQUIRED=2.4.0 \
    xcrun simctl launch --terminate-running-process "$udid" "$bundle" -AppleLanguages "(ja)" -AppleLocale ja_JP >/dev/null
  settle 6; shot "clientver-ja"
  SIMCTL_CHILD_CMUX_IOS_HOME_PREVIEW=1 SIMCTL_CHILD_CMUX_IOS_PREVIEW_UPDATE_REQUIRED= \
    xcrun simctl launch --terminate-running-process "$udid" "$bundle" >/dev/null
  settle 6; shot "clientver-noversion"
  # Both banners in the one header: update required above offline.
  SIMCTL_CHILD_CMUX_IOS_HOME_PREVIEW=1 SIMCTL_CHILD_CMUX_IOS_PREVIEW_UPDATE_REQUIRED=2.4.0 \
    SIMCTL_CHILD_CMUX_IOS_PREVIEW_OFFLINE=1 \
    xcrun simctl launch --terminate-running-process "$udid" "$bundle" >/dev/null
  settle 6; shot "clientver-offline"
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  ls -1 "$out"; exit 0
fi

if [[ "${SIM_GALLERY_ONLY:-}" != terminal ]]; then
xcrun simctl ui "$udid" appearance light
xcrun simctl launch --terminate-running-process "$udid" "$bundle" >/dev/null
settle 6; shot signin-light

SIMCTL_CHILD_CMUX_IOS_HOME_PREVIEW=1 xcrun simctl launch --terminate-running-process "$udid" "$bundle" >/dev/null
settle 5; shot home-preview-light
xcrun simctl ui "$udid" appearance dark
settle 2; shot home-preview-dark
xcrun simctl ui "$udid" appearance light
fi

# The mock host restores a Ghostty-encoded snapshot (grid generation 1), then
# after 10 s changes the grid (generation 2) and sends a new snapshot.
SIMCTL_CHILD_CMUX_IOS_HOME_PREVIEW=1 SIMCTL_CHILD_CMUX_IOS_TERMINAL_PREVIEW=1 \
  SIMCTL_CHILD_CMUX_IOS_TERMINAL_GRID_CHANGE_SECONDS=10 \
  xcrun simctl launch --terminate-running-process "$udid" "$bundle" >/dev/null
settle 6; shot terminal-mock-dark
settle 12; shot terminal-grid-change
tc="$(xcrun simctl get_app_container "$udid" "$bundle" data)"
cp "$tc"/Library/Caches/cmux-gallery/terminal*.json "$out/" 2>/dev/null || true
[[ "${SIM_GALLERY_ONLY:-}" == terminal ]] && { ls -1 "$out"; exit 0; }

SIMCTL_CHILD_CMUX_IOS_HOME_PREVIEW=1 SIMCTL_CHILD_CMUX_IOS_GALLERY=1 \
  xcrun simctl launch --terminate-running-process "$udid" "$bundle" >/dev/null
settle "${SIM_GALLERY_WAIT:-20}"
container="$(xcrun simctl get_app_container "$udid" "$bundle" data)"
if [[ -d "$container/Library/Caches/cmux-gallery" ]]; then
  cp "$container"/Library/Caches/cmux-gallery/*.png "$out/" 2>/dev/null || true
fi
xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
ls -1 "$out"
