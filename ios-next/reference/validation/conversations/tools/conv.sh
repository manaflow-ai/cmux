#!/usr/bin/env bash
# conv.sh build|run  -- slot "conv": sync, patch AppShell dev hook remotely if needed, build, install, launch.
set -euo pipefail
HOST=aziz-other-macbook
ROOT=/Users/azizalbahar/Development/cmuxterm-hq/worktrees/nx-ios-app
R=nx-ios/conv; SIM=nx-ios-conv; bundle=dev.cmux.next.drawer; product=CmuxNextDrawer
remote() { ssh "$HOST" "bash -lc $(printf '%q' "$1")"; }
ssh "$HOST" "mkdir -p ~/$R/src/Packages/Shared ~/$R/src/vendor"
rsync -a --delete --exclude .build --exclude node_modules --exclude 'reference/' \
  --exclude '*.xcodeproj/xcuserdata' --exclude '*.xcodeproj/project.xcworkspace/xcuserdata' \
  "$ROOT/ios-next" "$HOST:$R/src/"
rsync -a --delete --exclude .build "$ROOT/Packages/Shared/CmuxGhosttyKit" "$HOST:$R/src/Packages/Shared/"
rsync -a --delete --exclude .build --exclude Tests "$ROOT/vendor/stack-auth-swift-sdk-prerelease" "$HOST:$R/src/vendor/"
MR=$R/src/ios-next/Packages/CmuxNextMobile/Sources/CNAppShell/ModuleRoots.swift
if grep -q "func conversations() -> some View { ModulePlaceholder" "$ROOT/ios-next/Packages/CmuxNextMobile/Sources/CNAppShell/ModuleRoots.swift"; then
  ssh "$HOST" "perl -pi -e 's/func conversations\\(\\) -> some View \\{ ModulePlaceholder\\(destination: .home\\) \\}/func conversations() -> some View { ConversationsRoot(connection: connection) }/; s/^import CNDesign\$/import CNDesign\\nimport CNConversationsUI/' ~/$MR"
  echo "patched ModuleRoots (remote only)"
fi
if ! grep -rq "CMUX_NEXT_DEV_SCREEN" "$ROOT/ios-next/Packages/CmuxNextMobile/Sources/CNAppShell"; then
  scp -q /tmp/nxios/conv/AppShellDevHook.swift "$HOST:$R/src/ios-next/Packages/CmuxNextMobile/Sources/CNAppShell/CNAppShell.swift"
  echo "patched AppShell dev hook (remote only)"
fi
remote "
  set -eo pipefail
  cd ~/$R/src/ios-next/App
  xcodegen generate --quiet || true
  xcodebuild -project CmuxNextMobile.xcodeproj -scheme Drawer -configuration Debug \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath ~/$R/dd -skipPackagePluginValidation \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build 2>&1 > ~/$R/build.log || true
  grep -E 'error:' ~/$R/build.log | sort -u | head -60 || true
  grep -q 'BUILD SUCCEEDED' ~/$R/build.log && echo BUILD SUCCEEDED || { echo BUILD FAILED; exit 1; }
"
[[ "${1:-build}" == run ]] || exit 0
remote "
  set -e
  udid=\$(xcrun simctl list devices -j | python3 -c 'import json,sys;d=json.load(sys.stdin)[\"devices\"];print(next((x[\"udid\"] for v in d.values() for x in v if x[\"name\"]==\"$SIM\" and x[\"isAvailable\"]),\"\"))')
  if [ -z \"\$udid\" ]; then
    rt=\$(xcrun simctl list runtimes -j | python3 -c 'import json,sys;r=[x for x in json.load(sys.stdin)[\"runtimes\"] if x[\"platform\"]==\"iOS\" and x[\"isAvailable\"]];print(sorted(r,key=lambda x:x[\"version\"])[-1][\"identifier\"])')
    udid=\$(xcrun simctl create $SIM com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \"\$rt\")
  fi
  xcrun simctl bootstatus \"\$udid\" -b >/dev/null
  echo \$udid > ~/$R/sim.udid
  xcrun simctl terminate \$udid $bundle 2>/dev/null || true
  xcrun simctl install \$udid ~/$R/dd/Build/Products/Debug-iphonesimulator/$product.app
  SIMCTL_CHILD_CMUX_NEXT_DEV_SCREEN=conversations ${EXTRA_ENV:-} xcrun simctl launch \$udid $bundle
"
