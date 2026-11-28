#!/usr/bin/env bash
# One picture of a published cmux NEXT NIGHTLY that shows three merged fixes at once (ask-3729c9c563), on a fleet
# Mac with a console session (measurement only). Leo, 2026-11-27: "ok why dont your tabs have any names/letters
# showing up? that intentional? also the memory line... it should be the ram usage. why dont we have ram usage? and
# there's a (supposed to be) fix for the black bg of the preview in flight"
#   tab letters  #62345 and #62233: agent chat tabs in a crowded strip keep their first letters
#   Memory line  #62151: an agent chat's hover card shows its agent's RAM, not "-"
#   preview      #62233: the hover card's chat picture keeps clear pixels clear (no black ground)
# The NIGHTLY DMG is copied into a side instance (its own bundle id, data, daemon and config folder; the Mac's own
# apps are untouched) and launched in front. scripts/measure/tab-ram-preview-shot.py opens a crowd of agent chats on
# a stand-in ACP agent (cmux-tui/crates/acpmux/tests/fake_agent.py), rests the pointer on one tab, and captures the
# copy's windows and the display through the copy's own cmux Computer Use (no other capture path: a refusal is the
# answer).
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/tab-ram-preview-shot.sh --ref <sha> [--arg=build=VERSION | --arg=dmg=URL] \
#     --artifact .build/tab-ram-preview-shot/report.tgz --timeout 1500
#   build=VERSION  a NIGHTLY's build number (CFBundleVersion, e.g. 4612541169301): its DMG on files-next.cmux.com
#   dmg=URL        any NIGHTLY DMG (default: the newest in the NEXT feed)
# Prints TAB_RAM_PREVIEW {json}; report.tgz keeps result.json and the PNGs. The copy and the stand-in harness file
# are removed at the end.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/tab-ram-preview-shot"
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
  build="${build##*-nightly.}"
  [[ "$build" =~ ^[0-9]+$ ]] || { echo "build=VERSION takes a NIGHTLY build number" >&2; exit 2; }
  dmg="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-$build.dmg"
fi
if [[ -z "$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
echo "TRP host macOS $(sw_vers -productVersion) dmg $dmg"

work="$(mktemp -d "${TMPDIR:-/tmp}/tab-ram-preview.XXXXXX")"
mkdir -p "$work/side" "$work/chats"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
side="$root/scripts/cmux-next/side-instance.sh"
name="tabramshot"
# The stand-in harness: the copy's acpmux reads harnesses from the account's config folder. A unique id, one file
# this run writes and removes; an existing file of that name stops the run rather than being replaced.
harness="tabramshot$$"
harness_files=()
for dir in cmux-next cmux; do
  file="$HOME/.config/$dir/harnesses/$harness.toml"
  [[ -e "$file" ]] && { echo "TRP FAIL rig: $file exists" >&2; exit 3; }
  harness_files+=("$file")
done
cleanup() {
  "$side" remove "$name" >/dev/null 2>&1 || true
  [[ -n "${mnt:-}" ]] && hdiutil detach "$mnt" >/dev/null 2>&1
  for file in "${harness_files[@]}"; do
    [[ -f "$file" ]] && grep -q "^id = \"$harness\"" "$file" && rm -f "$file"
  done
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fake="$root/cmux-tui/crates/acpmux/tests/fake_agent.py"
[[ -f "$fake" ]] || { echo "TRP FAIL rig: no $fake" >&2; exit 3; }
for file in "${harness_files[@]}"; do
  mkdir -p "$(dirname "$file")"
  printf 'schema = 1\nid = "%s"\nname = "Stand-in agent"\nprotocol = "acp"\ncommand = "/usr/bin/python3"\nargs = ["%s"]\n' \
    "$harness" "$fake" >"$file"
done

curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "TRP download failed"; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt" "$work/app"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$work/app/cmux NIGHTLY.app"
hdiutil detach "$mnt" >/dev/null; mnt=""
"$side" make "$name" --from "$work/app/cmux NIGHTLY.app" --label "cmux tab RAM preview" >&2 || exit 3
app="$("$side" path "$name")"
"$side" launch "$name" --front -- --skip-onboarding >&2 || exit 3
python3 scripts/measure/tab-ram-preview-shot.py --app "$app" --pid-file "$CMUX_SIDE_ROOT/$name/pid" \
  --control-socket "$("$side" socket "$name")" --harness "$harness" --cwd "$work/chats" --dmg "$dmg" \
  --out "$out" 2>&1 | tee "$out/run.log"
status=${PIPESTATUS[0]}
"$side" stop "$name" >&2 || true
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
echo "TRP exit=$status"
exit "$status"
