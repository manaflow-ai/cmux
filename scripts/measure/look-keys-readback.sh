#!/usr/bin/env bash
# Look keys read back on a published cmux NEXT NIGHTLY, on a fleet Mac with a console session (read-back only): the
# NIGHTLY DMG is copied into a side instance (its own bundle id, data, daemon and config folder; the Mac's own apps
# are untouched) and launched in front, then scripts/measure/look-keys-readback.py applies each case of a cases file
# (a theme file's look keys, the chat stylesheet's tokens) to the running copy and reads each one back: every
# theme key through the copy's control socket (`settings.get`, the effective settings with the theme file applied),
# and a window and a desktop shot before and after, with an optional color probe that must appear only after.
#   cmux-ci run --class exclusive --display --target-worker HOST --pin-strict \
#     --script scripts/measure/look-keys-readback.sh --ref <sha> \
#     [--arg=build=VERSION | --arg=dmg=URL] [--arg=cases=PATH] [--arg=only=NAME,NAME] \
#     --artifact .build/look-keys-readback/report.tgz --timeout 1800
#   build=VERSION  a NIGHTLY's build number (CFBundleVersion, e.g. 4528921531001): its DMG on files-next.cmux.com
#   dmg=URL        any NIGHTLY DMG (default: the newest in the NEXT feed)
#   cases=PATH     repo-relative cases file (default scripts/measure/look-keys-readback/cases.json; the format is
#                  in look-keys-readback.py)
#   only=NAMES     run only these cases, in the file's order
# Prints the receipt (LOOK_KEYS_READBACK {json}) and keeps result.json, the PNGs and the copy's log in report.tgz.
# The copy is removed at the end.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/look-keys-readback"
rm -rf "$out" && mkdir -p "$out"
dmg="" build="" cases="scripts/measure/look-keys-readback/cases.json" only=""
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    build=*) build="${arg#build=}" ;;
    cases=*) cases="${arg#cases=}" ;;
    only=*) only="${arg#only=}" ;;
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
[[ -f "$cases" ]] || { echo "no cases file at $cases" >&2; exit 2; }
echo "LKR host $(hostname -s) macOS $(sw_vers -productVersion) dmg $dmg cases $cases"

work="$(mktemp -d "${TMPDIR:-/tmp}/look-keys-readback.XXXXXX")"
mkdir -p "$work/side"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
side="$root/scripts/cmux-next/side-instance.sh"
name="lookkeys"
cleanup() {
  "$side" remove "$name" >/dev/null 2>&1 || true
  [[ -n "${mnt:-}" ]] && hdiutil detach "$mnt" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "LKR download failed"; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt" "$work/app"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$work/app/cmux NIGHTLY.app"
hdiutil detach "$mnt" >/dev/null; mnt=""
"$side" make "$name" --from "$work/app/cmux NIGHTLY.app" --label "cmux look keys" >&2 || exit 3
config="$CMUX_SIDE_ROOT/$name/config"
# The copy starts on an empty theme file of the run's own; each case rewrites only that file (the app watches it).
python3 scripts/measure/look-keys-readback.py prepare --config "$config" || exit 3
app="$("$side" path "$name")"
# --skip-onboarding: a fresh profile opens Make cmux Yours over the main window. Step 640558b0 (cmux12s) shot the
# menu-tokens case under that sheet: the model menu never drew, 0 #ff00ff pixels. Same flag as customizer-toggle-readback.sh.
"$side" launch "$name" --front -- --skip-onboarding >&2 || exit 3
python3 scripts/measure/look-keys-readback.py run --app "$app" --pid-file "$CMUX_SIDE_ROOT/$name/pid" \
  --control-socket "$("$side" socket "$name")" --config "$config" --cases "$cases" --only "$only" \
  --dmg "$dmg" --out "$out" 2>&1 | tee "$out/run.log"
status=${PIPESTATUS[0]}
"$side" stop "$name" >&2 || true
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
echo "LKR exit=$status"
exit "$status"
