#!/usr/bin/env bash
# remote-ios.sh: build, install, launch and screenshot the cmux-next mobile app
# on a headless simulator on the remote build Mac (no Simulator.app window).
#
#   ios-next/scripts/remote-ios.sh build  [--slot S] [--scheme Drawer|Tabs]
#   ios-next/scripts/remote-ios.sh run    [--slot S] [--scheme Drawer|Tabs] [--env K=V ...]
#   ios-next/scripts/remote-ios.sh launch [--slot S] [--scheme Drawer|Tabs] [--env K=V ...]   (install + launch the last build, no rebuild)
#   ios-next/scripts/remote-ios.sh shot   [--slot S] --out local.png
#   ios-next/scripts/remote-ios.sh video  [--slot S] --seconds N --out local.mp4
#   ios-next/scripts/remote-ios.sh openurl [--slot S] --url <url>
#   ios-next/scripts/remote-ios.sh test   [--slot S]            (swift test of CmuxNextMobile on macOS)
#   ios-next/scripts/remote-ios.sh sim    [--slot S] -- <simctl args...>   (raw simctl on the slot sim)
#   ios-next/scripts/remote-ios.sh axe    [--slot S] -- <axe args...>      (AXe tap/swipe/type/describe-ui; --udid added)
#   ios-next/scripts/remote-ios.sh fetch  [--slot S] --url <remote path> --out <local path>
#
# Each slot has its own remote source copy, DerivedData and simulator, so
# parallel agents do not collide. Builds within one slot are serialized.
set -euo pipefail

HOST="${CMUX_NEXT_IOS_HOST:-aziz-other-macbook}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # worktree root
cmd="${1:?command}"; shift
slot="main"; scheme="Drawer"; out=""; seconds=8; url=""; envs=(); raw=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slot) slot="$2"; shift 2 ;;
    --scheme) scheme="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --seconds) seconds="$2"; shift 2 ;;
    --url) url="$2"; shift 2 ;;
    --env) envs+=("$2"); shift 2 ;;
    --) shift; raw=("$@"); break ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done

R="nx-ios/$slot"
SIM="nx-ios-$slot"
case "$scheme" in
  Drawer) bundle="dev.cmux.next.drawer"; product="CmuxNextDrawer" ;;
  Tabs) bundle="dev.cmux.next.tabs"; product="CmuxNextTabs" ;;
  *) echo "scheme must be Drawer or Tabs" >&2; exit 2 ;;
esac

sync_src() {
  ssh "$HOST" "mkdir -p ~/$R/src/Packages/Shared ~/$R/src/vendor"
  rsync -a --delete --exclude .build --exclude node_modules --exclude 'reference/' \
    --exclude '*.xcodeproj/xcuserdata' --exclude '*.xcodeproj/project.xcworkspace/xcuserdata' \
    "$ROOT/ios-next" "$HOST:$R/src/"
  rsync -a --delete --exclude .build "$ROOT/Packages/Shared/CmuxGhosttyKit" "$HOST:$R/src/Packages/Shared/"
  # Path dependencies of Packages/CmuxNextMobile, mirrored at the same
  # relative paths.
  rsync -a --delete --exclude .build --exclude Tests "$ROOT/vendor/stack-auth-swift-sdk-prerelease" "$HOST:$R/src/vendor/"
}

remote() { ssh "$HOST" "bash -lc $(printf '%q' "$1")"; }

ensure_sim() {
  remote "
    set -e
    udid=\$(xcrun simctl list devices -j | python3 -c 'import json,sys;d=json.load(sys.stdin)[\"devices\"];print(next((x[\"udid\"] for v in d.values() for x in v if x[\"name\"]==\"$SIM\" and x[\"isAvailable\"]),\"\"))')
    if [ -z \"\$udid\" ]; then
      rt=\$(xcrun simctl list runtimes -j | python3 -c 'import json,sys;r=[x for x in json.load(sys.stdin)[\"runtimes\"] if x[\"platform\"]==\"iOS\" and x[\"isAvailable\"]];print(sorted(r,key=lambda x:x[\"version\"])[-1][\"identifier\"])')
      udid=\$(xcrun simctl create $SIM com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \"\$rt\")
    fi
    xcrun simctl bootstatus \"\$udid\" -b >/dev/null
    echo \$udid > ~/$R/sim.udid
  "
}

build() {
  sync_src
  remote "
    set -eo pipefail
    cd ~/$R/src/ios-next/App
    command -v xcodegen >/dev/null && xcodegen generate --quiet || true
    exec 9>~/$R/build.lock; flock 9 2>/dev/null || true
    xcodebuild -project CmuxNextMobile.xcodeproj -scheme $scheme -configuration Debug \
      -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath ~/$R/dd -skipPackagePluginValidation \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build 2>&1 | tee ~/$R/build.log | grep -E 'error:|warning: .*CN|BUILD (SUCCEEDED|FAILED)' | grep -v '^ld: warning' | head -80
    grep -q 'BUILD SUCCEEDED' ~/$R/build.log
  "
}

case "$cmd" in
  build) build ;;
  run|launch)
    [[ "$cmd" == run ]] && build
    ensure_sim
    envstr=""
    for e in "${envs[@]+"${envs[@]}"}"; do envstr+="SIMCTL_CHILD_${e%%=*}=$(printf '%q' "${e#*=}") "; done
    remote "
      set -e
      udid=\$(cat ~/$R/sim.udid)
      app=~/$R/dd/Build/Products/Debug-iphonesimulator/$product.app
      xcrun simctl terminate \$udid $bundle 2>/dev/null || true
      # One-time: installs from before the UIKit scene delegate restore a
      # SwiftUI scene session and launch to a black window.
      if [ ! -e ~/$R/.uikit-scene-$bundle ]; then xcrun simctl uninstall \$udid $bundle 2>/dev/null || true; touch ~/$R/.uikit-scene-$bundle; fi
      xcrun simctl install \$udid \"\$app\"
      $envstr xcrun simctl launch \$udid $bundle
    "
    ;;
  shot)
    [[ -n "$out" ]] || { echo "--out required" >&2; exit 2; }
    remote "xcrun simctl io \$(cat ~/$R/sim.udid) screenshot ~/$R/shot.png >/dev/null 2>&1"
    scp -q "$HOST:$R/shot.png" "$out"; echo "$out"
    ;;
  video)
    [[ -n "$out" ]] || { echo "--out required" >&2; exit 2; }
    remote "
      udid=\$(cat ~/$R/sim.udid); rm -f ~/$R/rec.mp4
      xcrun simctl io \$udid recordVideo --codec=h264 --force ~/$R/rec.mp4 >/dev/null 2>&1 & p=\$!
      sleep $seconds; kill -INT \$p; wait \$p 2>/dev/null || true
    "
    scp -q "$HOST:$R/rec.mp4" "$out"; echo "$out"
    ;;
  openurl)
    remote "xcrun simctl openurl \$(cat ~/$R/sim.udid) $(printf '%q' "$url")"
    ;;
  sim)
    remote "xcrun simctl ${raw[*]//\$UDID/\$(cat ~/$R/sim.udid)}"
    ;;
  axe)
    remote "axe ${raw[*]} --udid \$(cat ~/$R/sim.udid)"
    ;;
  fetch)
    scp -q "$HOST:$url" "$out"; echo "$out"
    ;;
  test)
    sync_src
    remote "cd ~/$R/src/ios-next/Packages/CmuxNextMobile && swift test 2>&1 | tail -40"
    ;;
  *) echo "unknown command $cmd" >&2; exit 2 ;;
esac
