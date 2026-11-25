#!/usr/bin/env bash
# CLI read-back of a published cmux NEXT NIGHTLY on a fleet Mac, with no launch: the DMG is mounted read-only, the
# app is copied into a temp folder (the Mac's own apps are untouched), and the bundle's version, commit and its
# bundled CLIs' `--version` are printed. mark=WORD also says whether the bundled acpmux holds WORD between two
# \x01 bytes, the gateway's launch-shape masks (#55700's `\u{1}session\u{1}`), to show the build carries it.
#   cmux-ci run --label measure --script scripts/measure/nightly-cli-readback.sh --ref <sha> \
#     [--arg=build=VERSION | --arg=dmg=URL] [--arg=mark=WORD]
#   build=VERSION  a NIGHTLY's build number (CFBundleVersion, e.g. 4557519416001)
#   dmg=URL        any NIGHTLY DMG (default: the newest in the NEXT feed)
# Prints NCR lines; the temp folder is removed at the end.
set -uo pipefail
dmg="" build="" mark=""
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    build=*) build="${arg#build=}" ;;
    mark=*) mark="${arg#mark=}" ;;
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
echo "NCR host $(hostname -s) macOS $(sw_vers -productVersion) dmg $dmg"

work="$(mktemp -d "${TMPDIR:-/tmp}/nightly-cli-readback.XXXXXX")"
mnt=""
cleanup() { [[ -n "$mnt" ]] && hdiutil detach "$mnt" >/dev/null 2>&1; rm -rf "$work"; }
trap cleanup EXIT
curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "NCR download failed"; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
src="$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)"
ditto "$src" "$work/app.app"
hdiutil detach "$mnt" >/dev/null; mnt=""
app="$work/app.app"
plist="$app/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion CFBundleIdentifier; do
  echo "NCR $key $(plutil -extract "$key" raw -o - "$plist" 2>&1)"
done
plutil -p "$plist" | grep -iE 'commit|sha|revision' | sed 's/^ */NCR plist /'
status=0
for name in cmux acpmux; do
  bin="$(find "$app/Contents" -type f -perm -u+x -name "$name" 2>/dev/null | head -1)"
  if [[ -z "$bin" ]]; then echo "NCR $name: not in the bundle"; continue; fi
  echo "NCR $name path ${bin#"$app/"}"
  echo "NCR $name --version: $(HOME="$work" "$bin" --version 2>&1 | head -3 | tr '\n' ' ')"
  if [[ "$name" == acpmux && -n "$mark" ]]; then
    if LC_ALL=C grep -qaF $'\x01'"$mark"$'\x01' "$bin"; then echo "NCR acpmux mark present: $mark"
    else echo "NCR acpmux mark absent: $mark"; status=1; fi
  fi
done
echo "NCR exit=$status"
exit "$status"
