#!/usr/bin/env bash
# The See-Through Dock switch (experiments.seeThroughDock, #53569) read back on a published cmux NEXT NIGHTLY, from
# a cold start on a clean profile, on a fleet Mac with a console session. The NIGHTLY DMG is copied into a side
# instance (its own bundle id, data, daemon and config folder; the Mac's own apps are untouched) and launched in
# front; scripts/measure/customizer-toggle-readback.py then walks the shortest path a person takes to the switch
# (open Settings, its Advanced section, the switch; and the search path), counts the clicks, flips the switch and
# reads experiments.seeThroughDock back through the copy's control socket, with a window and a desktop shot per step.
#   cmux-ci run --class exclusive --display --target-worker HOST --pin-strict \
#     --script scripts/measure/customizer-toggle-readback.sh --ref <sha> \
#     [--arg=build=VERSION | --arg=dmg=URL] \
#     --artifact .build/customizer-toggle-readback/report.tgz --timeout 1800
#   build=VERSION  a NIGHTLY's build number (CFBundleVersion, e.g. 4556757533801): its DMG on files-next.cmux.com
#   dmg=URL        any NIGHTLY DMG (default: the newest in the NEXT feed)
# Leo, 2026-11-24 (ask-82b08b7ed7): "having people be able to easily toggle my customieer or whatever would be god".
# Prints the receipt (CUSTOMIZER_TOGGLE_READBACK {json}) and keeps result.json and the PNGs in report.tgz. The copy is
# removed at the end.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/customizer-toggle-readback"
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
  [[ "$build" =~ ^[0-9]+$ ]] || { echo "build=VERSION takes a NIGHTLY build number" >&2; exit 2; }
  dmg="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-$build.dmg"
fi
if [[ -z "$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
echo "CTR host $(hostname -s) macOS $(sw_vers -productVersion) dmg $dmg"

work="$(mktemp -d "${TMPDIR:-/tmp}/customizer-toggle-readback.XXXXXX")"
mkdir -p "$work/side"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
side="$root/scripts/cmux-next/side-instance.sh"
name="ctoggle"
cleanup() {
  "$side" remove "$name" >/dev/null 2>&1 || true
  [[ -n "${mnt:-}" ]] && hdiutil detach "$mnt" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "CTR download failed"; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt" "$work/app"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$work/app/cmux NIGHTLY.app"
hdiutil detach "$mnt" >/dev/null; mnt=""
"$side" make "$name" --from "$work/app/cmux NIGHTLY.app" --label "cmux customizer toggle" >&2 || exit 3
app="$("$side" path "$name")"
# --skip-onboarding: a fresh profile's first run opens Make cmux Yours over the main window, and its sheet hides
# Settings from the walk (run 12608e55, cmux21: no Advanced link). The path measured is a person's who already set up
# cmux, not a first run's.
"$side" launch "$name" --front -- --skip-onboarding >&2 || exit 3
python3 scripts/measure/customizer-toggle-readback.py --app "$app" --pid-file "$CMUX_SIDE_ROOT/$name/pid" \
  --control-socket "$("$side" socket "$name")" --dmg "$dmg" --out "$out" 2>&1 | tee "$out/run.log"
status=${PIPESTATUS[0]}
"$side" stop "$name" >&2 || true
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
echo "CTR exit=$status"
exit "$status"
