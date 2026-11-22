#!/usr/bin/env bash
# What a video-call page needs, in cmux NEXT's in-app browser (Chromium, then WebKit) against Google Chrome on
# the same fleet Mac with a console session (measurement only). Leo 2026-11-22: "when we open up google meet
# inside our browser, it works well". The NIGHTLY DMG from the feed is copied into a side instance (its own
# bundle id, data and daemon; the Mac's own apps are untouched) and launched; scripts/measure/meet-browser.py
# serves a local test page (127.0.0.1 is a secure context) and drives each browser through it:
# getUserMedia, getDisplayMedia, Picture-in-Picture, notifications, a 60 s loopback WebRTC call (CPU and
# getStats), meet.google.com load cold and warm, and timer drift in a hidden tab.
#   cmux-ci run --class exclusive --label measure --display \
#     --script scripts/measure/meet-browser.sh --ref <sha> [--arg=dmg=URL] [--arg=call=60] \
#     --artifact .build/meet-browser/report.tgz --timeout 2700
#   dmg=URL   the nightly DMG (default: the newest in the NEXT feed)
#   call=S    seconds of the loopback call (default 60)
#   only=a,b  some runs only (cmux-chromium,cmux-chromium-fake,cmux-webkit,chrome-fake,chrome-plain)
# Prints MEET_BROWSER {json} and the table; keeps results.json, table.md and the log in report.tgz.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/meet-browser"
rm -rf "$out" && mkdir -p "$out"
dmg="" call=60 only=""
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    call=*) call="${arg#call=}" ;;
    only=*) only="${arg#only=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$call" =~ ^[0-9]+$ ]] || { echo "call=S takes seconds" >&2; exit 2; }
[[ -z "$only" || "$only" =~ ^[a-z,-]+$ ]] || { echo "only=a,b takes run names" >&2; exit 2; }
if [[ -z "$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
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

curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "MEET download failed"; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt" "$work/app"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$work/app/cmux NIGHTLY.app"
hdiutil detach "$mnt" >/dev/null; mnt=""
rm -f "$work/nightly.dmg"
"$side" make "$name" --from "$work/app/cmux NIGHTLY.app" --label "cmux meet" >&2 || exit 3
plist="$work/app/cmux NIGHTLY.app/Contents/Info.plist"
version="" build=""
[[ -f "$plist" ]] && version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
[[ -f "$plist" ]] && build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
python3 scripts/measure/meet-browser.py --side "$side" --name "$name" --work "$work" --out "$out" \
  --dmg "$dmg" --version "$version ($build)" --call "$call" ${only:+--only "$only"} 2>&1 | tee "$out/run.log"
status=${PIPESTATUS[0]}
"$side" stop "$name" >&2 || true
[[ -f "$out/table.md" ]] && cat "$out/table.md"
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
echo "MEET exit=$status"
exit "$status"
