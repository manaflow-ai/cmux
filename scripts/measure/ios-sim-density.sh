#!/usr/bin/env bash
# How many iOS simulators one fleet Mac runs at once before throughput stops
# growing or tests start to fail (Leo, 2026-11-16: "aziz also wanted to look
# into packing more ios simulators at once and right-sizing them in ci").
#
#   cmux-ci run --class exclusive --label measure --script scripts/measure/ios-sim-density.sh \
#     --ref SHA [--target-worker aws-m4pro-8] [--arg counts=1,2,3,4,6,8] [--arg rounds=2] \
#     [--arg ui=SUITE,...] --artifact .build/ios-sim-density/report.json --timeout 7200
#
# Builds the cmux-next iPhone app and its UI tests once (build-for-testing), as
# cmux-next-ios-sim.sh's `test ui=` builds them, then hands the .xctestrun to
# ios-sim-density.py, which boots one base iPhone, and for each count N clones
# N devices from it, boots them, and runs the same suites on all N at once,
# `rounds` times, on the booted clones (test-without-building), sampling the
# host. It prints IOS-SIM-DENSITY lines and writes report.json.
#
# Args: counts=LIST (default 1,2,3,4,6,8), rounds=R (2), ui=SUITE,... (the
# CmuxMobileAppUITests suites; default below: 21 tests that need no network),
# stop_on_pressure=0 to keep going under memory pressure (default 1 stops the
# sweep at the first count that hits it, which is itself the answer).
#
# Isolation: the step runs alone (class exclusive). Every device it makes is
# named ios-sim-density-<step key>-..., deleted by UDID when it ends.
set -euo pipefail
trap 'echo "ios-sim-density.sh: line $LINENO exited $? ($BASH_COMMAND)" >&2' ERR

# shellcheck source-path=SCRIPTDIR source=../cmux-next/lib/fleet-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/../cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet ios-sim-density.sh "xcodebuild and several iOS simulators" "none (a measurement)" \
  "cmux-ci run --class exclusive --label measure --script scripts/measure/ios-sim-density.sh --ref SHA --artifact .build/ios-sim-density/report.json"

counts=1,2,3,4,6,8 rounds=2 stop_on_pressure=1
ui=AppReviewGateUITests,DeepLinkUITests,ComposerGrowUpUITests,FeedNewPillUITests,AgentDisclosureUITests,EmailCodeUITests
for kv in "$@"; do
  case "$kv" in
    counts=*) counts="${kv#*=}" ;;
    rounds=*) rounds="${kv#*=}" ;;
    ui=*) ui="${kv#*=}" ;;
    stop_on_pressure=*) stop_on_pressure="${kv#*=}" ;;
    *) echo "ios-sim-density.sh: unknown arg '$kv' (counts=, rounds=, ui=, stop_on_pressure=)" >&2; exit 2 ;;
  esac
done
[[ "$counts" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] || { echo "ios-sim-density.sh: counts= wants N,N,..., got '$counts'" >&2; exit 2; }
[[ "$rounds" =~ ^[1-9][0-9]*$ ]] || { echo "ios-sim-density.sh: rounds= wants a positive number, got '$rounds'" >&2; exit 2; }
[[ "$ui" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]] || { echo "ios-sim-density.sh: ui= wants suite names, got '$ui'" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
out="$root/.build/ios-sim-density"
work="$out/work"
rm -rf "$out" && mkdir -p "$work"

# xcodegen and DEVELOPER_DIR exactly as scripts/ci/cmux-next-ios-sim.sh takes them (keep the
# version and sha256 in step with it).
xcodegen_version=2.46.0
xcodegen_sha256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
curl -fsSL --retry 3 --retry-delay 2 -o "$work/xcodegen.zip" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$xcodegen_version/xcodegen.zip"
got="$(shasum -a 256 "$work/xcodegen.zip" | awk '{ print $1 }')"
[[ "$got" == "$xcodegen_sha256" ]] || { echo "error: xcodegen zip has sha256 $got, expected $xcodegen_sha256" >&2; exit 3; }
unzip -q "$work/xcodegen.zip" -d "$work"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -n "${CMUX_CI_XCODE_APP:-}" ]]; then
    export DEVELOPER_DIR="$CMUX_CI_XCODE_APP/Contents/Developer"
  else
    major="$(sw_vers -productVersion | cut -d. -f1)"
    pin="$(awk -v m="$major" '$1 == m { print $2 }' scripts/ci/xcode-pins.txt)"
    export DEVELOPER_DIR="/Applications/Xcode_${pin}.app/Contents/Developer"
  fi
fi
[[ -d "$DEVELOPER_DIR" ]] || { echo "error: no Xcode at $DEVELOPER_DIR" >&2; exit 3; }
read -r runtime device_type <<< "$(xcrun simctl list -j runtimes devicetypes | python3 -I scripts/ci/ios_sim_runtime.py)"

t0=$SECONDS
ffi_key="$(python3 -I scripts/ci/ios_ffi_cache.py key "$root" "$work/ffi-inputs.json" 2>/dev/null)" || ffi_key=""
ffi_how=built
if [[ "$ffi_key" =~ ^[0-9a-f]{64}$ ]] && python3 -I scripts/ci/ios_ffi_cache.py restore "$root" "$ffi_key" >"$work/ffi-cache.log" 2>&1 &&
   [[ -f cmux-next-ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework/Info.plist ]]; then
  ffi_how="cache hit ${ffi_key:0:12}"
else
  JOBS="${JOBS:-8}" bash cmux-next-ios/rust/scripts/build-xcframework.sh >"$work/ffi.log" 2>&1 || {
    tail -60 "$work/ffi.log"; echo "error: CmuxMobileLinkFFI.xcframework build failed" >&2; exit 1; }
fi
(cd cmux-next-ios && "$work/xcodegen/bin/xcodegen" generate -q) >"$work/xcodegen.log" 2>&1 || {
  cat "$work/xcodegen.log"; echo "error: xcodegen failed" >&2; exit 1; }
set +e
xcodebuild build-for-testing -project cmux-next-ios/CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$work/dd" -enableCodeCoverage NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -quiet \
  >"$work/build.log" 2>&1
status=$?
set -e
[[ $status -eq 0 ]] || { tail -60 "$work/build.log"; echo "error: build-for-testing failed" >&2; exit 1; }
xctestrun="$(find "$work/dd/Build/Products" -maxdepth 1 -name '*.xctestrun' | head -1)"
[[ -n "$xctestrun" ]] || { echo "error: build-for-testing left no .xctestrun in $work/dd/Build/Products" >&2; exit 1; }
echo "IOS-SIM-DENSITY-BUILD seconds=$((SECONDS - t0)) ffi=${ffi_how// /_}"

exec python3 -I scripts/measure/ios-sim-density.py --xctestrun "$xctestrun" --runtime "$runtime" \
  --device-type "$device_type" --counts "$counts" --rounds "$rounds" --suites "$ui" \
  --stop-on-pressure "$stop_on_pressure" --prefix "ios-sim-density-${CMUX_CI_STEP_KEY:-local}" --out "$out"
