#!/usr/bin/env bash
# The mobile bench's reference capture on a Mac: an iPhone app that the App Store offers on the Mac ("Designed for
# iPhone", run natively on Apple Silicon) recorded through the mobile bench's flows (scripts/mobile-bench/flows.json),
# one clip each, at 120 fps, for frame-by-frame measurement next to cmux's own iPhone app.
# Leo, 2026-11-19: "looking at the mobile apps and their various, you know, animations, their flows or whatever, and
# the elements for like [...] or Claude ... the actual like measurement to measurement speeds, the benchmarks of whatever."
#   cmux-ci run --class exclusive --measurement --label measure --display --key KEY \
#     --script scripts/measure/mobile-bench-mac-capture.sh --ref <feat-cmux-next sha> \
#     --arg=app=BUNDLE_ID --arg=flows=new-chat,scroll-fling [--arg=name=SHORT] [--arg=profile=BASE64URL_JSON] \
#     [--arg=hz=120] [--arg=status-of=BUNDLE_ID,BUNDLE_ID] \
#     --artifact artifacts/mobile-bench-mac-capture/capture.tgz --timeout 1800
#   app=BUNDLE_ID      the app (found by LaunchServices, or by its wrapped bundle id under /Applications)
#   flows=ID,ID        flows.json ids (default all: every flow the profile names)
#   name=SHORT         its name in the output (<out>/<name>/<flow>/), default the profile's
#   profile=B64        the app's drive profile as base64url JSON (scripts/mobile-bench/mac/apps/*.json's shape), for an
#                      app whose profile is kept outside this repo; default apps/BUNDLE_ID.json
#   status-of=IDS      also report these bundle ids' install state (version, iPhone app or not), and nothing else
# Steps, in the console user's GUI session (console-session.sh): the Mac's App Store sign-in state and every iPhone
# app installed; a virtual display at hz= as the main display (scripts/ci/frame-pacing/vdisplay.m, 1600x1200 points at
# 2x); the app opened, its window put at a phone's size (430 x 932 pt); per flow a ScreenCaptureKit recording of the
# window at hz= (every frame's own presentation time kept, H.264 High) around the flow's stimulus (CGEvents at
# mach-time deadlines, scripts/journeys/hid_inject.swift, on the recorder's clock). Without this step's own Screen
# Recording or PostEvent grant it records through CuaDriver (a marker flip times the stimulus) and drives through
# `cua-driver call`; meta.json names the routes taken. An iPhone app on a Mac has no software keyboard: the keyboard
# flows are reported unsupported, with that reason.
# Output: artifacts/mobile-bench-mac-capture/capture.tgz holding <name>/<flow>/clip.mp4 + meta.json (the clip
# contract: app, flow, source, device, os, app_version, recorded_at, stimulus_t, fps_nominal), recorder.json,
# input.json, run.json and status.json; MOBILEBENCH marker lines (scripts/mobile-bench/cut.py's) in the log.
# Exit 0 when it ran (an app that is not installed is a status, not a failure: the artifact says so), 2 bad arguments,
# 3 nothing could be recorded.
set -uo pipefail
app="" flows="" name="" profile="" hz=120 status_of=""
for arg in "$@"; do
  case "$arg" in
    app=*) app="${arg#app=}" ;;
    flows=*) flows="${arg#flows=}" ;;
    name=*) name="${arg#name=}" ;;
    profile=*) profile="${arg#profile=}" ;;
    hz=*) hz="${arg#hz=}" ;;
    status-of=*) status_of="${arg#status-of=}" ;;
    *) echo "mobile-bench-mac-capture: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ -z "$app" || "$app" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "mobile-bench-mac-capture: app= is a bundle id" >&2; exit 2; }
[[ "$flows" =~ ^[a-z0-9,-]*$ && "$name" =~ ^[a-z0-9-]*$ && "$profile" =~ ^[A-Za-z0-9_=-]*$ ]] ||
  { echo "mobile-bench-mac-capture: flows= and name= take ids, profile= base64url" >&2; exit 2; }
[[ "$hz" =~ ^(60|90|120)$ ]] || { echo "mobile-bench-mac-capture: hz= is 60, 90 or 120" >&2; exit 2; }
[[ "$status_of" =~ ^[A-Za-z0-9.,-]*$ ]] || { echo "mobile-bench-mac-capture: status-of= takes bundle ids" >&2; exit 2; }
[[ -n "$app" || -n "$status_of" ]] || { echo "mobile-bench-mac-capture: app= or status-of= is needed" >&2; exit 2; }

root="$(git rev-parse --show-toplevel)"
cd "$root" || exit 3
out="$root/artifacts/mobile-bench-mac-capture"
rm -rf "$out" && mkdir -p "$out/clips" && chmod -R 0777 "$out"
tools="$(mktemp -d)"
# Only this run's own folder, by the path mktemp gave.
trap 'rm -rf -- "$tools"' EXIT
chmod 0755 "$tools" # the harness runs as the console user (console-session.sh)
echo "MBC host $(scutil --get ComputerName 2>/dev/null || hostname) model=$(sysctl -n hw.model) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername) load=\"$(sysctl -n vm.loadavg)\""

xcrun swiftc -O -parse-as-library -o "$tools/mbcap" scripts/mobile-bench/mac/mbcap.swift >"$tools/mbcap.log" 2>&1 ||
  { echo "MBC mbcap did not compile"; tail -n 40 "$tools/mbcap.log"; exit 3; }
xcrun swiftc -O -o "$tools/hid_inject" scripts/journeys/hid_inject.swift >"$tools/hid.log" 2>&1 ||
  { echo "MBC hid_inject did not compile"; tail -n 40 "$tools/hid.log"; exit 3; }
xcrun swiftc -O -o "$tools/tab-switch-tools" scripts/measure/tab-switch-frames/tools.swift >"$tools/tst.log" 2>&1 ||
  { echo "MBC tab-switch-tools did not compile"; tail -n 40 "$tools/tst.log"; exit 3; }
vd="$tools/VDisplay.app"
mkdir -p "$vd/Contents/MacOS"
xcrun clang -fobjc-arc -O2 -Wno-deprecated-declarations -framework AppKit -framework CoreVideo \
  scripts/ci/frame-pacing/vdisplay.m -o "$vd/Contents/MacOS/VDisplay" >"$tools/vd.log" 2>&1 ||
  { echo "MBC vdisplay did not compile"; tail -n 40 "$tools/vd.log"; exit 3; }
cp scripts/ci/frame-pacing/VDisplay-Info.plist "$vd/Contents/Info.plist"
codesign -s - --force "$vd" >/dev/null 2>&1 || true
codesign -s - --force "$tools/mbcap" "$tools/hid_inject" "$tools/tab-switch-tools" >/dev/null 2>&1 || true

# The Mac's App Store state: who is signed in (if anyone), and every iPhone or iPad app installed. Read-only.
# Read as the console user (the account an App Store sign-in belongs to); an account name shows only its first 3
# characters.
in_console() { GITHUB_WORKSPACE="$root" scripts/ci/frame-pacing/console-session.sh "$@" 2>/dev/null; }
store_account="$( (for domain in com.apple.commerce com.apple.storeagent com.apple.AppStore com.apple.appstored; do
    in_console /usr/bin/defaults read "$domain" | sed "s/^/$domain: /"
  done) | grep -iE 'AppleID|primaryAccount|accountName|DSID|SignedIn|StoreAccount' |
  sed -E 's/[[:space:]]+/ /g; s/(= "?[^";@]{3})[^";]*/\1.../' | head -n 8)"
mas_account="$(in_console /bin/bash -c 'PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; command -v mas >/dev/null && mas account 2>&1 | head -n 1 || echo "no mas"' |
  sed -E 's/^([^@ ]{3})[^@ ]*@.*/\1...@.../')"
GITHUB_WORKSPACE="$root" scripts/ci/frame-pacing/console-session.sh "$tools/mbcap" wrapped >"$out/wrapped.json" 2>&1
{
  printf '{"host": "%s", "model": "%s", "macos": "%s", "store_account_keys": %s, "mas": %s, "wrapped": %s, "apps": {' \
    "$(scutil --get ComputerName 2>/dev/null || hostname)" "$(sysctl -n hw.model)" "$(sw_vers -productVersion)" \
    "$(python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "${store_account:-none}")" \
    "$(python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$mas_account")" \
    "$(grep -m1 '^{' "$out/wrapped.json" || echo null)"
  sep=""
  for id in ${status_of//,/ } ${app:+$app}; do
    printf '%s"%s": %s' "$sep" "$id" "$(GITHUB_WORKSPACE="$root" scripts/ci/frame-pacing/console-session.sh "$tools/mbcap" app "$id" 2>/dev/null | grep -m1 '^{' || echo null)"
    sep=", "
  done
  printf '}}\n'
} >"$out/clips/status.json"
echo "MBC STATUS $(cat "$out/clips/status.json")"

rc=0
if [[ -n "$app" ]]; then
  args=(--app "$app" --out "$out/clips" --tools "$tools" --vdisplay "$vd" --hz "$hz")
  [[ -n "$flows" ]] || flows=all  # every flow the profile names
  args+=(--flows "$flows")
  [[ -n "$name" ]] && args+=(--name "$name")
  [[ -n "$profile" ]] && args+=(--profile-b64 "$profile")
  GITHUB_WORKSPACE="$root" scripts/ci/frame-pacing/console-session.sh \
    python3 -I "$root/scripts/mobile-bench/mac/capture.py" "${args[@]}" 2>&1 | tee "$out/clips/capture.log"
  rc=${PIPESTATUS[0]}
  echo "MBC capture.py exit $rc"
  find "$out/clips" -name meta.json -exec sh -c 'echo "MBC META $1 $(tr -d "\n" <"$1")"' _ {} \;
fi
tar -czf "$out/capture.tgz" -C "$out/clips" . && echo "MBC ARTIFACT $out/capture.tgz $(stat -f %z "$out/capture.tgz") bytes"
# 3 from capture.py is "not installed": a status the artifact reports, so the step still passes and returns it.
[[ "$rc" == 0 || "$rc" == 3 ]] && exit 0
exit 3
