#!/usr/bin/env bash
# What a video-call page needs, in cmux NEXT's in-app browser (Chromium, then WebKit) against Google Chrome on
# the same fleet Mac with a console session (measurement only). Leo 2026-11-22: "when we open up google meet
# inside our browser, it works well". The NIGHTLY DMG from the feed is copied into a side instance (its own
# bundle id, data and daemon; the Mac's own apps are untouched) and launched; scripts/measure/meet-browser.py
# serves a local test page (127.0.0.1 is a secure context) and drives each browser through it:
# getUserMedia, getDisplayMedia, Picture-in-Picture, notifications, a 60 s loopback WebRTC call (CPU and
# getStats), signed-out Meet navigation (including its final destination), and timer drift in a hidden tab.
#   cmux-ci run --class exclusive --label measure --display \
#     --script scripts/measure/meet-browser.sh --ref <sha> [--arg=dmg=URL] [--arg=call=60] \
#     --artifact .build/meet-browser/report.tgz --timeout 2700
#   dmg=URL   the NEXT DMG (default: newest NIGHTLY). The fake cmux row needs the measurement switch in the app.
#   build=JOB  a cmux-ci app build to measure before its switches reach the NIGHTLY feed
#   call=S    seconds of the loopback call (default 60)
#   only=a,b  some runs only (cmux-chromium,cmux-chromium-fake,cmux-webkit,chrome-fake,chrome-plain)
# Prints MEET_BROWSER {json} and the table. report.tgz also includes Chrome startup logs.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/meet-browser"
rm -rf "$out" && mkdir -p "$out"
dmg="" build_job="" call=60 only=""
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    build=*) build_job="${arg#build=}" ;;
    call=*) call="${arg#call=}" ;;
    only=*) only="${arg#only=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$call" =~ ^[0-9]+$ ]] || { echo "call=S takes seconds" >&2; exit 2; }
[[ -z "$only" || "$only" =~ ^[a-z,-]+$ ]] || { echo "only=a,b takes run names" >&2; exit 2; }
[[ -z "$build_job" || ( -z "$dmg" && "$build_job" =~ ^[0-9a-f]{24}$ ) ]] || { echo "use one app source: build=JOB or dmg=URL" >&2; exit 2; }
if [[ -z "$build_job$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ -n "$build_job" || "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
echo "MEET host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername) dmg $dmg"

work="$(mktemp -d "${TMPDIR:-/tmp}/meet-browser.XXXXXX")"
mkdir -p "$work/side"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
side="$root/scripts/cmux-next/side-instance.sh"
name="meetbrowser"
mnt=""
# shellcheck disable=SC2317  # run by the EXIT trap
cleanup() {
  "$side" remove "$name" >/dev/null 2>&1 || true
  [[ -n "$mnt" ]] && hdiutil detach "$mnt" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$work/app"
if [[ -n "$build_job" ]]; then
  ci="$(command -v cmux-ci || true)"
  ci="${ci:-$HOME/.local/bin/cmux-ci}"
  "$ci" artifact "$build_job" "$work/app.zip" || exit 3
  ditto -x -k "$work/app.zip" "$work/app" || exit 3
  app="$(find "$work/app" -maxdepth 3 -name '*.app' -prune -print | head -1)"
else
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "MEET download failed"; exit 3; }
  mnt="$work/mnt"; mkdir -p "$mnt"
  hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
  app="$work/app/cmux NIGHTLY.app"
  ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$app" || exit 3
  hdiutil detach "$mnt" >/dev/null || exit 3
  mnt=""
fi
[[ -f "$app/Contents/Info.plist" ]] || { echo "MEET no app in the supplied artifact" >&2; exit 3; }
"$side" make "$name" --from "$app" --label "cmux meet" >&2 || exit 3
plist="$app/Contents/Info.plist"
version="" build=""
[[ -f "$plist" ]] && version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
[[ -f "$plist" ]] && build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
python3 scripts/measure/meet-browser.py --side "$side" --name "$name" --work "$work" --out "$out" \
  --dmg "$dmg" --build-job "$build_job" --version "$version ($build)" --call "$call" ${only:+--only "$only"} 2>&1 | tee "$out/run.log"
status=${PIPESTATUS[0]}
"$side" stop "$name" >&2 || true
[[ -f "$out/table.md" ]] && cat "$out/table.md"
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . || exit 3
echo "MEET exit=$status"
exit "$status"
