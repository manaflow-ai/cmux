#!/usr/bin/env bash
# Feed scroll-performance rig: builds the Demo app for the simulator on a cmux
# Mac mini and runs the Feed stress with the in-app frame-interval log (G-04).
# Never builds on this laptop and never opens Simulator.app.
#
#   rig.sh sync              xcodegen here, rsync sources + CnxFFI.xcframework to $HOST:$DIR
#   rig.sh build             Demo simulator build on the mini (arm64 only)
#   rig.sh sim               create + boot the rig's own simulator ($SIM_NAME)
#   rig.sh run LABEL [K=V..] install, launch on the Feed with CNX_FRAMELOG=1 and the
#                            given CNX_* settings, wait for the app to exit after the autoscroll,
#                            copy framelog.jsonl to verify/evidence/feedperf/LABEL.jsonl
#
# Environment: HOST (default mini-cmux11s-mac-mini), DIR (default feedperf),
# SIM_NAME (default cnx-feedperf-1), XCF (CnxFFI.xcframework to ship).
set -euo pipefail
HOST=${HOST:-mini-cmux11s-mac-mini}
DIR=${DIR:-feedperf}
SIM_NAME=${SIM_NAME:-cnx-feedperf-1}
here=$(cd "$(dirname "$0")" && pwd)
cnx=$(cd "$here/../.." && pwd)
repo=$(cd "$cnx/.." && pwd)
remote_env='export PATH=/opt/homebrew/bin:$PATH DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer;'

case "${1:-}" in
  sync)
    (cd "$cnx" && xcodegen generate -q)
    ssh "$HOST" "mkdir -p $DIR"
    rsync -a --delete --exclude .build --exclude build --exclude 'verify/' --exclude 'CnxKit/Frameworks/' \
      "$cnx" "$HOST:$DIR/"
    rsync -a --delete --exclude .build "$repo/Packages" "$HOST:$DIR/"
    ssh "$HOST" "mkdir -p $DIR/vendor"
    rsync -a "$repo/vendor/stack-auth-swift-sdk-prerelease" "$HOST:$DIR/vendor/"
    rsync -a "$repo/AppIcon.icon" "$HOST:$DIR/"
    xcf=${XCF:-$(ls -td "$HOME"/cnx-ios-builds/.cache/xcframework/*/CnxFFI.xcframework | head -1)}
    key=$(printf '%s\n' "$(git -C "$repo" rev-parse 'HEAD:cnx-ios/rust')" "$(git -C "$repo" rev-parse 'HEAD:cmux-tui/crates/cmux-wg')" \
      "$(git -C "$repo" rev-parse 'HEAD:cmux-tui/crates/cmux-transport')" | shasum | cut -c1-16)
    [[ -d "$HOME/cnx-ios-builds/.cache/xcframework/$key" && -z "${XCF:-}" ]] && xcf="$HOME/cnx-ios-builds/.cache/xcframework/$key/CnxFFI.xcframework"
    echo "xcframework: $xcf (want key $key)"
    ssh "$HOST" "mkdir -p $DIR/cnx-ios/CnxKit/Frameworks"
    rsync -a --delete "$xcf" "$HOST:$DIR/cnx-ios/CnxKit/Frameworks/"
    # rsync keeps mtimes; touch so SwiftPM never reuses an older build of a changed file.
    ssh "$HOST" "find $DIR/cnx-ios/CnxKit/Sources -name '*.swift' -newer $DIR/.synced -exec touch {} + 2>/dev/null; touch $DIR/.synced"
    ;;
  build)
    ssh "$HOST" "$remote_env cd $DIR/cnx-ios && xcodebuild -project CnxApp.xcodeproj -scheme CnxApp -configuration Demo \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath build/demo -jobs 8 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CNX_TAG=.feedperf 'CNX_DISPLAY_NAME=cnx feedperf' \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) DEBUG CNX_DEMO' build > build-demo.log 2>&1; rc=\$?; \
      grep -E 'error:|BUILD (SUCCEEDED|FAILED)' build-demo.log | sort -u | head -30; exit \$rc"
    ;;
  sim)
    ssh "$HOST" "$remote_env udid=\$(xcrun simctl list devices | grep '$SIM_NAME (' | head -1 | grep -oE '[0-9A-F-]{36}'); \
      if [[ -z \$udid ]]; then udid=\$(xcrun simctl create '$SIM_NAME' 'iPhone 17 Pro' com.apple.CoreSimulator.SimRuntime.iOS-26-5); fi; \
      xcrun simctl boot \$udid 2>/dev/null; xcrun simctl bootstatus \$udid -b >/dev/null; echo \$udid"
    ;;
  run)
    label=${2:?label}; shift 2
    envs="SIMCTL_CHILD_CNX_FRAMELOG=1 SIMCTL_CHILD_CNX_MOCK_AUTH=${MOCK:-1}"
    for kv in "$@"; do envs+=" SIMCTL_CHILD_$kv"; done
    out="$cnx/verify/evidence/feedperf"; mkdir -p "$out"
    ssh "$HOST" "$remote_env udid=\$(xcrun simctl list devices | grep '$SIM_NAME (' | head -1 | grep -oE '[0-9A-F-]{36}'); \
      app=\$(ls -d $DIR/cnx-ios/build/demo/Build/Products/Demo-iphonesimulator/*.app | head -1); \
      bid=\$(plutil -extract CFBundleIdentifier raw \$app/Info.plist); \
      xcrun simctl terminate \$udid \$bid 2>/dev/null; xcrun simctl install \$udid \$app; \
      caches=\$(xcrun simctl get_app_container \$udid \$bid data)/Library/Caches; rm -f \$caches/framelog.jsonl; \
      SIMCTL_CHILD_CNX_FEED_EXIT_WHEN_DONE=1 $envs perl -e 'alarm shift; exec @ARGV' ${WAIT:-300} \
        xcrun simctl launch --console-pty --terminate-running-process \$udid \$bid -cnx-tab feed -cnx.setupComplete YES -cnx-no-restore >/dev/null 2>&1; \
      cat \$caches/framelog.jsonl" > "$out/$label.jsonl"
    python3 "$here/summarize.py" "$out/$label.jsonl"
    ;;
  *) sed -n '2,17p' "$0"; exit 2 ;;
esac
