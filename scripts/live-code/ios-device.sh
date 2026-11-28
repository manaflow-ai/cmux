#!/usr/bin/env bash
# Swift live code for the iPhone app on a real iPhone (cmuxterm-hq docs/design/ios-dev-channels.md,
# step 4): an edit to a Swift file of the app or of CmuxMobileKit shows in cmux Dev on the phone in
# seconds, with no rebuild, no reinstall and no relaunch. ios-sim.sh's engine, for iphoneos: the Mac
# compiles an arm64 iphoneos patch, signs it with its Apple Development identity (the team the app is
# signed by), and drops it in the live folder its cmux NEXT host serves on the link's `live-code`
# service (cmux-mobile-host live_code.rs). cmux Dev takes it over the link, checks that its own team
# signed it (CmuxLiveCode DevicePatchSignature.swift) and loads it. Nothing is copied to the phone by
# hand, and no folder on the phone is watched from the Mac.
#
#   scripts/live-code/ios-device.sh build OUT [Demo|Debug]  the live code build of cmux Dev into OUT (once)
#   scripts/live-code/ios-device.sh run OUT UDID [KEY=VALUE]...
#                                       sign it for the phone UDID, install it (the sanctioned install) and
#                                       launch it with CMUX_LIVE_CODE_LINK=1 (KEY=VALUE: launch environment)
#   scripts/live-code/ios-device.sh patch OUT FILE.swift...  apply edited files to cmux Dev on the phone;
#                                       waits for the phone's answer and prints it (exit 1: refused)
#   scripts/live-code/ios-device.sh undo OUT [--all]         the code before the newest patch (or every patch)
#   scripts/live-code/ios-device.sh log                      the live folder's log (hostd's and the phone's lines)
#
# Run it on the Mac the phone is attached to and linked with: the Mac whose cmux NEXT the phone is
# paired with serves the folder. That Mac's cmux NEXT needs a host with the `live-code` service.
# CMUX_MOBILE_LIVE_CODE_DIR names the live folder (default ~/Library/Caches/cmux-live-code/ios-device,
# the host's own default). Only cmux Dev (dev.cmux.mobile.dev) or a tagged dev build, DEBUG, launched
# with CMUX_LIVE_CODE_LINK=1 opens the service: a Release, TestFlight or App Store build compiles none
# of it. The build and its limits (what applies live, what needs a rebuild) are ios-sim.sh's.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
ios="$root/cmux-next-ios"
team=7WLXT3NR37

die() { echo "ios-device live code: $*" >&2; exit 1; }
out_dir() { mkdir -p "${1:?OUT}" && cd "$1" && pwd; }
live_dir() { local d="${CMUX_MOBILE_LIVE_CODE_DIR:-$HOME/Library/Caches/cmux-live-code/ios-device}"; mkdir -p "$d" && cd "$d" && pwd; }

build() { # OUT [CONFIG]
  LIVE_CODE_IOS_SDK=iphoneos "$here/ios-sim.sh" build "$@"
}

run() { # OUT UDID [KEY=VALUE]...
  local out udid app signed live bundle envs=()
  out="$(out_dir "$1")"; udid="${2:?usage: ios-device.sh run OUT UDID}"; shift 2
  app="$(cat "$out/app-path" 2>/dev/null)" || die "no live code build in $out (ios-device.sh build $out)"
  [[ "$app" == *-iphoneos/* ]] || die "$app is not a device build (ios-device.sh build $out)"
  for a in "$@"; do [[ "$a" == [A-Z_]*=* ]] || die "run takes KEY=VALUE launch variables, not $a"; envs+=("DEVICECTL_CHILD_$a"); done
  # A signed copy per phone; the build stays unsigned for the next phone and for patch.py's frontend lines.
  signed="$out/signed-$udid/CmuxMobileApp.app"
  rm -rf "$out/signed-$udid" && mkdir -p "$out/signed-$udid"
  ditto "$app" "$signed"
  /usr/bin/python3 -I "$ios/scripts/sign_device_app.py" --app "$signed" --checkout "$root" --team "$team" --device "$udid" \
    >"$out/signed-$udid/signed.json" 2>"$out/signed-$udid/sign.err" \
    || die "signing failed: $(tail -n 1 "$out/signed-$udid/sign.err")"
  # The identity that signed the app signs every patch: the phone loads only its own team's code.
  /usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["bundles"][-1]["identity"])' \
    "$out/signed-$udid/signed.json" >"$out/sign-identity" || die "no identity in $out/signed-$udid/signed.json"
  bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$signed/Info.plist")"
  "$root/scripts/ios-device-process.sh" terminate-installed --device-id "$udid" --bundle-id "$bundle" >/dev/null 2>&1 || true
  CMUX_SANCTIONED_IPHONE_INSTALL=1 xcrun devicectl device install app --device "$udid" "$signed" >"$out/signed-$udid/install.log" 2>&1 \
    || die "install failed ($(tail -n 1 "$out/signed-$udid/install.log"); locked, or Developer Mode off?)"
  live="$(live_dir)"
  local before; before="$(listens "$live")"
  env ${envs[@]+"${envs[@]}"} DEVICECTL_CHILD_CMUX_LIVE_CODE_LINK=1 \
    xcrun devicectl device process launch --terminate-existing --device "$udid" "$bundle" >/dev/null \
    || die "installed, but it did not launch (is the phone locked?)"
  # The phone opens the service once it is linked; hostd logs it.
  for _ in $(seq 1 300); do
    if (( $(listens "$live") > before )); then
      grep -F "a phone listens on" "$live/live-code.log" | tail -n 1
      return 0
    fi
    sleep 0.1
  done
  die "cmux Dev launched, but no phone opened live-code in 30 s: is it signed in and linked with this Mac, and does this Mac's cmux NEXT have the live-code service? (log: $live/live-code.log)"
}

listens() { local n; n="$(grep -c "a phone listens on" "$1/live-code.log" 2>/dev/null)" || true; echo "${n:-0}"; }
redraws() { local n; n="$(grep -c "redrawn generation=" "$1/live-code.log" 2>/dev/null)" || true; echo "${n:-0}"; }

# answer LIVE NAME BEFORE: waits up to 30 s for the phone's answer to NAME and prints it, then the
# redraw after it (the first past BEFORE redraws).
answer() {
  local live="$1" name="$2" before="$3" line
  for _ in $(seq 1 600); do
    line="$(grep -E -- "(applied|rolled back) $name|$name refused" "$live/live-code.log" 2>/dev/null | tail -n 1 || true)"
    if [[ -n "$line" ]]; then
      echo "$line"
      [[ "$line" == *refused* ]] && return 1
      for _ in $(seq 1 150); do
        if (( $(redraws "$live") > before )); then grep -F "redrawn generation=" "$live/live-code.log" | tail -n 1; return 0; fi
        sleep 0.02
      done
      echo "ios-device live code: applied, but no redraw came back in 3 s" >&2
      return 0
    fi
    sleep 0.05
  done
  die "no answer to $name in 30 s: is cmux Dev running and linked? (ios-device.sh run; log: $live/live-code.log)"
}

patch() { # OUT FILE...
  local out live identity printed dylib before
  out="$(out_dir "$1")"; shift
  [[ $# -gt 0 ]] || die "usage: ios-device.sh patch OUT FILE.swift..."
  identity="$(cat "$out/sign-identity" 2>/dev/null)" || die "no signing identity yet: ios-device.sh run $out UDID first"
  live="$(live_dir)"
  before="$(redraws "$live")"
  printed="$(python3 "$here/patch.py" --log "$out/xcodebuild.log" --live "$live" --sign "$identity" "$@")" || exit 1
  echo "$printed"
  dylib="$(sed -n 's/^patch.py: \([^ ]*\.dylib\) .*/\1/p' <<<"$printed")"
  answer "$live" "$(basename "$dylib")" "$before"
}

undo() { # OUT [--all]
  local live name before
  live="$(live_dir)"
  before="$(redraws "$live")"
  name="undo-$(date +%s)-$$-$RANDOM.rollback"
  [[ "${2:-}" == --all ]] && name="${name%.rollback}.rollback-all"
  : > "$live/.$name" && mv "$live/.$name" "$live/$name"
  answer "$live" "$name" "$before"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  build) build "$@" ;;
  run) run "$@" ;;
  patch) patch "$@" ;;
  undo) undo "$@" ;;
  log) cat "$(live_dir)/live-code.log" ;;
  *) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
