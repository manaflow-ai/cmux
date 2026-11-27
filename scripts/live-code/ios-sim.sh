#!/usr/bin/env bash
# Swift live code for the iPhone app (cmux-next-ios) in the iOS Simulator: an edit to a Swift file
# of the app (cmux-next-ios/App) or of CmuxMobileKit shows in the running simulator app in seconds,
# with no rebuild, no reinstall and no relaunch. The macOS app's live code (docs/cmux-next/live-code.md),
# on the simulator: a simulator app is a macOS process, so it loads an ad hoc signed dylib from a
# folder on the Mac's disk, and the engine is the macOS app's (Packages/Shared/CmuxLiveCode).
#
#   scripts/live-code/ios-sim.sh build OUT [Demo|Debug]   the live code build into OUT (once; then only patches)
#   scripts/live-code/ios-sim.sh run OUT UDID [KEY=VALUE | ARG]...
#                                       install it on the booted simulator UDID and launch it watching
#                                       OUT/live (KEY=VALUE: launch environment; ARG: launch argument)
#   scripts/live-code/ios-sim.sh patch OUT FILE.swift...  apply edited files to the running app; waits
#                                       for the app's answer and prints it (exit 1: refused)
#   scripts/live-code/ios-sim.sh undo OUT [--all]         the code before the newest patch (or every patch)
#   scripts/live-code/ios-sim.sh log OUT                  the app's live code log
#
# IOS_SIM_SET=DIR uses that simctl device set. LIVE_CODE_IOS_SDK=iphoneos builds the same app for a
# device instead, unsigned (scripts/live-code/ios-device.sh build signs and installs it). JOBS bounds xcodebuild's parallel jobs (default 6).
# XCODEGEN names the xcodegen to generate the project with (default: xcodegen on PATH; the project is
# generated only when one is found). The FFI (CmuxMobileLinkFFI.xcframework) must be built or
# restored first: cmux-next-ios/rust/scripts/build-xcframework.sh, or scripts/ci/ios_ffi_cache.py.
#
# The build (two passes, as the macOS app's scripts/live-code/build.sh): the app target and every
# CmuxMobileKit module compile unoptimized, testable and a file at a time, the app links with classic
# binds and its symbols exported, then links again with the CmuxMobile Swift symbols it exports made
# interposable, so its calls to its own functions go through pointers a patch can repoint. The app's
# modules also build with -enable-private-imports, so `private` views are patchable too. Only
# DEBUG configurations (Demo, Debug): a Release, TestFlight or App Store build is never built this
# way and never watches a live folder (only the app's DEBUG code starts the watcher).
#
# What applies live: changes inside functions, computed properties and SwiftUI `body`s of existing
# files. Needs a build: stored properties, enum cases, new files, resources, Package.swift.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
ios="$root/cmux-next-ios"

die() { echo "ios-sim live code: $*" >&2; exit 1; }
simctl() { xcrun simctl ${IOS_SIM_SET:+--set "$IOS_SIM_SET"} "$@"; }
out_dir() { mkdir -p "${1:?OUT}" && cd "$1" && pwd; }
live_code_sdk() {
  case "${LIVE_CODE_IOS_SDK:-iphonesimulator}" in
    iphonesimulator|iphoneos) echo "${LIVE_CODE_IOS_SDK:-iphonesimulator}" ;;
    *) die "LIVE_CODE_IOS_SDK is iphonesimulator or iphoneos, not $LIVE_CODE_IOS_SDK" ;;
  esac
}

# The iPhone app's modules: every CmuxMobile target of CmuxMobileKit, and the app target.
export LIVE_CODE_MODULE_PREFIX=CmuxMobile
export LIVE_CODE_PACKAGE_SWIFT="$ios/CmuxMobileKit/Package.swift"
export LIVE_CODE_EXTRA_TARGETS=CmuxMobileApp
# shellcheck source=scripts/live-code/lib/two-pass.sh
source "$here/lib/two-pass.sh"
# shellcheck source=scripts/live-code/lib/xcodebuild-args.sh
source "$here/lib/xcodebuild-args.sh"

xcodebuild_live() { # OUT CONFIG LOG [LIST]
  local out="$1" config="$2" log="$3" list="${4:-}" conditions=DEBUG args=() line
  [[ "$config" == Demo ]] && conditions="DEBUG CMUX_MOBILE_DEMO"
  while IFS= read -r line; do args+=("$line"); done < <(live_code_xcodebuild_args "$config" "$list")
  # The app's views are mostly `private struct`s, whose symbols stay inside their object file and
  # so could never be repointed. -enable-private-imports gives them external symbols (the same
  # names: a private name carries its file's discriminator), in the app's own modules only.
  args+=('OTHER_SWIFT_FLAGS=$(inherited) $(CMUX_LIVE_CODE_PRIVATE_$(TARGET_NAME))')
  while IFS= read -r line; do args+=("CMUX_LIVE_CODE_PRIVATE_$line=-Xfrontend -enable-private-imports"); done < <(live_code_targets)
  local destination='generic/platform=iOS Simulator' signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
  # A device build is left unsigned: the Mac's Apple Development identity signs it before the install.
  # It is cmux Dev (dev.cmux.mobile.dev), as cmux-next-ios-sim.sh try builds it, so it replaces the
  # person's cmux Dev in place and keeps its sign-in and pairing.
  if [[ "$(live_code_sdk)" == iphoneos ]]; then
    destination='generic/platform=iOS'
    signing=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=7WLXT3NR37
      CMUX_MOBILE_TAG=.dev "CMUX_MOBILE_DISPLAY_NAME=cmux Dev")
  fi
  xcodebuild -project "$ios/CmuxMobileApp.xcodeproj" -scheme CmuxMobileApp -configuration "$config" \
    -destination "$destination" -derivedDataPath "$out/dd" -jobs "${JOBS:-6}" \
    "${signing[@]}" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    COMPILER_INDEX_STORE_ENABLE=NO ENABLE_DEBUG_DYLIB=NO \
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) $conditions" \
    "${args[@]}" build >"$log" 2>&1 || {
      grep -E "error:" "$log" | sort -u | head -n 30 >&2
      die "xcodebuild failed (log $log)"
    }
}

build() { # OUT [CONFIG]
  local out config="${2:-Demo}" started=$SECONDS
  out="$(out_dir "$1")"
  [[ "$config" == Demo || "$config" == Debug ]] || die "only a DEBUG configuration (Demo or Debug) is built for live code, not $config"
  local xcodegen="${XCODEGEN:-$(command -v xcodegen || true)}"
  if [[ -n "$xcodegen" ]]; then
    (cd "$ios" && "$xcodegen" generate -q) || die "xcodegen failed"
  fi
  [[ -d "$ios/CmuxMobileApp.xcodeproj" ]] || die "no cmux-next-ios/CmuxMobileApp.xcodeproj: set XCODEGEN or run xcodegen in cmux-next-ios"
  [[ -f "$ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework/Info.plist" ]] \
    || die "no CmuxMobileLinkFFI.xcframework: build it (cmux-next-ios/rust/scripts/build-xcframework.sh) or restore it (scripts/ci/ios_ffi_cache.py)"
  # 1. Build and link, nothing interposable yet. Its log holds the frontend commands patches compile with.
  xcodebuild_live "$out" "$config" "$out/xcodebuild.log"
  local app="$out/dd/Build/Products/$config-$(live_code_sdk)/CmuxMobileApp.app"
  local bin="$app/CmuxMobileApp"
  [[ -f "$bin" ]] || die "no app at $app"
  # 2. What the app exports of its own modules, made interposable: only the link steps run again.
  live_code_list "$bin" "$out"
  xcodebuild_live "$out" "$config" "$out/xcodebuild-2.log" "$out/interposable.txt"
  live_code_check "$bin" "$out" || die "the relinked app would not launch (see above)"
  printf '%s\n' "$app" > "$out/app-path"
  mkdir -p "$out/live"
  echo "ios-sim live code: built in $((SECONDS - started)) s: $app"
}

run() { # OUT UDID [KEY=VALUE | ARG]...
  local out udid app bundle envs=() args=()
  out="$(out_dir "$1")"; udid="${2:?usage: ios-sim.sh run OUT UDID}"; shift 2
  app="$(cat "$out/app-path" 2>/dev/null)" || die "no live code build in $out (ios-sim.sh build $out)"
  bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
  for a in "$@"; do if [[ "$a" == [A-Z_]*=* ]]; then envs+=("SIMCTL_CHILD_$a"); else args+=("$a"); fi; done
  mkdir -p "$out/live"
  # A new log per launch, so the watching line below is this launch's.
  if [[ -f "$out/live/live-code.log" ]]; then mv "$out/live/live-code.log" "$out/live/live-code.log.1"; fi
  simctl install "$udid" "$app"
  simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  env ${envs[@]+"${envs[@]}"} SIMCTL_CHILD_CMUX_LIVE_CODE_DIR="$out/live" xcrun simctl ${IOS_SIM_SET:+--set "$IOS_SIM_SET"} launch "$udid" "$bundle" ${args[@]+"${args[@]}"}
  # The app says it watches once its engine has started.
  for _ in $(seq 1 100); do
    grep -q "live code: watching $out/live" "$out/live/live-code.log" 2>/dev/null && { tail -n 1 "$out/live/live-code.log"; return 0; }
    sleep 0.1
  done
  die "the app did not start watching $out/live in 10 s (a DEBUG live code build? see $out/live/live-code.log)"
}

# redraws OUT: how many redraws the app has logged since its launch.
redraws() { local n; n="$(grep -c "redrawn generation=" "$1/live/live-code.log" 2>/dev/null)" || true; echo "${n:-0}"; }

# answer OUT NAME BEFORE: waits up to 20 s for the app's answer to NAME in its log and prints it,
# then the redraw after it (the first past BEFORE redraws).
answer() {
  local out="$1" name="$2" before="$3" line
  for _ in $(seq 1 400); do
    line="$(grep -E -- "(applied|rolled back) $name|$name refused" "$out/live/live-code.log" 2>/dev/null | tail -n 1 || true)"
    if [[ -n "$line" ]]; then
      echo "$line"
      [[ "$line" == *refused* ]] && return 1
      for _ in $(seq 1 100); do
        if (( $(redraws "$out") > before )); then grep -F "redrawn generation=" "$out/live/live-code.log" | tail -n 1; return 0; fi
        sleep 0.02
      done
      echo "ios-sim live code: applied, but no redraw logged in 2 s (is the app's main thread busy?)" >&2
      return 0
    fi
    sleep 0.05
  done
  die "no answer to $name in 20 s: is the app running and watching $out/live? (ios-sim.sh run)"
}

patch() { # OUT FILE...
  local out
  out="$(out_dir "$1")"; shift
  [[ $# -gt 0 ]] || die "usage: ios-sim.sh patch OUT FILE.swift..."
  local printed dylib before
  before="$(redraws "$out")"
  printed="$(python3 "$here/patch.py" --log "$out/xcodebuild.log" --live "$out/live" "$@")" || exit 1
  echo "$printed"
  dylib="$(sed -n 's/^patch.py: \([^ ]*\.dylib\) .*/\1/p' <<<"$printed")"
  answer "$out" "$(basename "$dylib")" "$before"
}

undo() { # OUT [--all]
  local out name before
  out="$(out_dir "$1")"
  before="$(redraws "$out")"
  name="undo-$(date +%s)-$$-$RANDOM.rollback"
  [[ "${2:-}" == --all ]] && name="${name%.rollback}.rollback-all"
  : > "$out/live/.$name" && mv "$out/live/.$name" "$out/live/$name"
  answer "$out" "$name" "$before"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  build) build "$@" ;;
  run) run "$@" ;;
  patch) patch "$@" ;;
  undo) undo "$@" ;;
  log) cat "$(out_dir "${1:?OUT}")/live/live-code.log" ;;
  *) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
