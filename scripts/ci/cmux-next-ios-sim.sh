#!/usr/bin/env bash
# cmux-next-ios on an iOS simulator, as a fleet step of class `simulator`
# (the M4 Pro minis that advertise the `simulator` label; never the M6 perf
# hosts). Agents cannot build cmux-next-ios on their own Mac (fleet guard) and
# the fleet's `build ios` target builds the classic app, so this is the route
# for the new app:
#
#   cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
#     --arg MODE --artifact artifacts/ios-sim/evidence.zip
#
# MODE:
#   release-build
#           CmuxMobileLinkFFI.xcframework, xcodegen, and an unsigned Release app
#           for generic iOS Simulator, without injected DEBUG or demo conditions.
#           Compile only: no simulator runtime, install, launch or publication.
#           Takes no further arguments; retains build logs and evidence.zip.
#   build   CmuxMobileLinkFFI.xcframework, xcodegen, and the app for the
#           simulator (Demo: optimized, with the DEBUG developer surface); then
#           boot one iPhone, install, launch, screenshot.
#   test    build, plus `xcodebuild test` of CmuxMobileKit on that iPhone.
#           Optional arguments after it (each one `--arg`; the controller's
#           argument pattern has no spaces, so lists are comma-separated):
#             only=TARGET/SUITE[,TARGET/SUITE...]   run only those kit tests
#               (-only-testing), e.g. only=CmuxMobileLiveTests/LinkRecoveryTests
#               (a suite, or TARGET/SUITE/test for an XCTest method)
#             ui=SUITE[,SUITE...]   also run those CmuxMobileAppUITests suites
#               against a Debug app; with ui= and no only=, the kit run is skipped
#           The artifact keeps each run's log, its console output (a test's
#           print lines, e.g. benchmark numbers) and its per-test results.
#   bench   build, plus the in-app flood benchmark (TerminalFloodBench,
#           verify/terminal-flood.md) on PTY recordings made on the worker:
#             cat     `cat` of a 6 MB source file
#             vim     vim scrolling that file a line per redraw (Ctrl-E)
#             top     top refreshing once a second (htop when installed)
#           Each recording is replayed at the rate the program wrote it (capped
#           at 50 Mbit/s), with screenshots during and after the flood.
#   all     build, test and bench.
#   shots   build, plus one screenshot per scene, in dark and in light, from
#           the app's own DEBUG launch arguments and demo drivers (mock data,
#           setup marked complete). Each later argument is one scene,
#           `name=WORD,WORD,...`: the words are launch arguments (commas stand
#           for spaces, which fleet step arguments cannot hold), and leading
#           KEY=VALUE words are the app's environment, e.g.
#             --arg shots --arg devices=-cmux-mobile-settings-page,devices \
#               --arg feed=CMUX_MOBILE_FEED_STRESS=60,-cmux-mobile-tab,feed
#           Run it at the base and at the head for a PR's before and after.
#   chief-live-perf / chief-live-perf-baseline
#           Three Chief layout measurements on one simulator, reusing test
#           DerivedData. Copy the identical head benchmark test to the baseline
#           tree; baseline mode selects its original-view adapter.
#           bench/ retains each log, console output and result bundle.
#   pair-e2e
#           build, plus a tagged DEBUG cmux NEXT Mac app built here
#           (reload.sh), and pairing by its QR code end to end
#           (cmux_next_pair_e2e.py): the Mac's Mobile Pairing link, opened on
#           the iPhone, pairs it with no Allow prompt and no test seed. Screens
#           of the Mac page (never while it shows a code: its image carries
#           the token), the phone's Settings > Devices (a base ref gives
#           the "before") and its scanner with the camera off; the Mac's
#           pairing log, hostd's log and paired-devices.json, keys redacted.
#           Then the upload leg: the phone streams a sparse ~150 MB file (past
#           the old 100 MiB cap) to the Mac with its own LinkUpload, and the
#           stored file's size and SHA-256 must match (UploadProbe.swift).
#   listperf
#           build, plus the list frame-rate rig (ListStressRig,
#           verify/listperf/): each case launches the Demo app with
#           CMUX_MOBILE_LIST_SCREEN and its settings, waits for it to exit after
#           its scroll passes, and keeps its framelog.jsonl and summary
#           (verify/feedperf/summarize.py: the POOLED autoscroll line and each
#           -open window). Optional arguments (each one `--arg`):
#             base=SHA     also build SHA (a commit with the rig's files, e.g. the
#                          PR's base with them grafted on) in a worktree of this
#                          checkout, and run every case on both apps, base then
#                          head, on the one simulator: a same-harness before/after
#             reps=N       repetitions of every case (1-5, default 2)
#             cases=A,B    cases by label (default ws-200-live4, chat-40-stream,
#                          chat-40, diff-2400, tabs-30-stream); the labels are
#                          final.sh's: ws-200 ws-200-live4 ws-500-live8 home-300
#                          chat-40 chat-200 chat-40-stream tabs-30 tabs-30-stream
#                          tabs-80 diff-2400 diff-2400-pan artifacts-40 feed-ref
#           SUMMARY.md gets one row per window; the artifact keeps listperf/.
#
# Isolation: the step makes its own simulator device set under its checkout
# (`simctl --set`), so it never lists, boots or deletes another simulator, and
# deletes the set when it ends. The artifact holds the screenshots, each
# benchmark's flood-bench.json, the app log, the test summary, SUMMARY.md, the
# built app (zipped) and the PTY recordings with their replay rates.
set -euo pipefail
trap 'echo "cmux-next-ios-sim.sh: line $LINENO exited $? ($BASH_COMMAND)" >&2' ERR

# shellcheck source-path=SCRIPTDIR source=../cmux-next/lib/fleet-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/../cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet cmux-next-ios-sim.sh "xcodebuild and an iOS simulator" "cmux-next-ios kit tests" \
  "cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA --arg bench --artifact artifacts/ios-sim/evidence.zip"

mode="${1:-build}"
case "$mode" in build|release-build|test|bench|all|pair-e2e|shots|chief-live-perf|chief-live-perf-baseline|listperf) ;; *) echo "cmux-next-ios-sim.sh: MODE is build, release-build, test, bench, all, pair-e2e, shots, chief-live-perf, chief-live-perf-baseline or listperf, got '$mode'" >&2; exit 2 ;; esac
if [[ "$mode" == release-build && $# -ne 1 ]]; then
  echo "cmux-next-ios-sim.sh: release-build takes no further arguments" >&2; exit 2
fi
scenes=("${@:2}")
if [[ "$mode" == shots && ${#scenes[@]} -eq 0 ]]; then
  echo "cmux-next-ios-sim.sh: shots needs one or more scenes after it, name=WORD,WORD,..." >&2; exit 2
fi

# test's optional selection (see MODE above), checked before anything is built.
kit_only=()
ui_suites=()
if [[ "$mode" == test && $# -gt 1 ]]; then
  for sel in "${@:2}"; do
    case "$sel" in
      only=?*)
        IFS=',' read -r -a items <<< "${sel#only=}"
        for item in "${items[@]}"; do
          [[ "$item" =~ ^[A-Za-z0-9_]+(/[A-Za-z0-9_]+){0,2}$ ]] ||
            { echo "cmux-next-ios-sim.sh: only= wants TARGET/SUITE names, got '$item'" >&2; exit 2; }
          kit_only+=("-only-testing:$item")
        done ;;
      ui=?*)
        IFS=',' read -r -a items <<< "${sel#ui=}"
        for item in "${items[@]}"; do
          [[ "$item" =~ ^[A-Za-z0-9_]+(/[A-Za-z0-9_]+)?$ ]] ||
            { echo "cmux-next-ios-sim.sh: ui= wants CmuxMobileAppUITests suite names, got '$item'" >&2; exit 2; }
          ui_suites+=("-only-testing:CmuxMobileAppUITests/$item")
        done ;;
      *) echo "cmux-next-ios-sim.sh: test takes only=LIST and ui=LIST, got '$sel'" >&2; exit 2 ;;
    esac
  done
fi
run_kit=1

# listperf's cases (label, screen, settings), as verify/listperf/final.sh runs them.
listperf_table=(
  "ws-200          workspaces  LIST_COUNT=200"
  "ws-200-live4    workspaces  LIST_COUNT=200 LIST_LIVE_HZ=4"
  "ws-500-live8    workspaces  LIST_COUNT=500 LIST_LIVE_HZ=8"
  "home-300        home        LIST_COUNT=300"
  "chat-40         chat        LIST_COUNT=40"
  "chat-200        chat        LIST_COUNT=200"
  "chat-40-stream  chat        LIST_COUNT=40 LIST_STREAM=1"
  "tabs-30         tabs        LIST_COUNT=30"
  "tabs-30-stream  tabs        LIST_COUNT=30 LIST_STREAM=1"
  "tabs-80         tabs        LIST_COUNT=80"
  "diff-2400       diff        LIST_COUNT=3"
  "diff-2400-pan   diff        LIST_COUNT=3 LIST_PAN=1 LIST_PASSES=4 LIST_SPEED=800"
  "artifacts-40    artifacts   LIST_COUNT=40"
  "feed-ref        feed        FEED_STRESS=320"
)
listperf_base="" listperf_reps=2
listperf_cases=(ws-200-live4 chat-40-stream chat-40 diff-2400 tabs-30-stream)
if [[ "$mode" == listperf ]]; then
  for sel in "${@:2}"; do
    case "$sel" in
      base=*)
        listperf_base="${sel#base=}"
        [[ "$listperf_base" =~ ^[0-9a-f]{40}$ ]] || { echo "cmux-next-ios-sim.sh: base= wants a 40-character commit SHA, got '$listperf_base'" >&2; exit 2; } ;;
      reps=*)
        listperf_reps="${sel#reps=}"
        [[ "$listperf_reps" =~ ^[1-5]$ ]] || { echo "cmux-next-ios-sim.sh: reps= wants 1 to 5, got '$listperf_reps'" >&2; exit 2; } ;;
      cases=?*)
        IFS=',' read -r -a listperf_cases <<< "${sel#cases=}"
        for item in "${listperf_cases[@]}"; do
          printf '%s\n' "${listperf_table[@]}" | awk '{ print $1 }' | grep -qxF -- "$item" ||
            { echo "cmux-next-ios-sim.sh: no listperf case '$item'" >&2; exit 2; }
        done ;;
      *) echo "cmux-next-ios-sim.sh: listperf takes base=SHA, reps=N and cases=LIST, got '$sel'" >&2; exit 2 ;;
    esac
  done
fi
if [[ ${#ui_suites[@]} -gt 0 && ${#kit_only[@]} -eq 0 ]]; then run_kit=0; fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
# listperf needs the rig in the app it measures (ListStressRig reads
# CMUX_MOBILE_LIST_SCREEN; summarize.py reads its frame log). A tree without it
# would launch the ordinary app and time out on every case, so refuse up front.
listperf_rig=(cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileShell/ListStressRig.swift cmux-next-ios/verify/feedperf/summarize.py)
if [[ "$mode" == listperf ]]; then
  for f in "${listperf_rig[@]}"; do
    [[ -f "$f" ]] || { echo "cmux-next-ios-sim.sh: listperf needs $f in the head; this tree has no list frame-rate rig" >&2; exit 2; }
  done
fi
out="$root/artifacts/ios-sim"
work="$root/.build/ios-sim"
rm -rf "$out" "$work"
mkdir -p "$out/screens" "$out/bench" "$work"
summary="$out/SUMMARY.md"
note() { printf '%s\n' "$*" | tee -a "$summary"; }

# Steps run with a per-step HOME; Homebrew tools live outside it.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"

# Everything this step makes outside its checkout goes away when it ends: the
# pinned xcodegen's temp dir and, once made, the simulator device set.
xcodegen_dir=""
sims=""
perf_udid=""
cleanup() {
  local result=$?
  # The test iPhones in the default device set, when a step is cut short.
  local d
  for d in "${test_udid:-}" "${ui_udid:-}" "${perf_udid:-}"; do
    [[ -n "$d" ]] || continue
    xcrun simctl shutdown "$d" >/dev/null 2>&1 || true
    xcrun simctl delete "$d" >/dev/null 2>&1 || true
  done
  if [[ -n "$sims" ]]; then
    xcrun simctl --set "$sims" shutdown all >/dev/null 2>&1 || true
    xcrun simctl --set "$sims" delete all >/dev/null 2>&1 || true
    rm -rf "$sims" || true
  fi
  # Attempted even when the simulator set's removal failed.
  if [[ -n "$xcodegen_dir" ]]; then rm -rf "$xcodegen_dir" || true; fi
  # listperf's base worktree (its build is under $work, which the next step's checkout clears).
  if [[ -n "${base_src:-}" ]]; then
    git -C "$root" worktree remove --force "$base_src" >/dev/null 2>&1 || rm -rf "$base_src" || true
    git -C "$root" worktree prune >/dev/null 2>&1 || true
  fi
  # pair-e2e's Mac app build (its DerivedData, app included), reload.sh's
  # /tmp/cmux-<tag> link to it, and the host's last-debug-log pointer as it was.
  if [[ -n "${mac_dd:-}" ]]; then
    # The tag is this run's own (its PID is in it), so its link and state are too. The rig removes
    # them in its own finally; this runs the same list (forget_tag) for a rig cut short.
    if [[ -n "${mac_tag:-}" ]]; then
      if [[ -L "/tmp/cmux-$mac_tag" ]]; then rm -f "/tmp/cmux-$mac_tag" || true; fi
      if [[ -n "${mac_app:-}" && -d "$mac_app" ]]; then
        python3 -I scripts/ci/cmux_next_pair_e2e.py --forget-tag "$mac_app" >/dev/null 2>&1 || true
      fi
    fi
    rm -rf "$work/pair-rig" || true
    if [[ -n "${mac_tag:-}" ]] && grep -qF -- "$mac_tag" /tmp/cmux-last-debug-log-path 2>/dev/null; then
      if [[ -n "${prev_last_log:-}" ]]; then printf '%s\n' "$prev_last_log" > /tmp/cmux-last-debug-log-path || true
      else rm -f /tmp/cmux-last-debug-log-path || true; fi
    fi
    rm -rf "$mac_dd" || true
  fi
  # Cloud routing payloads contain machine/team/session ids; remove this exact
  # file even when SIGTERM/INT interrupts the Python leg before its finally.
  if [[ -n "${work:-}" ]]; then rm -f "$work/cloud-routing-push.json" || true; fi
  if [[ "$mode" == release-build ]]; then
    # Keep failure evidence too, including FFI or project-generation failures.
    local log
    for log in ffi xcodegen build; do
      if [[ -f "$work/$log.log" ]]; then cp "$work/$log.log" "$out/$log.log" || result=1; fi
    done
    note "- exit status: $result" || result=1
    (cd "$out" && zip -qr evidence.zip . -x evidence.zip) || result=1
  fi
  if [[ -n "${CMUX_IOS_CLOUD_PROOF_FILE:-}" ]]; then
    python3 -I scripts/ci/cmux_next_cloud_pair_proof.py --export-out "$out" --status "$result" || result=1
  fi
  return "$result"
}
trap cleanup EXIT
# A cancelled step gets SIGTERM: exit, so the EXIT trap cleans up.
trap 'exit 143' TERM
trap 'exit 130' INT

# xcodegen: a pinned release, checksum-verified, in a temp dir of this step's
# own, never the host's (aws-m4pro-2 has none, and the fleet's AWS Macs are not
# provisioned by hand). Bump the version and the zip's sha256 together.
xcodegen_version=2.46.0
xcodegen_sha256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
xcodegen_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-next-ios-sim-xcodegen.XXXXXX")"
curl -fsSL --retry 3 --retry-delay 2 -o "$xcodegen_dir/xcodegen.zip" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$xcodegen_version/xcodegen.zip" ||
  { echo "error: could not download xcodegen $xcodegen_version" >&2; exit 3; }
got="$(shasum -a 256 "$xcodegen_dir/xcodegen.zip" | awk '{ print $1 }')"
[[ "$got" == "$xcodegen_sha256" ]] ||
  { echo "error: xcodegen $xcodegen_version zip has sha256 $got, expected $xcodegen_sha256" >&2; exit 3; }
unzip -q "$xcodegen_dir/xcodegen.zip" -d "$xcodegen_dir"
# The binary finds its SettingPresets in ../share/xcodegen, so it runs from the unzipped tree.
xcodegen="$xcodegen_dir/xcodegen/bin/xcodegen"
[[ -x "$xcodegen" ]] || { echo "error: no xcodegen binary in the $xcodegen_version zip" >&2; exit 3; }
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
# The simulator runtime and iPhone, chosen before anything is built: the runtime the fleet declares
# (CMUX_CI_IOS_SIM_RUNTIME, set by the build fleet's controller), else the newest (ios_sim_runtime.py).
# A host without the declared runtime fails here, with the runtimes it has.
if [[ "$mode" != release-build ]]; then
  sim_choice="$(xcrun simctl list -j runtimes devicetypes | python3 -I scripts/ci/ios_sim_runtime.py)" || exit 3
  read -r runtime device_type <<< "$sim_choice"
fi

note "# cmux-next-ios simulator step ($mode)"
note ""
note "- commit: $(git rev-parse HEAD)"
note "- host: $(hostname -s), $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, macOS $(sw_vers -productVersion)"
note "- Xcode: $(xcodebuild -version | tr '\n' ' ')"
note "- xcodegen: $xcodegen_version (pinned, sha256 verified)"

# --- Build ------------------------------------------------------------------
t0=$SECONDS
# The FFI comes from the worker's source-keyed cache when an earlier step built the same
# inputs with the same toolchain (scripts/ci/ios_ffi_cache.py: key, verified restore). A
# miss builds it as before, and a build of landed inputs (the same trees as feat-cmux-next's
# tip, probed beside the build) is published for the next step. The cache never fails the
# step: a miss or no key builds. Everything else (a key command that failed, a failed probe or
# store, a helper error) is a warning in the log and SUMMARY.md, then the step builds.
ffi_cache=(python3 -I scripts/ci/ios_ffi_cache.py)
ffi_log="$work/ffi-cache.log"
: >"$ffi_log"
ffi_warn() {
  echo "warning: ios-ffi cache: $1 (exit $2); building the FFI" >&2
  tail -20 "$ffi_log" >&2 || true
  note "- FFI cache warning: $1 (exit $2)"
}
ffi_key="" ffi_rc=0
ffi_key="$("${ffi_cache[@]}" key "$root" "$work/ffi-inputs.json" 2>>"$ffi_log")" || ffi_rc=$?
if [[ $ffi_rc -ne 0 ]]; then
  [[ $ffi_rc -eq 3 ]] || ffi_warn "key failed" "$ffi_rc"
  ffi_key=""
elif ! [[ "$ffi_key" =~ ^[0-9a-f]{64}$ ]]; then
  ffi_warn "key printed '${ffi_key:0:80}', not a sha256" 0
  ffi_key=""
fi
ffi_xcf=cmux-next-ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework
ffi_swift=cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift
ffi_how=""
if [[ -n "$ffi_key" ]]; then
  ffi_rc=0
  "${ffi_cache[@]}" restore "$root" "$ffi_key" >>"$ffi_log" 2>&1 || ffi_rc=$?
  if [[ $ffi_rc -eq 0 && -f "$ffi_xcf/Info.plist" && -s "$ffi_swift" ]]; then
    ffi_how="cache hit ${ffi_key:0:12}"
  elif [[ $ffi_rc -eq 0 ]]; then
    ffi_warn "restore reported a hit but left no $ffi_xcf/Info.plist" 0
  elif [[ $ffi_rc -ne 1 ]]; then
    ffi_warn "restore failed" "$ffi_rc"
  fi
fi
if [[ -z "$ffi_how" ]]; then
  ffi_probe=""
  if [[ -n "$ffi_key" ]]; then
    "${ffi_cache[@]}" probe "$work/ffi-inputs.json" "$work/ffi-tip.json" >>"$ffi_log" 2>&1 &
    ffi_probe=$!
  fi
  JOBS="${JOBS:-8}" bash cmux-next-ios/rust/scripts/build-xcframework.sh >"$work/ffi.log" 2>&1 || {
    tail -60 "$work/ffi.log"; echo "error: CmuxMobileLinkFFI.xcframework build failed" >&2; exit 1; }
  ffi_how="built"
  if [[ -n "$ffi_probe" ]]; then
    ffi_how="built, cache miss ${ffi_key:0:12}"
    ffi_rc=0
    wait "$ffi_probe" || ffi_rc=$?
    if [[ $ffi_rc -eq 0 ]]; then
      "${ffi_cache[@]}" store "$root" "$work/ffi-inputs.json" "$work/ffi-tip.json" >>"$ffi_log" 2>&1 || {
        ffi_rc=$?; ffi_warn "store failed" "$ffi_rc"; }
    else
      ffi_warn "probe of the feat-cmux-next tip failed, nothing stored" "$ffi_rc"
    fi
  fi
fi
grep -h '^ios-ffi cache:' "$ffi_log" || true
note "- FFI: $((SECONDS - t0)) s ($ffi_how)"
(cd cmux-next-ios && "$xcodegen" generate -q) >"$work/xcodegen.log" 2>&1 || {
  cat "$work/xcodegen.log"; echo "error: xcodegen failed" >&2; exit 1; }
dd="$work/dd"
# Demo builds the Swift packages as Release (no DEBUG), so the flood benchmark
# and terminal demo would be missing; the command-line conditions reach the
# packages too (verify/terminal-flood.md, Reproducing).
configuration=Demo
build_settings=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CMUX_MOBILE_DEMO')
if [[ "$mode" == release-build ]]; then
  configuration=Release
  build_settings=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
fi
build_command=(xcodebuild -project cmux-next-ios/CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration "$configuration"
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$dd"
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
  "${build_settings[@]}" build)
if [[ "$mode" == release-build ]]; then
  printf '%q ' "${build_command[@]}" >"$out/build-command.txt"
  printf '\n' >>"$out/build-command.txt"
  note "- configuration: Release; destination: generic/platform=iOS Simulator; signing: disabled"
  note "- compilation conditions: Release defaults; no injected DEBUG or CMUX_MOBILE_DEMO"
fi
set +e
"${build_command[@]}" >"$work/build.log" 2>&1
status=$?
set -e
grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$work/build.log" | sort -u | head -40 || true
[[ $status -eq 0 ]] || { tail -40 "$work/build.log"; exit 1; }
app="$dd/Build/Products/$configuration-iphonesimulator/CmuxMobileApp.app"
if [[ "$mode" == release-build ]]; then
  [[ -d "$app" ]] || { echo "error: Release app missing at $app" >&2; exit 1; }
  note "- build: $((SECONDS - t0)) s (FFI + xcodegen + Release simulator app)"
  ditto -c -k --keepParent "$app" "$out/CmuxMobileApp-Release-simulator.app.zip"
  note "- compile only: no simulator install or launch, TestFlight upload or publication"
  exit 0
fi
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
note "- build: $((SECONDS - t0)) s (FFI + xcodegen + Demo simulator app), bundle $bundle_id"

# --- listperf: the base app -------------------------------------------------
base_app=""
if [[ "$mode" == listperf && -n "$listperf_base" ]]; then
  t0=$SECONDS
  if ! git cat-file -e "$listperf_base^{commit}" 2>/dev/null; then
    depth=()
    [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
    git fetch --no-tags --quiet ${depth[@]+"${depth[@]}"} origin "$listperf_base" ||
      { echo "error: could not fetch base $listperf_base" >&2; exit 1; }
  fi
  base_src="$work/base-src"
  for f in "${listperf_rig[@]:0:1}"; do
    git cat-file -e "$listperf_base:$f" 2>/dev/null ||
      { echo "error: base $listperf_base has no $f (graft the rig onto the base first)" >&2; exit 2; }
  done
  git worktree add --quiet --detach "$base_src" "$listperf_base"
  base_ffi="$("${ffi_cache[@]}" key "$base_src" "$work/ffi-inputs-base.json" 2>>"$ffi_log")" || base_ffi=""
  if [[ -n "$ffi_key" && "$base_ffi" == "$ffi_key" ]]; then
    # The same FFI inputs as the head: its build.
    mkdir -p "$base_src/$(dirname "$ffi_xcf")" "$base_src/$(dirname "$ffi_swift")"
    rm -rf "${base_src:?}/$ffi_xcf"
    cp -R "$ffi_xcf" "$base_src/$ffi_xcf"
    cp "$ffi_swift" "$base_src/$ffi_swift"
    base_ffi_how="the head's (same inputs)"
  else
    (cd "$base_src" && JOBS="${JOBS:-8}" bash cmux-next-ios/rust/scripts/build-xcframework.sh) >"$work/ffi-base.log" 2>&1 || {
      tail -60 "$work/ffi-base.log"; echo "error: base CmuxMobileLinkFFI.xcframework build failed" >&2; exit 1; }
    base_ffi_how="built"
  fi
  (cd "$base_src/cmux-next-ios" && "$xcodegen" generate -q) >"$work/xcodegen-base.log" 2>&1 || {
    cat "$work/xcodegen-base.log"; echo "error: base xcodegen failed" >&2; exit 1; }
  set +e
  xcodebuild -project "$base_src/cmux-next-ios/CmuxMobileApp.xcodeproj" -scheme CmuxMobileApp -configuration Demo \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$work/dd-base" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    "${build_settings[@]}" build >"$work/build-base.log" 2>&1
  status=$?
  set -e
  cp "$work/build-base.log" "$out/build-base.log" 2>/dev/null || true
  grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$work/build-base.log" | sort -u | head -40 || true
  [[ $status -eq 0 ]] || { tail -40 "$work/build-base.log"; exit 1; }
  base_app="$work/dd-base/Build/Products/Demo-iphonesimulator/CmuxMobileApp.app"
  base_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$base_app/Info.plist")"
  [[ "$base_bundle" == "$bundle_id" ]] || { echo "error: base bundle $base_bundle is not the head's $bundle_id" >&2; exit 1; }
  note "- base build: $((SECONDS - t0)) s at $listperf_base (FFI: $base_ffi_how)"
fi

# --- Simulator --------------------------------------------------------------
sims="$work/sims"
mkdir -p "$sims"
simctl() { xcrun simctl --set "$sims" "$@"; }
udid="$(simctl create cmux-next-ios-sim "$device_type" "$runtime")"
simctl boot "$udid"
simctl bootstatus "$udid" -b >/dev/null
simctl ui "$udid" appearance dark >/dev/null 2>&1 || true
note "- simulator: ${device_type##*.} on ${runtime##*.}"
simctl install "$udid" "$app"
simctl launch "$udid" "$bundle_id" >/dev/null
# A bounded wait for the first screen to draw; the launch itself has no signal to wait on.
sleep 8
simctl io "$udid" screenshot "$out/screens/launch.png" >/dev/null
simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
note "- launch: ok, screens/launch.png"

# keep_test_logs LOG XCRESULT NAME: the run's log, console output (print
# lines), per-test results, counts and failures into the artifact as NAME-*.
keep_test_logs() {
  local log=$1 bundle=$2 name=$3
  cp "$log" "$out/$name-test.log" 2>/dev/null || true
  xcrun xcresulttool get log --type console --path "$bundle" > "$out/$name-console.txt" 2>/dev/null || true
  xcrun xcresulttool get test-results tests --path "$bundle" --compact > "$out/$name-tests.json" 2>/dev/null || true
  # XCTAttachments (UI tests' keepAlways screenshots) as files, with the
  # manifest.json that maps each one to its test.
  mkdir -p "$out/$name-attachments"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$out/$name-attachments" >/dev/null 2>&1 || true
  xcrun xcresulttool get test-results summary --path "$bundle" --compact 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("passed %s, failed %s, skipped %s" % (d.get("passedTests"), d.get("failedTests"), d.get("skippedTests")))
' > "$out/$name-tests-counts.txt" 2>/dev/null || rm -f "$out/$name-tests-counts.txt"
  python3 -c '
import json, sys
def walk(node, path):
    if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
        print("FAILED:", " / ".join(path))
        for child in node.get("children", []):
            if child.get("nodeType") == "Failure Message":
                print("   ", child.get("name"))
    for child in node.get("children", []):
        walk(child, path + [child.get("name", "")])
for root in json.load(open(sys.argv[1])).get("testNodes", []):
    walk(root, [root.get("name", "")])
' "$out/$name-tests.json" > "$out/$name-tests-failures.txt" 2>/dev/null || true
}

# --- Tests ------------------------------------------------------------------
if [[ ( "$mode" == test || "$mode" == all ) && $run_kit -eq 1 ]]; then
  t0=$SECONDS
  # xcodebuild sees only the default device set: the tests get their own new
  # iPhone there, deleted by its UDID afterwards (never another step's device).
  test_udid="$(xcrun simctl create "cmux-next-ios-sim-test-${CMUX_CI_STEP_KEY:-local}" "$device_type" "$runtime")"
  set +e
  (cd cmux-next-ios/CmuxMobileKit && xcodebuild test -scheme CmuxMobileKit-Package \
    -destination "id=$test_udid,arch=arm64" -enableCodeCoverage NO -derivedDataPath "$work/dd-test" \
    -resultBundlePath "$work/kit.xcresult" CODE_SIGNING_ALLOWED=NO -quiet ${kit_only[@]+"${kit_only[@]}"}) >"$work/test.log" 2>&1
  test_status=$?
  set -e
  xcrun simctl shutdown "$test_udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$test_udid" >/dev/null 2>&1 || true
  test_udid=""
  counts="$(xcrun xcresulttool get test-results summary --path "$work/kit.xcresult" --compact 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("passed %s, failed %s, skipped %s" % (d.get("passedTests"), d.get("failedTests"), d.get("skippedTests")))
' || echo "no result bundle")"
  # The failed test cases and their messages, from the result bundle.
  xcrun xcresulttool get test-results tests --path "$work/kit.xcresult" --compact 2>/dev/null | python3 -c '
import json, sys
def walk(node, path):
    if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
        print("FAILED:", " / ".join(path))
        for child in node.get("children", []):
            if child.get("nodeType") == "Failure Message":
                print("   ", child.get("name"))
    for child in node.get("children", []):
        walk(child, path + [child.get("name", "")])
for root in json.load(sys.stdin).get("testNodes", []):
    walk(root, [root.get("name", "")])
' > "$out/test-failures.txt" 2>/dev/null || true
  cat "$out/test-failures.txt"
  keep_test_logs "$work/test.log" "$work/kit.xcresult" kit
  [[ ${#kit_only[@]} -eq 0 ]] || note "- kit filter: ${kit_only[*]}"
  note "- CmuxMobileKit tests (iOS simulator): exit $test_status, $counts, $((SECONDS - t0)) s"
fi

# --- UI tests (test ui=...) -------------------------------------------------
if [[ ${#ui_suites[@]} -gt 0 ]]; then
  t0=$SECONDS
  # A Debug build of the app and its UI test bundle, on a new iPhone in the
  # default device set (xcodebuild sees no other), deleted by its UDID after.
  ui_udid="$(xcrun simctl create "cmux-next-ios-sim-ui-${CMUX_CI_STEP_KEY:-local}" "$device_type" "$runtime")"
  set +e
  xcodebuild test -project cmux-next-ios/CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Debug \
    -destination "id=$ui_udid,arch=arm64" -enableCodeCoverage NO -derivedDataPath "$work/dd-ui" \
    -resultBundlePath "$work/ui.xcresult" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    -quiet "${ui_suites[@]}" >"$work/ui-test.log" 2>&1
  ui_status=$?
  set -e
  xcrun simctl shutdown "$ui_udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$ui_udid" >/dev/null 2>&1 || true
  ui_udid=""
  keep_test_logs "$work/ui-test.log" "$work/ui.xcresult" ui
  grep -h "^FAILED:" -A3 "$out/ui-tests-failures.txt" 2>/dev/null || true
  note "- UI tests ${ui_suites[*]}: exit $ui_status, $(cat "$out/ui-tests-counts.txt" 2>/dev/null || echo "no result bundle"), $((SECONDS - t0)) s"
fi

# --- Chief layout benchmark -------------------------------------------------
if [[ "$mode" == chief-live-perf || "$mode" == chief-live-perf-baseline ]]; then
  perf_udid="$(xcrun simctl create "cmux-chief-perf-${CMUX_CI_STEP_KEY:-local}" "$device_type" "$runtime")"
  perf_flags=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited)')
  if [[ "$mode" == chief-live-perf-baseline ]]; then
    perf_flags=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_CHIEF_LIVE_BASELINE')
  fi
  note "## Chief live layout ($mode): three runs, one warm-up + three samples per run"
  note "- harness sha256: $(shasum -a 256 cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileChiefTests/ChiefLiveLayoutPerformanceTests.swift | awk '{print $1}')"
  perf_status=0
  for run in 1 2 3; do
    # TEST_RUNNER_ forwards this opt-in to the simulator test process. No
    # controller env allowlist change is needed: the mode owns the setting.
    # Keep one simulator and DerivedData for all runs; only the result path varies.
    set +e
    (cd cmux-next-ios/CmuxMobileKit && TEST_RUNNER_CMUX_CHIEF_LIVE_PERF=1 xcodebuild test \
      -scheme CmuxMobileKit-Package -destination "id=$perf_udid,arch=arm64" \
      -enableCodeCoverage NO -parallel-testing-enabled NO \
      -only-testing:CmuxMobileChiefTests/ChiefLiveLayoutPerformanceTests \
      -derivedDataPath "$work/dd-chief-perf" \
      -resultBundlePath "$out/bench/chief-live-$run.xcresult" \
      CODE_SIGNING_ALLOWED=NO "${perf_flags[@]}") > "$out/bench/chief-live-$run.log" 2>&1
    run_status=$?
    set -e
    note "- run $run: xcodebuild exit $run_status"
    if [[ "$run_status" -ne 0 ]]; then
      tail -60 "$out/bench/chief-live-$run.log"
      perf_status=$run_status
      break
    fi
    xcrun xcresulttool get log --type console --path "$out/bench/chief-live-$run.xcresult" \
      > "$out/bench/chief-live-$run-console.log" 2>/dev/null || true
    if ! grep -h 'CHIEF_LIVE_LAYOUT main_thread_ms_per_1000_tokens=' "$out/bench/chief-live-$run.log" "$out/bench/chief-live-$run-console.log" \
      > "$out/bench/chief-live-$run.txt"; then
      note "- ERROR: run $run produced no measurement; a skipped test is not a benchmark pass. See its log and xcresult."
      perf_status=1
      break
    fi
    cat "$out/bench/chief-live-$run.txt" | tee -a "$summary"
  done
  xcrun simctl shutdown "$perf_udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$perf_udid" >/dev/null 2>&1 || true
  perf_udid=""
fi

# --- Benchmarks -------------------------------------------------------------
if [[ "$mode" == bench || "$mode" == all ]]; then
  corpus="$work/corpus"
  mkdir -p "$corpus"
  # A 6 MB real text file: this checkout's Swift sources.
  # head closes the pipe early; the SIGPIPE upstream is expected (pipefail).
  { git ls-files -z '*.swift' | xargs -0 cat 2>/dev/null | head -c 6000000 > "$corpus/big.txt"; } || true
  [[ -s "$corpus/big.txt" ]] || { echo "error: empty benchmark corpus" >&2; exit 1; }
  # Record each workload through a real PTY at a phone-like grid (50 x 45).
  record() { # name, command...
    local name=$1; shift
    local start end
    start=$(python3 -c 'import time; print(time.time())')
    TERM=xterm-256color script -q "$corpus/$name.typescript" sh -c "stty rows 45 cols 50; $*" </dev/null >/dev/null 2>&1 || true
    end=$(python3 -c 'import time; print(time.time())')
    python3 - "$corpus/$name.typescript" "$start" "$end" > "$corpus/$name.rate" <<'PY'
import os, sys
size = os.path.getsize(sys.argv[1]); secs = max(float(sys.argv[3]) - float(sys.argv[2]), 0.05)
print(f"{min(size * 8 / secs / 1e6, 50.0):.3f} {size} {secs:.2f}")
PY
  }
  record cat "cat '$corpus/big.txt'"
  cat > "$corpus/scroll.vim" <<'VIM'
set number
set filetype=c
syntax on
for i in range(1500)
  execute "normal! \<C-e>"
  redraw
endfor
qa!
VIM
  record vim "vim -u NONE -i NONE -N -n -S '$corpus/scroll.vim' '$corpus/big.txt'"
  if command -v htop >/dev/null; then top_cmd="htop -d 10"; top_name="htop"; else top_cmd="top -s 1"; top_name="top (htop not installed)"; fi
  # In the foreground (a background job is stopped by SIGTTOU when it sets the
  # tty mode); the alarm survives exec and ends it after 12 s.
  record top "perl -e 'alarm 12; exec @ARGV' $top_cmd"
  note ""
  note "## Flood benchmark (Demo build, in-app TerminalFloodBench, fake Mac daemon, real DaemonClient + Ghostty renderer)"
  note ""
  note "| Workload | Bytes | Replay Mbit/s | Main CPU ms/s | App CPU ms/s | Frames/s | Frame p50 / p95 / max ms | Echo p50 / p90 / max ms | Idle echo p50 / p90 ms | Drain ms |"
  note "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
  for name in cat vim top; do
    read -r mbps size _secs < "$corpus/$name.rate"
    simctl launch "$udid" "$bundle_id" -CmuxMobileFloodBench -CmuxMobileFloodBenchFile "$corpus/$name.typescript" \
      -CmuxMobileFloodBenchMbps "$mbps" -CmuxMobileFloodBenchSeconds 10 >/dev/null
    data="$(simctl get_app_container "$udid" "$bundle_id" data)"
    result="$data/Documents/flood-bench.json"
    rm -f "$result"
    # Screens at fixed points of the run (3 s idle, 10 s flood, 6 s after): bounded delays, not a sync.
    sleep 9; simctl io "$udid" screenshot "$out/screens/$name-flood.png" >/dev/null
    deadline=$((SECONDS + 60))
    until [[ -s "$result" ]] || (( SECONDS > deadline )); do sleep 1; done
    simctl io "$udid" screenshot "$out/screens/$name-after.png" >/dev/null
    simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
    if [[ ! -s "$result" ]]; then note "| $name | $size | $mbps | no result (timed out) | | | | | | |"; continue; fi
    cp "$result" "$out/bench/$name.json"
    python3 - "$out/bench/$name.json" "$name" "$size" "$mbps" >> "$summary" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["summary"]; f = s["flood"]; i = s.get("idle", {})
print(f"| {sys.argv[2]} | {int(sys.argv[3]):,} | {float(sys.argv[4]):.2f} | {f['mainCPUmsPerSecondAvg']} | {f.get('processCPUmsPerSecondAvg', '-')} | "
      f"{f['presentsPerSecondAvg']:.0f} | {f.get('frameIntervalP50ms', '-')} / {f.get('frameIntervalP95ms', '-')} / {f.get('frameIntervalMaxms', '-')} | "
      f"{f['echoP50ms']} / {f['echoP90ms']} / {f['echoMaxms']} | {i.get('echoP50ms', '-')} / {i.get('echoP90ms', '-')} | {s['drainAfterStopMs']:.0f} |")
PY
  done
  note ""
  note "Workload top ran: $top_name. Recordings: 50 columns x 45 rows; replayed in a loop for 10 s at the rate the program wrote them (capped at 50 Mbit/s)."
  tail -n +1 "$summary" | tail -8
fi

# --- Screens ----------------------------------------------------------------
if [[ "$mode" == shots ]]; then
  t0=$SECONDS
  # Setup marked complete, so a deep link lands on its screen instead of "Choose a space".
  simctl spawn "$udid" defaults write "$bundle_id" cmuxMobile.setupComplete -bool YES
  note ""
  note "## Screens (mock data, DEBUG launch arguments)"
  note ""
  for scene in "${scenes[@]}"; do
    name="${scene%%=*}"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$scene" == *=?* ]] || { note "- skipped scene '$scene': want name=WORD,WORD,..."; continue; }
    IFS=',' read -r -a words <<< "${scene#*=}"
    envs=(SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1)
    args=()
    for w in ${words[@]+"${words[@]}"}; do
      if [[ ${#args[@]} -eq 0 && "$w" =~ ^[A-Z_][A-Z0-9_]*= ]]; then envs+=("SIMCTL_CHILD_$w"); else args+=("$w"); fi
    done
    for look in dark light; do
      simctl ui "$udid" appearance "$look" >/dev/null 2>&1 || true
      env "${envs[@]}" xcrun simctl --set "$sims" launch "$udid" "$bundle_id" ${args[@]+"${args[@]}"} >/dev/null
      # A bounded wait for the scene to draw; demo drivers have no signal to wait on.
      sleep "${CMUX_NEXT_IOS_SHOT_WAIT:-5}"
      simctl io "$udid" screenshot "$out/screens/$name-$look.png" >/dev/null
      simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
    done
    note "- $name: screens/$name-dark.png, screens/$name-light.png"
  done
  simctl ui "$udid" appearance dark >/dev/null 2>&1 || true
  note "- screens: $((SECONDS - t0)) s"
fi

# --- List frame rate (listperf) --------------------------------------------
if [[ "$mode" == listperf ]]; then
  t0=$SECONDS
  lp="$out/listperf"
  mkdir -p "$lp"
  sides=(head)
  [[ -z "$base_app" ]] || sides=(base head)
  note ""
  note "## List frame rate (ListStressRig, Demo build, ${device_type##*.} on ${runtime##*.})"
  note ""
  note "| Run | Window | Frames | p99 ms | Max ms | Hitch ms/s | Main CPU ms/s |"
  note "| --- | --- | --- | --- | --- | --- | --- |"
  for rep in $(seq 1 "$listperf_reps"); do
    for case_name in "${listperf_cases[@]}"; do
      line="$(printf '%s\n' "${listperf_table[@]}" | awk -v c="$case_name" '$1 == c')"
      read -r _label screen settings <<< "$line"
      for side in "${sides[@]}"; do
        run="$side-$case_name-r$rep"
        side_app="$app"
        [[ "$side" == head ]] || side_app="$base_app"
        envs=(SIMCTL_CHILD_CMUX_MOBILE_FRAMELOG=1 SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1
          "SIMCTL_CHILD_CMUX_MOBILE_LIST_SCREEN=$screen" SIMCTL_CHILD_CMUX_MOBILE_LIST_EXIT_WHEN_DONE=1)
        for kv in $settings; do envs+=("SIMCTL_CHILD_CMUX_MOBILE_$kv"); done
        # A clean install of this side's app: no data container carried over from the other side.
        simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
        simctl uninstall "$udid" "$bundle_id" >/dev/null 2>&1 || true
        simctl install "$udid" "$side_app"
        started=$SECONDS
        # The rig exits the app after its last pass; bounded at 300 s (rig.sh's WAIT).
        env "${envs[@]}" perl -e 'alarm shift; exec @ARGV' 300 xcrun simctl --set "$sims" launch --console-pty \
          --terminate-running-process "$udid" "$bundle_id" -cmuxMobile.setupComplete YES -cmux-mobile-no-restore \
          >"$lp/$run.console.txt" 2>&1 || { echo "$run: launch exited $? (142: the 300 s bound)"; listperf_status=1; }
        simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
        caches="$(simctl get_app_container "$udid" "$bundle_id" data)/Library/Caches"
        cp "$caches/framelog.jsonl" "$lp/$run.jsonl" 2>/dev/null || : >"$lp/$run.jsonl"
        simctl spawn "$udid" log show --last "$(( SECONDS - started + 30 ))s" --style compact \
          --predicate 'subsystem == "dev.cmux.mobile" AND category == "frames"' 2>/dev/null |
          grep -E 'list-stress' | sed 's/^/# /' >>"$lp/$run.jsonl" || true
        python3 -I cmux-next-ios/verify/feedperf/summarize.py "$lp/$run.jsonl" >"$lp/$run.txt" 2>&1 || true
        echo "== $run ($(( SECONDS - started )) s)"
        grep -E 'POOLED|-open' "$lp/$run.txt" || { echo "$run: no windows"; listperf_status=1; }
        python3 -I - "$lp/$run.txt" "$run" >>"$summary" <<'PY'
import sys
path, run = sys.argv[1], sys.argv[2]
rows = 0
for line in open(path):
    words = line.split()
    if not words or not (words[0] == "POOLED" or "-open" in words[0]):
        continue
    kv = dict(w.split("=", 1) for w in words if "=" in w)
    print(f"| {run} | {words[0]} | {kv.get('frames', '-')} | {kv.get('p99', '-')} | {kv.get('max', '-')} | "
          f"{kv.get('hitch_ms_per_s', '-')} | {kv.get('main_cpu_ms_per_s', '-')} |")
    rows += 1
if not rows:
    print(f"| {run} | no windows | | | | | |")
PY
      done
    done
  done
  simctl uninstall "$udid" "$bundle_id" >/dev/null 2>&1 || true
  note "- listperf: $((SECONDS - t0)) s; sides: ${sides[*]}; reps: $listperf_reps; logs: listperf/"
  [[ "${listperf_status:-0}" -eq 0 ]] || note "- listperf: FAILED (a run did not finish or measured no windows; see listperf/)"
fi

# --- Pairing by QR code ----------------------------------------------------
if [[ "$mode" == pair-e2e ]]; then
  t0=$SECONDS
  # A tag of this run only: its own bundle id, socket, settings and state.
  mac_tag="iospair-$(git rev-parse --short=8 HEAD)-$$"
  prev_last_log="$(cat /tmp/cmux-last-debug-log-path 2>/dev/null || true)"
  mac_dd="$work/mac-dd"
  # A fleet step checks out no submodules (only their empty gitlink directories): the Mac app
  # needs Ghostty's headers, the ghostty-next tree and GhosttyKit.xcframework (a prebuilt
  # download), as the measure steps do (scripts/measure/action-signposts.sh). Without them
  # reload.sh stops at once: "ghostty/include/ghostty.h is missing" (step 4baf44ec, 2026-10-27).
  for sub in ghostty ghostty-next; do
    [[ -e "$sub/.git" ]] || git submodule update --init --depth 1 "$sub" >"$work/submodules.log" 2>&1 ||
      { tail -20 "$work/submodules.log"; echo "error: could not check out the $sub submodule" >&2; exit 1; }
  done
  if [[ ! -f GhosttyKit.xcframework/Info.plist ]]; then
    rm -rf GhosttyKit.xcframework
    if [[ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" && -n "${CI_SHARED_CACHE_DIR:-}" ]]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    ./scripts/download-prebuilt-ghosttykit.sh >"$work/ghosttykit.log" 2>&1 ||
      { tail -20 "$work/ghosttykit.log"; echo "error: could not download GhosttyKit.xcframework" >&2; exit 1; }
  fi
  # A fleet build (CMUX_FLEET_BUILD_TAG) builds acpmux, optchat-chief and
  # cmux-mobile-host on a cache miss and requires them in the bundle.
  set +e
  CMUX_FLEET_BUILD_TAG="$mac_tag" ./scripts/reload.sh --tag "$mac_tag" --derived-data "$mac_dd" \
    --no-global-cli-links >"$work/mac-build.log" 2>&1
  status=$?
  set -e
  cp "$work/mac-build.log" "$out/mac-build.log"
  mac_app="$mac_dd/Build/Products/Debug/cmux DEV $mac_tag.app"
  [[ $status -eq 0 && -d "$mac_app" ]] || { tail -60 "$work/mac-build.log"; echo "error: tagged cmux NEXT Mac app build failed" >&2; exit 1; }
  note "- Mac app: $((SECONDS - t0)) s (reload.sh --tag $mac_tag, Debug)"
  set +e
  python3 -I scripts/ci/cmux_next_pair_e2e.py --mac-app "$mac_app" --ios-app "$app" --sims "$sims" \
    --udid "$udid" --bundle-id "$bundle_id" --work "$work" --out "$out" --summary "$summary"
  pair_status=$?
  set -e
fi

# Cloud proof mode exports an allowlisted receipt only. The ordinary pair-e2e
# mode keeps its existing diagnostics and app artifact. This boundary runs
# after Python teardown, so a Python failure cannot leave raw Cloud captures in
# the public archive; a missing receipt makes the step fail.
if [[ -n "${CMUX_IOS_CLOUD_PROOF_FILE:-}" ]]; then
  python3 -I scripts/ci/cmux_next_cloud_pair_proof.py --export-out "$out" --status "${pair_status:-0}" || pair_status=1
  cat "$out/SUMMARY.md"
  [[ "${pair_status:-0}" -eq 0 ]] || pair_status=1
else
  # The app log goes through the pairing redactor: a pairing link or token it logged never reaches the artifact.
  simctl spawn "$udid" log show --last 10m --style compact --predicate 'process == "CmuxMobileApp"' 2>/dev/null |
    python3 -I scripts/ci/cmux_next_pair_e2e.py --redact > "$out/app-log.txt" || true
  cp "$work/build.log" "$out/build.log" 2>/dev/null || true
  # The app (so the same build runs on another Mac's simulator) and the recordings.
  ditto -c -k --keepParent "$app" "$out/CmuxMobileApp-Demo-simulator.app.zip"
  if [[ -d "$work/corpus" ]]; then
    mkdir -p "$out/corpus"
    cp "$work/corpus/"*.typescript "$work/corpus/"*.rate "$out/corpus/" 2>/dev/null || true
  fi
  (cd "$out" && rm -f evidence.zip && zip -qr evidence.zip . -x evidence.zip)
fi
if [[ -z "${CMUX_IOS_CLOUD_PROOF_FILE:-}" ]]; then
  cat "$summary"
fi
if [[ "${test_status:-0}" -ne 0 ]]; then exit "$test_status"; fi
if [[ "${ui_status:-0}" -ne 0 ]]; then exit "$ui_status"; fi
if [[ "${pair_status:-0}" -ne 0 ]]; then exit "$pair_status"; fi
if [[ "${listperf_status:-0}" -ne 0 ]]; then exit "$listperf_status"; fi

if [[ "${perf_status:-0}" -ne 0 ]]; then exit "$perf_status"; fi
