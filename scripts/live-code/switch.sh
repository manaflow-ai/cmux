#!/usr/bin/env bash
# Switch one tag between its live code build and its regular build (docs/cmux-next/live-code.md).
# A live code build pays for live code all the time it runs, whatever Labs > Live Code says:
# CmuxNextApp's calls to its own functions go through pointers dyld can repoint, and nothing in it
# is stripped as unused. So turning the Labs switch off alone keeps that build. This keeps the two
# builds side by side, each in its own DerivedData and both warm, and swaps which one runs.
#   scripts/live-code/switch.sh on [TAG]      live code build (built or brought up to date), Live Code on
#   scripts/live-code/switch.sh off [TAG]     regular build (built or brought up to date), Live Code off
#   scripts/live-code/switch.sh status [TAG]
# TAG defaults to mine. Both builds have the tag's name, bundle id and settings, so the swap keeps
# the tag's windows and sessions. Each swap runs the tag's reload, which compiles only what changed
# since that build, then quits the running app and launches the other one.
# The live code build lives in ~/Library/Caches/cmux-next/live-code-builds/TAG (CMUX_LIVE_CODE_BUILDS),
# with the xcodebuild.log scripts/live-code/patch.py compiles patches from.
set -euo pipefail
mode="${1:-}"
tag="${2:-mine}"
case "$mode" in
  on | off | status) ;;
  *)
    echo "usage: scripts/live-code/switch.sh on|off|status [TAG]" >&2
    exit 2
    ;;
esac
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "switch: invalid tag: $tag" >&2; exit 2; }
# Absolute, from the caller's folder: reload.sh refuses a relative CMUX_DERIVED_DATA.
builds="${CMUX_LIVE_CODE_BUILDS:-$HOME/Library/Caches/cmux-next/live-code-builds}"
[[ "$builds" == /* ]] || builds="$PWD/$builds"
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=scripts/lib/mobile-attach.sh
source scripts/lib/mobile-attach.sh
# Named for the tag as reload.sh names its app: Foo.Bar and foo-bar are one tag.
out="$builds/$(cmux_attach__slug_raw "$tag")"
live_dir="$HOME/Library/Caches/cmux-next/live-code"

# The tag's CLI from either build: each talks to the tag's one socket. The regular build's comes
# from the tag's own DerivedData, never one the caller's shell names.
cli() {
  env -u CMUX_DERIVED_DATA CMUX_TAG="$tag" scripts/cmux-debug-cli.sh "$@" ||
    env CMUX_DERIVED_DATA="$out/DerivedData" CMUX_TAG="$tag" scripts/cmux-debug-cli.sh "$@"
}
# Labs > Live Code, through the running app. The setting is the tag's, so either build can set it.
set_switch() {
  if cli settings set labs.liveCode "$1" >/dev/null 2>&1; then
    echo "switch: Labs > Live Code $1"
  else
    echo "switch: no running $tag app took labs.liveCode $1; set it in Settings > Advanced > Labs and relaunch" >&2
    return 1
  fi
}

if [[ "$mode" == "status" ]]; then
  echo "switch: Labs > Live Code: $(cli settings get labs.liveCode 2>/dev/null || echo "unknown (is the $tag app running?)")"
  if [[ -s "$out/app-path" ]]; then
    echo "switch: live code build: $(sed -n 1p "$out/app-path") ($out)"
  else
    echo "switch: live code build: none yet (switch.sh on $tag builds it)"
  fi
  exit 0
fi

if [[ "$mode" == "on" ]]; then
  # Set before the swap: the live code build reads it at launch.
  set_before=1
  set_switch true 2>/dev/null || set_before=0
  # The two passes (scripts/live-code/build.sh), in the live build's own DerivedData; the
  # regular build's DerivedData and app stay as they are.
  scripts/live-code/build.sh "$out" "$tag" debug CMUX_DERIVED_DATA="$out/DerivedData"
  # Launch it: the same reload as the second pass, so nothing compiles or links again.
  launch_live() {
    env CMUX_LIVE_CODE_BUILD=1 CMUX_LIVE_CODE_INTERPOSABLE_LIST="$out/interposable.txt" \
      CMUX_DERIVED_DATA="$out/DerivedData" ./scripts/reload.sh --tag "$tag" --config debug --launch
  }
  launch_live
  # No app was running to take the setting: set it on this one, then launch it again to read it.
  if [[ "$set_before" -eq 0 ]] && set_switch true; then launch_live; fi
  echo "switch: live code on for $tag. Apply an edit with:"
  echo "  scripts/live-code/patch.py --log $out/xcodebuild.log --module CmuxNextApp --live $live_dir FILE.swift"
  echo "switch: back to the regular build: scripts/live-code/switch.sh off $tag"
else
  set_before=1
  set_switch false 2>/dev/null || set_before=0
  # The tag's own DerivedData (reload.sh's default for a tag), never the live build's.
  launch_regular() {
    env -u CMUX_DERIVED_DATA -u CMUX_LIVE_CODE_BUILD -u CMUX_LIVE_CODE_INTERPOSABLE_LIST \
      ./scripts/reload.sh --tag "$tag" --config debug --launch
  }
  launch_regular
  # No app was running to take the setting: set it on this one, then launch it again to read it.
  if [[ "$set_before" -eq 0 ]] && set_switch false; then launch_regular; fi
  echo "switch: live code off for $tag: the regular build runs"
fi
