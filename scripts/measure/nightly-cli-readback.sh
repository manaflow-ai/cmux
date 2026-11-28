#!/usr/bin/env bash
# CLI read-back of a published cmux NEXT NIGHTLY on a fleet Mac, with no launch: the DMG is mounted read-only, the
# app is copied into a temp folder (the Mac's own apps are untouched), and the bundle's version, commit and its
# bundled CLIs' `--version` are printed. mark=WORD also says whether the bundled acpmux holds WORD between two
# \x01 bytes, the gateway's launch-shape masks (#55700's `\u{1}session\u{1}`), to show the build carries it.
# chief-mark=TEXT (repeatable) says whether the bundled optchat-chief holds TEXT, a string a Chief change added,
# to show the NIGHTLY carries that Chief change (its `--version` also names the commit it was built from).
#   cmux-ci run --class light --script scripts/measure/nightly-cli-readback.sh --ref <sha> \
#     [--arg=build=VERSION | --arg=dmg=URL] [--arg=mark=WORD] [--arg=chief-mark=TEXT ...] [--arg=help=VERB...]
#   build=VERSION  a NIGHTLY's build number (CFBundleVersion, e.g. 4557519416001)
#   dmg=URL        any NIGHTLY DMG (default: the newest in the NEXT feed)
#   help=VERB      also run the bundled `cmux VERB --help` (VERB may be several words joined by +, e.g. link+dial),
#                  print its exit code and first line; repeatable. A nonzero exit fails the read-back.
# Prints NCR lines; the temp folder is removed at the end.
set -uo pipefail
dmg="" build="" mark=""
chief_marks=()
helps=()
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    build=*) build="${arg#build=}" ;;
    mark=*) mark="${arg#mark=}" ;;
    chief-mark=?*) chief_marks+=("${arg#chief-mark=}") ;;
    help=?*) helps+=("${arg#help=}") ;;
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
# The app's own executable (Contents/MacOS/cmux) shares the CLI's name; run with --version it starts the GUI and
# never exits on a headless Mac, so it is skipped, and each CLI call is bounded at 30 s.
main_exe="$app/Contents/MacOS/$(plutil -extract CFBundleExecutable raw -o - "$plist" 2>/dev/null)"
bounded() { perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' 30 "$@"; }
status=0
for name in cmux acpmux optchat-chief; do
  # A bundled CLI may be a symlink (bin/acpmux -> cmux), so links count too; one whose target is the app's own
  # executable is skipped like that executable.
  bin=""
  while IFS= read -r cand; do
    # -x and -ef follow the link: the target must run and must not be the app's own executable.
    [[ -x "$cand" && ! "$cand" -ef "$main_exe" ]] || continue
    bin="$cand"; break
  done < <(find "$app/Contents" \( -type f -o -type l \) -name "$name" 2>/dev/null)
  if [[ -z "$bin" ]]; then echo "NCR $name: not in the bundle"; continue; fi
  if [[ -L "$bin" ]]; then echo "NCR $name path ${bin#"$app/"} -> $(readlink "$bin")"
  else echo "NCR $name path ${bin#"$app/"}"; fi
  ver="$(HOME="$work" bounded "$bin" --version 2>&1)"; rc=$?
  ver="$(head -3 <<<"$ver" | tr '\n' ' ')"
  if [[ "$rc" -eq 142 ]]; then echo "NCR $name --version: no answer in 30 s"; status=1
  else echo "NCR $name --version: $ver"; fi
  if [[ "$name" == cmux ]]; then
    for verb in ${helps[@]+"${helps[@]}"}; do
      IFS=+ read -r -a words <<<"$verb"
      out="$(HOME="$work" bounded "$bin" "${words[@]}" --help 2>&1)"; rc=$?
      echo "NCR cmux ${words[*]} --help exit=$rc: $(printf '%s\n' "$out" | grep -m1 -v '^[[:space:]]*$')"
      [[ $rc -eq 0 ]] || status=1
    done
  fi
  if [[ "$name" == acpmux && -n "$mark" ]]; then
    if LC_ALL=C grep -qaF $'\x01'"$mark"$'\x01' "$bin"; then echo "NCR acpmux mark present: $mark"
    else echo "NCR acpmux mark absent: $mark"; status=1; fi
  fi
  if [[ "$name" == optchat-chief ]]; then
    for cm in ${chief_marks[@]+"${chief_marks[@]}"}; do
      if LC_ALL=C grep -qaF -- "$cm" "$bin"; then echo "NCR optchat-chief mark present: $cm"
      else echo "NCR optchat-chief mark absent: $cm"; status=1; fi
    done
  fi
done
echo "NCR exit=$status"
exit "$status"
