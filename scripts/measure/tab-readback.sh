#!/usr/bin/env bash
# Two merged fixes read back on a published cmux NEXT NIGHTLY, on a fleet Mac with a console session, while CuaDriver
# records the display (launch_reveal_record.py: fleet steps hold no `screencapture -v` grant):
#   tabs  #52099 (ask-3fda3b3a7e). Leo, 2026-11-23: "opening a new tab in a pane with many tabs the end bit the text
#         has a weird rewritten thing and it's weird. and the animations are weird." New tabs open one by one in one
#         pane until it holds ~24, then a rapid burst, with window shots of the crowded strip along the way.
#   pin   #52050 (ask c-b5d3e0efb6, task #134 "Mango"): a workspace an older daemon pinned inside its group
#         (`extra.pinned`, first among Leads' members) is unpinned through its hover Unpin; it must stay in Leads
#         (in place, no jump) and show no Unpin afterwards.
# The NIGHTLY DMG is copied into a side instance (its own bundle id, data, daemon and config folder; the Mac's own
# apps are untouched) and launched in front; scripts/measure/tab-readback.py drives it.
#   cmux-ci run --class exclusive --display --target-worker HOST --pin-strict \
#     --script scripts/measure/tab-readback.sh --ref <sha> \
#     [--arg=build=VERSION | --arg=dmg=URL] \
#     --artifact .build/tab-readback/report.tgz --timeout 1800
#   build=VERSION  a NIGHTLY's build number (CFBundleVersion, e.g. 4594117542401): its DMG on files-next.cmux.com
#   dmg=URL        any NIGHTLY DMG (default: the newest in the NEXT feed)
# Prints TAB_READBACK {json}; report.tgz keeps result.json, the PNGs and the video. The copy is removed at the end.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/tab-readback"
rm -rf "$out" && mkdir -p "$out"
dmg="" build=""
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    build=*) build="${arg#build=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
if [[ -n "$build" ]]; then
  build="${build##*-nightly.}"  # 1.0.0-nightly.N names the same build as N
  [[ "$build" =~ ^[0-9]+$ ]] || { echo "build=VERSION takes a NIGHTLY build number" >&2; exit 2; }
  dmg="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-$build.dmg"
fi
if [[ -z "$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
echo "TRB host $(hostname -s) macOS $(sw_vers -productVersion) dmg $dmg"
rec_ready="$(python3 scripts/measure/launch_reveal_record.py preflight 2>&1)" \
  || { echo "TRB FAIL rig: cannot record: $rec_ready"; exit 3; }
echo "TRB recorder: $rec_ready"

work="$(mktemp -d "${TMPDIR:-/tmp}/tab-readback.XXXXXX")"
mkdir -p "$work/side"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
side="$root/scripts/cmux-next/side-instance.sh"
name="tabrb"
rec_pid=""
cleanup() {
  [[ -n "$rec_pid" ]] && kill -TERM "$rec_pid" 2>/dev/null && wait "$rec_pid" 2>/dev/null
  "$side" remove "$name" >/dev/null 2>&1 || true
  [[ -n "${mnt:-}" ]] && hdiutil detach "$mnt" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "TRB download failed"; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt" "$work/app"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$work/app/cmux NIGHTLY.app"
hdiutil detach "$mnt" >/dev/null; mnt=""
"$side" make "$name" --from "$work/app/cmux NIGHTLY.app" --label "cmux tab readback" >&2 || exit 3
app="$("$side" path "$name")"
# --skip-onboarding: a fresh profile's first run opens Make cmux Yours over the main window.
"$side" launch "$name" --front -- --skip-onboarding >&2 || exit 3
mkdir -p "$out/video"
python3 scripts/measure/launch_reveal_record.py record "$out/video" 1500 >"$out/rec.log" 2>&1 &
rec_pid=$!
for _ in $(seq 1 700); do
  grep -q '^READY' "$out/rec.log" 2>/dev/null && break
  kill -0 "$rec_pid" 2>/dev/null || break
  sleep 0.1
done
grep -q '^READY' "$out/rec.log" || { echo "TRB FAIL rig: recorder did not start: $(head -c 300 "$out/rec.log")"; exit 3; }
echo "TRB recording $(sed -n 's/^READY //p' "$out/rec.log")"
python3 scripts/measure/tab-readback.py --app "$app" --pid-file "$CMUX_SIDE_ROOT/$name/pid" \
  --control-socket "$("$side" socket "$name")" --dmg "$dmg" --out "$out" 2>&1 | tee "$out/run.log"
status=${PIPESTATUS[0]}
kill -TERM "$rec_pid" 2>/dev/null; wait "$rec_pid" 2>/dev/null; rec_pid=""
video="$(sed -n 's/^VIDEO //p' "$out/rec.log" | tail -1)"
if [[ -n "$video" && -s "$video" ]]; then
  [[ "$video" == "$out"/* ]] || cp "$video" "$out/video/" 2>/dev/null
  echo "TRB video $(basename "$video") $(($(stat -f %z "$video") / 1024)) KiB"
else
  echo "TRB no video: $(tail -c 300 "$out/rec.log")"
fi
"$side" stop "$name" >&2 || true
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
echo "TRB exit=$status"
exit "$status"
