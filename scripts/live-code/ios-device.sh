#!/usr/bin/env bash
# Swift live code on an iPhone: the iOS Simulator's live code (scripts/live-code/ios-sim.sh, the same
# engine, Packages/Shared/CmuxLiveCode) on a real device, in cmux Dev only (dev.cmux.mobile.dev,
# cmuxterm-hq docs/design/ios-dev-channels.md, phase 3 "Hot Swift on the device"). An edit to a Swift
# file of the app or of CmuxMobileKit shows on the running phone with no rebuild, reinstall or relaunch.
# Run it on the Mac the phone is attached to (USB, or the same network once paired in Xcode).
#
#   scripts/live-code/ios-device.sh build OUT [Demo|Debug]   the live code build of cmux Dev for iphoneos,
#                                       unsigned, into OUT (once; then only patches)
#   scripts/live-code/ios-device.sh run OUT UDID [KEY=VALUE]...
#                                       sign it with this Mac's Apple Development identity for that phone,
#                                       install it as cmux Dev and launch it (KEY=VALUE: launch environment)
#   scripts/live-code/ios-device.sh patch OUT FILE.swift...  compile the edited files for iphoneos, sign
#                                       the patch with the identity `run` signed the app with, copy it into
#                                       cmux Dev's container; waits for the app's answer (exit 1: refused)
#   scripts/live-code/ios-device.sh undo OUT [--all]         the code before the newest patch (or every patch)
#   scripts/live-code/ios-device.sh log OUT                  the app's live code log, read from the phone
#
# How a patch reaches the phone: an iPhone loads only code signed by the app's own team, so the patch
# is signed by this Mac with the same Apple Development identity sign_device_app.py signed cmux Dev
# with. devicectl copies it into cmux Dev's data container (Library/LiveCode, LiveCodeRedraw's device
# folder): hidden first (`.NAME.dylib` and its sidecar `.NAME.json`), then an empty `NAME.load` marker,
# because devicectl cannot rename a file into place and the engine must never read a half-copied
# patch. The app's answer is its live-code.log, copied back. On a device only cmux Dev watches a
# folder, and only its DEBUG code (a Release, TestFlight or App Store build compiles none of it).
#
# JOBS bounds xcodebuild's parallel jobs (default 6). XCODEGEN as in ios-sim.sh. The FFI
# (CmuxMobileLinkFFI.xcframework) must be built or restored first. TEAM (default 7WLXT3NR37) is the
# signing team: its wildcard development profile must name the phone (as for try.sh).
set -euo pipefail
device_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export IOS_LIVE_PLATFORM=iphoneos
# shellcheck source=scripts/live-code/ios-sim.sh
source "$device_here/ios-sim.sh"

DEV_BUNDLE_ID=dev.cmux.mobile.dev
DEV_FOLDER=Library/LiveCode # LiveCodeRedraw.deviceFolder

die() { echo "ios-device live code: $*" >&2; exit 1; }
devicectl() { xcrun devicectl "$@"; }

# copy_to OUT LOCAL NAME: LOCAL into cmux Dev's live folder on the phone, as NAME.
copy_to() {
  devicectl device copy to --device "$(cat "$1/udid")" --domain-type appDataContainer --domain-identifier "$DEV_BUNDLE_ID" \
    --source "$2" --destination "$DEV_FOLDER/$3" >"$1/copy.log" 2>&1 || { tail -n 5 "$1/copy.log" >&2; die "devicectl could not copy $3 to the phone"; }
}

# fetch_log OUT: the phone's live-code.log into OUT/device/live-code.log (empty when it has none yet).
fetch_log() {
  mkdir -p "$1/device"
  devicectl device copy from --device "$(cat "$1/udid")" --domain-type appDataContainer --domain-identifier "$DEV_BUNDLE_ID" \
    --source "$DEV_FOLDER/live-code.log" --destination "$1/device/live-code.log" >"$1/copy-from.log" 2>&1 || : > "$1/device/live-code.log"
}

device_build() { # OUT [CONFIG]
  local out
  out="$(out_dir "$1")"
  IOS_LIVE_EXTRA_SETTINGS=(CMUX_MOBILE_TAG=.dev "CMUX_MOBILE_DISPLAY_NAME=cmux Dev"
    "CMUX_MOBILE_SOURCE_COMMIT=$(git -C "$root" rev-parse HEAD)")
  build "$out" "${2:-Demo}"
  local app bundle
  app="$(cat "$out/app-path")"
  bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
  [[ "$bundle" == "$DEV_BUNDLE_ID" ]] || die "built $bundle, not cmux Dev ($DEV_BUNDLE_ID)"
}

device_run() { # OUT UDID [KEY=VALUE]...
  local out udid app signed identity
  out="$(out_dir "$1")"; udid="${2:?usage: ios-device.sh run OUT UDID}"; shift 2
  app="$(cat "$out/app-path" 2>/dev/null)" || die "no live code build in $out (ios-device.sh build $out)"
  printf '%s\n' "$udid" > "$out/udid"
  rm -rf "$out/signed" && mkdir -p "$out/signed"
  ditto "$app" "$out/signed/CmuxMobileApp.app"
  signed="$(/usr/bin/python3 -I "$ios/scripts/sign_device_app.py" --app "$out/signed/CmuxMobileApp.app" \
    --checkout "$root" --team "${TEAM:-7WLXT3NR37}" --device "$udid")" || die "signing failed (sign_device_app.py above)"
  identity="$(/usr/bin/python3 -I -c 'import json,sys; print(next(b["identity"] for b in json.loads(sys.argv[1])["bundles"] if b["bundle"] == "CmuxMobileApp.app"))' "$signed")"
  [[ -n "$identity" ]] || die "sign_device_app.py named no identity for the app"
  # Every patch is signed with the app's own identity: the phone's dyld loads only the app's team.
  printf '%s\n' "$identity" > "$out/sign-identity"
  "$root/scripts/ios-device-process.sh" terminate-installed --device-id "$udid" --bundle-id "$DEV_BUNDLE_ID" >/dev/null 2>&1 || true
  # The sanctioned install, as try.sh's: the marker lets the devicectl interceptor tell it from a raw install.
  CMUX_SANCTIONED_IPHONE_INSTALL=1 devicectl device install app --device "$udid" "$out/signed/CmuxMobileApp.app" \
    >"$out/install.log" 2>&1 || { tail -n 5 "$out/install.log" >&2; die "install failed (locked, or Developer Mode off?)"; }
  local a before started
  for a in "$@"; do [[ "$a" == [A-Z_]*=* ]] || die "launch arguments are KEY=VALUE environment only, got '$a'"; done
  # The phone keeps its log across launches: this launch's watching line is the first past `before`.
  fetch_log "$out"
  before="$(grep -c "live code: watching" "$out/device/live-code.log" || true)"
  (
    for a in "$@"; do export "DEVICECTL_CHILD_$a"; done
    exec xcrun devicectl device process launch --terminate-existing --device "$udid" "$DEV_BUNDLE_ID"
  ) >"$out/launch.log" 2>&1 || { tail -n 5 "$out/launch.log" >&2; die "installed, but it did not launch (unlock the phone)"; }
  started="$(date +%s)"
  while (( $(date +%s) - started < 30 )); do
    fetch_log "$out"
    if (( $(grep -c "live code: watching" "$out/device/live-code.log" || true) > ${before:-0} )); then
      grep "live code: watching" "$out/device/live-code.log" | tail -n 1
      return 0
    fi
    sleep 1
  done
  die "cmux Dev did not start watching $DEV_FOLDER in 30 s (a DEBUG build? see ios-device.sh log $out)"
}

# device_answer OUT NAME: waits up to 60 s for the phone's answer to NAME and prints it, then its redraw.
device_answer() {
  local out="$1" name="$2" line started
  started="$(date +%s)"
  while (( $(date +%s) - started < 60 )); do
    fetch_log "$out"
    line="$(grep -E -- "(applied|rolled back) $name|$name refused" "$out/device/live-code.log" | tail -n 1 || true)"
    if [[ -n "$line" ]]; then
      echo "$line"
      [[ "$line" == *refused* ]] && return 1
      grep -F "redrawn generation=" "$out/device/live-code.log" | tail -n 1 || true
      return 0
    fi
    sleep 0.5
  done
  die "no answer to $name in 60 s: is cmux Dev running in the foreground? (ios-device.sh run, ios-device.sh log $out)"
}

device_patch() { # OUT FILE...
  local out printed dylib name
  out="$(out_dir "$1")"; shift
  [[ $# -gt 0 ]] || die "usage: ios-device.sh patch OUT FILE.swift..."
  [[ -s "$out/sign-identity" && -s "$out/udid" ]] || die "run cmux Dev first (ios-device.sh run $out UDID): it records the phone and the signing identity"
  rm -rf "$out/outbox" && mkdir -p "$out/outbox"
  printed="$(python3 "$here/patch.py" --log "$out/xcodebuild.log" --live "$out/outbox" --sign "$(cat "$out/sign-identity")" "$@")" || exit 1
  echo "$printed"
  dylib="$(sed -n 's/^patch.py: \([^ ]*\.dylib\) .*/\1/p' <<<"$printed")"
  [[ -f "$dylib" ]] || die "patch.py printed no patch"
  name="$(basename "$dylib" .dylib)"
  local t0=$SECONDS
  [[ ! -f "$out/outbox/$name.json" ]] || copy_to "$out" "$out/outbox/$name.json" ".$name.json"
  copy_to "$out" "$dylib" ".$name.dylib"
  : > "$out/outbox/$name.load"
  copy_to "$out" "$out/outbox/$name.load" "$name.load"
  echo "ios-device live code: sent $name.dylib ($(wc -c < "$dylib" | tr -d ' ') bytes) in $((SECONDS - t0)) s"
  device_answer "$out" "$name.dylib"
}

device_undo() { # OUT [--all]
  local out name
  out="$(out_dir "$1")"
  [[ -s "$out/udid" ]] || die "run cmux Dev first (ios-device.sh run $out UDID)"
  name="undo-$(date +%s)-$$-$RANDOM.rollback"
  [[ "${2:-}" == --all ]] && name="${name%.rollback}.rollback-all"
  mkdir -p "$out/outbox" && : > "$out/outbox/$name"
  copy_to "$out" "$out/outbox/$name" "$name"
  device_answer "$out" "$name"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  build) device_build "$@" ;;
  run) device_run "$@" ;;
  patch) device_patch "$@" ;;
  undo) device_undo "$@" ;;
  log) out="$(out_dir "${1:?OUT}")"; [[ -s "$out/udid" ]] || die "no phone recorded in $out (ios-device.sh run)"; fetch_log "$out"; cat "$out/device/live-code.log" ;;
  *) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
