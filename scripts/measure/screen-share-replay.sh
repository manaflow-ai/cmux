#!/usr/bin/env bash
# The screen-share viewer's Decode + Present, read in a published cmux NEXT NIGHTLY with no host peer: a recorded
# share (a display recording of a moving window, or a movie you name) is replayed through a Screen Sharing tab's
# own decoder and presenter (`cmux app mac-screen-replay`, cmux#64138), and the pane's decode_present_ms is the
# number. Goal screen-share-viewer-present (hq goals/screen-share-viewer-present.md): NOW's
# screen_share_fast.viewer_decode_present_p50_ms, read from a replay run when no pair run has it.
#   cmux-ci run --class exclusive --label measure --display --script scripts/measure/screen-share-replay.sh \
#     --ref <sha> [--arg=build=VERSION | --arg=dmg=URL] [--arg=movie=PATH] [--arg=seconds=8] [--arg=frames=120] \
#     --artifact .build/screen-share-replay/report.tgz --timeout 1800
#   build=VERSION  a NIGHTLY's build number: its DMG on files-next.cmux.com (default: the newest in the NEXT feed)
#   dmg=URL        any NIGHTLY DMG
#   movie=PATH     replay this H.264 or HEVC movie (on the worker) instead of recording one
#   seconds=N      the recording's length (default 8)
#   frames=N       frames to wait for on the glass (1-120, default 120)
# The app is a side instance (scripts/cmux-next/side-instance.sh: its own bundle id and data; the Mac's own apps
# are untouched). Without movie=, scripts/measure/screen-share-replay-motion.swift animates a window while
# CuaDriver (the fleet's granted recorder) records the display; `cmux tab new-mac-screen` opens the viewer tab
# and `cmux app mac-screen-replay --tab T --path REC --frames N --json` plays it.
# Prints SSR lines and `SSR RESULT {json}` (the replay report plus host, app, commit); report.tgz holds replay.json
# and the recording. Exit 0 when frames reached the glass, 1 when the replay did not present, 3 the rig could not
# run it (no download, no CuaDriver, no app socket).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/screen-share-replay"
rm -rf "$out" && mkdir -p "$out"
dmg="" build="" movie="" seconds=8 frames=120
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    build=*) build="${arg#build=}" ;;
    movie=/*) movie="${arg#movie=}" ;;
    seconds=*) seconds="${arg#seconds=}" ;;
    frames=*) frames="${arg#frames=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$seconds" =~ ^[0-9]+$ && "$seconds" -ge 2 && "$seconds" -le 60 ]] || { echo "seconds=N takes 2-60" >&2; exit 2; }
[[ "$frames" =~ ^[0-9]+$ && "$frames" -ge 1 && "$frames" -le 120 ]] || { echo "frames=N takes 1-120" >&2; exit 2; }
if [[ -n "$build" ]]; then
  [[ "$build" =~ ^[0-9]+$ ]] || { echo "build=VERSION takes a NIGHTLY build number" >&2; exit 2; }
  dmg="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-$build.dmg"
fi
if [[ -z "$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
host="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
echo "SSR host $host macOS $(sw_vers -productVersion) session $(launchctl managername) dmg $dmg"

work="$(mktemp -d "${TMPDIR:-/tmp}/screen-share-replay.XXXXXX")"
mkdir -p "$work/side" "$work/app"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
side="$root/scripts/cmux-next/side-instance.sh"
name="ssreplay"
mnt="" motion_pid=""
# shellcheck disable=SC2317  # run by the EXIT trap
cleanup() {
  [[ -n "$motion_pid" ]] && kill "$motion_pid" 2>/dev/null
  "$side" stop "$name" >/dev/null 2>&1 || true
  "$side" remove "$name" >/dev/null 2>&1 || true
  [[ -n "$mnt" ]] && hdiutil detach "$mnt" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "SSR download failed"; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
app="$work/app/cmux NIGHTLY.app"
ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$app" || exit 3
hdiutil detach "$mnt" >/dev/null || exit 3
mnt=""
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist" 2>/dev/null || true; }
commit="$(pb CMUXCommit)"
echo "SSR app version $(pb CFBundleShortVersionString) build $(pb CFBundleVersion) commit $commit"

# The movie first: the app is not running yet, so nothing else is on the display but the motion window.
rec="$out/recording.mp4"
if [[ -n "$movie" ]]; then
  [[ -f "$movie" ]] || { echo "SSR movie $movie not found"; exit 3; }
  cp "$movie" "$rec" || exit 3
  recording="$(basename "$movie")"
else
  xcrun swiftc -O -o "$work/motion" scripts/measure/screen-share-replay-motion.swift 2>"$out/swiftc.log" \
    || { cat "$out/swiftc.log" >&2; exit 3; }
  "$work/motion" "$((seconds + 4))" >"$work/motion.out" 2>&1 &
  motion_pid=$!
  for _ in $(seq 1 20); do grep -q READY "$work/motion.out" 2>/dev/null && break; sleep 0.5; done
  grep -q READY "$work/motion.out" || { echo "SSR the motion window did not open"; exit 3; }
  python3 scripts/measure/launch_reveal_record.py record "$work/rec" "$seconds" >"$work/rec.out" 2>&1
  rc=$?
  cat "$work/rec.out"
  [[ $rc -eq 0 ]] || { echo "SSR CANNOT record (exit $rc)"; exit 3; }
  video="$(sed -n 's/^VIDEO //p' "$work/rec.out" | tail -1)"
  [[ -f "$video" ]] || { echo "SSR no recording"; exit 3; }
  cp "$video" "$rec" || exit 3
  kill "$motion_pid" 2>/dev/null; wait "$motion_pid" 2>/dev/null; motion_pid=""
  recording="display-recording-scrolling-text-${seconds}s.mp4"
fi
echo "SSR recording $recording $(stat -f %z "$rec") bytes sha256 $(shasum -a 256 "$rec" | cut -c1-16)"

"$side" make "$name" --from "$app" --label "cmux ssr" >"$out/side.log" 2>&1 || { echo "SSR side instance make failed"; exit 3; }
"$side" launch "$name" --shown -- --skip-onboarding >>"$out/side.log" 2>&1 || { echo "SSR side instance launch failed"; exit 3; }
sock="$("$side" socket "$name")"
for _ in $(seq 1 90); do [[ -S "$sock" ]] && break; sleep 1; done
[[ -S "$sock" ]] || { echo "SSR the app has no socket"; exit 3; }
copy="$("$side" path "$name")"
cli="$copy/Contents/Resources/bin/cmux"
run_cli() { CMUX_SOCKET_PATH="$sock" CMUX_NEXT_SOCKET_PATH="$sock" "$cli" --app-socket "$sock" "$@"; }
sleep 5  # the window settles before a tab opens
tab="$(run_cli tab new-mac-screen --json 2>"$out/tab.err" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tab"])')" \
  || { echo "SSR tab new-mac-screen failed: $(head -c 300 "$out/tab.err")"; exit 3; }
echo "SSR tab $tab"
run_cli app mac-screen-replay --tab "$tab" --path "$rec" --frames "$frames" --timeout 120 --json >"$out/replay.json" 2>"$out/replay.err"
status=$?
echo "SSR replay exit=$status $(head -c 300 "$out/replay.err")"
python3 - "$out/replay.json" "$host" "$commit" "$recording" "$dmg" <<'PY' || status=3
import json, sys
path, host, commit, recording, dmg = sys.argv[1:6]
report = json.load(open(path))
summary = {"host": host, "commit": commit, "recording": recording, "dmg": dmg, "report": report}
print("SSR RESULT " + json.dumps(summary, separators=(",", ":")))
dp = (report.get("decode_present_ms") or {})
print(f"SSR decode_present p50={dp.get('p50')} p95={dp.get('p95')} n={dp.get('count')} presented={report.get('frames_presented')}")
PY
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
echo "SSR exit=$status"
exit "$status"
