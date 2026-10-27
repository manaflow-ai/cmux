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
#   build   CmuxMobileLinkFFI.xcframework, xcodegen, and the app for the
#           simulator (Demo: optimized, with the DEBUG developer surface); then
#           boot one iPhone, install, launch, screenshot.
#   test    build, plus `xcodebuild test` of CmuxMobileKit on that iPhone.
#   bench   build, plus the in-app flood benchmark (TerminalFloodBench,
#           verify/terminal-flood.md) on PTY recordings made on the worker:
#             cat     `cat` of a 6 MB source file
#             vim     vim scrolling that file a line per redraw (Ctrl-E)
#             top     top refreshing once a second (htop when installed)
#           Each recording is replayed at the rate the program wrote it (capped
#           at 50 Mbit/s), with screenshots during and after the flood.
#   all     build, test and bench.
#   pair-e2e
#           build, plus a tagged DEBUG cmux NEXT Mac app built here
#           (reload.sh), and pairing by its QR code end to end
#           (cmux_next_pair_e2e.py): the Mac's Mobile Pairing link, opened on
#           the iPhone, pairs it with no Allow prompt and no test seed. Screens
#           of the Mac page (never while it shows a code: its image carries
#           the token), the phone's Settings > Devices (a base ref gives
#           the "before") and its scanner with the camera off; the Mac's
#           pairing log, hostd's log and paired-devices.json, keys redacted.
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
case "$mode" in build|test|bench|all|pair-e2e) ;; *) echo "cmux-next-ios-sim.sh: MODE is build, test, bench, all or pair-e2e, got '$mode'" >&2; exit 2 ;; esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
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
cleanup() {
  if [[ -n "$sims" ]]; then
    xcrun simctl --set "$sims" shutdown all >/dev/null 2>&1 || true
    xcrun simctl --set "$sims" delete all >/dev/null 2>&1 || true
    rm -rf "$sims" || true
  fi
  # Attempted even when the simulator set's removal failed.
  if [[ -n "$xcodegen_dir" ]]; then rm -rf "$xcodegen_dir" || true; fi
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
}
trap cleanup EXIT

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

note "# cmux-next-ios simulator step ($mode)"
note ""
note "- commit: $(git rev-parse HEAD)"
note "- host: $(hostname -s), $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, macOS $(sw_vers -productVersion)"
note "- Xcode: $(xcodebuild -version | tr '\n' ' ')"
note "- xcodegen: $xcodegen_version (pinned, sha256 verified)"

# --- Build ------------------------------------------------------------------
t0=$SECONDS
JOBS="${JOBS:-8}" bash cmux-next-ios/rust/scripts/build-xcframework.sh >"$work/ffi.log" 2>&1 || {
  tail -60 "$work/ffi.log"; echo "error: CmuxMobileLinkFFI.xcframework build failed" >&2; exit 1; }
(cd cmux-next-ios && "$xcodegen" generate -q)
dd="$work/dd"
# Demo builds the Swift packages as Release (no DEBUG), so the flood benchmark
# and terminal demo would be missing; the command-line conditions reach the
# packages too (verify/terminal-flood.md, Reproducing).
set +e
xcodebuild -project cmux-next-ios/CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Demo \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$dd" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CMUX_MOBILE_DEMO' \
  build >"$work/build.log" 2>&1
status=$?
set -e
grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$work/build.log" | sort -u | head -40 || true
[[ $status -eq 0 ]] || { tail -40 "$work/build.log"; exit 1; }
app="$dd/Build/Products/Demo-iphonesimulator/CmuxMobileApp.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
note "- build: $((SECONDS - t0)) s (FFI + xcodegen + Demo simulator app), bundle $bundle_id"

# --- Simulator --------------------------------------------------------------
sims="$work/sims"
mkdir -p "$sims"
simctl() { xcrun simctl --set "$sims" "$@"; }
read -r runtime device_type < <(xcrun simctl list -j runtimes devicetypes | python3 -c '
import json, sys
d = json.load(sys.stdin)
rts = [r for r in d["runtimes"] if r.get("isAvailable") and r.get("platform") == "iOS"]
rts.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
rt = rts[-1]
names = {t["name"]: t["identifier"] for t in rt.get("supportedDeviceTypes", [])}
for want in ("iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro"):
    if want in names:
        print(rt["identifier"], names[want]); break
else:
    print(rt["identifier"], [v for k, v in names.items() if k.startswith("iPhone")][-1])
')
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

# --- Tests ------------------------------------------------------------------
if [[ "$mode" == test || "$mode" == all ]]; then
  t0=$SECONDS
  # xcodebuild sees only the default device set: the tests get their own new
  # iPhone there, deleted by its UDID afterwards (never another step's device).
  test_udid="$(xcrun simctl create "cmux-next-ios-sim-test-${CMUX_CI_STEP_KEY:-local}" "$device_type" "$runtime")"
  set +e
  (cd cmux-next-ios/CmuxMobileKit && xcodebuild test -scheme CmuxMobileKit-Package \
    -destination "id=$test_udid,arch=arm64" -enableCodeCoverage NO -derivedDataPath "$work/dd-test" \
    -resultBundlePath "$work/kit.xcresult" CODE_SIGNING_ALLOWED=NO -quiet) >"$work/test.log" 2>&1
  test_status=$?
  set -e
  xcrun simctl shutdown "$test_udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$test_udid" >/dev/null 2>&1 || true
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
  note "- CmuxMobileKit tests (iOS simulator): exit $test_status, $counts, $((SECONDS - t0)) s"
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

# --- Pairing by QR code ----------------------------------------------------
if [[ "$mode" == pair-e2e ]]; then
  t0=$SECONDS
  # A tag of this run only: its own bundle id, socket, settings and state.
  mac_tag="iospair-$(git rev-parse --short=8 HEAD)-$$"
  prev_last_log="$(cat /tmp/cmux-last-debug-log-path 2>/dev/null || true)"
  mac_dd="$work/mac-dd"
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
cat "$summary"
if [[ "${test_status:-0}" -ne 0 ]]; then exit "$test_status"; fi
if [[ "${pair_status:-0}" -ne 0 ]]; then exit "$pair_status"; fi
