#!/usr/bin/env bash
# Thin every fat Mach-O file inside an app bundle down to one architecture, in place.
#
#   scripts/thin-app-bundle.sh <path-to.app> <arm64|x86_64>
#
# Walks the bundle (nested apps, frameworks, plug-ins, dylibs, Resources/bin
# helpers), leaves non-Mach-O files and symlinks untouched, thins fat files that
# contain the requested slice, and fails if any fat file lacks it. Single-arch
# files already matching the request are left as-is; single-arch files of another
# architecture fail, since that bundle could never launch on the target machine.
# Contents/Resources/bin/cmux-tui-ssh/ is skipped: it holds cmux-tui builds for
# SSH hosts of every platform, which the app uploads rather than runs.
# Run before code signing: thinning invalidates existing signatures.
set -euo pipefail

usage() { sed -n '2,13p' "$0"; }

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then usage; exit 0; fi
if [ "$#" -ne 2 ]; then usage >&2; exit 2; fi

APP_PATH="$1"
ARCH="$2"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "error: unsupported architecture '$ARCH' (expected arm64 or x86_64)" >&2; exit 2 ;;
esac
if [ ! -d "$APP_PATH/Contents" ]; then
  echo "error: app bundle not found: $APP_PATH" >&2
  exit 1
fi

LIPO_TOOL="${CMUX_LIPO_TOOL:-lipo}"
FILE_TOOL="${CMUX_FILE_TOOL:-file}"

# Only files that start with a Mach-O or fat magic reach the real `file`
# (list-macho-candidates.py); it calls nothing else Mach-O, so the loop sees
# the same files with one process per Mach-O instead of one per file. A
# substitute CMUX_FILE_TOOL (tests) sees every file, as before.
list_files() {
  if [ -n "${CMUX_FILE_TOOL:-}" ]; then
    find "$APP_PATH" -path "$APP_PATH/Contents/Resources/bin/cmux-tui-ssh" -prune -o -type f -print0
  else
    find "$APP_PATH" -path "$APP_PATH/Contents/Resources/bin/cmux-tui-ssh" -prune -o -type f -print0 \
      | python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/list-macho-candidates.py"
  fi
}

# A missing python3 would make the filtered list silently empty.
if [ -z "${CMUX_FILE_TOOL:-}" ] && ! command -v python3 >/dev/null; then
  echo "error: python3 is required to list the bundle's Mach-O files" >&2
  exit 1
fi

thinned=0
kept=0
while IFS= read -r -d '' path; do
  # `file -b` on a fat binary prints "Mach-O universal binary with N architectures".
  kind="$("$FILE_TOOL" -b "$path" 2>/dev/null || true)"
  case "$kind" in
    *"Mach-O universal binary"*) ;;
    *"Mach-O"*)
      archs="$("$LIPO_TOOL" -archs "$path" 2>/dev/null || true)"
      if [ "$archs" != "$ARCH" ]; then
        echo "error: $path is a single-architecture Mach-O for '$archs', not '$ARCH'" >&2
        exit 1
      fi
      kept=$((kept + 1))
      continue
      ;;
    *) continue ;;
  esac
  if ! "$LIPO_TOOL" "$path" -verify_arch "$ARCH"; then
    echo "error: fat binary lacks the $ARCH slice: $path" >&2
    exit 1
  fi
  tmp="$path.thin.$$"
  "$LIPO_TOOL" "$path" -thin "$ARCH" -output "$tmp"
  # Preserve mode bits so helpers in Resources/bin stay executable.
  chmod --reference="$path" "$tmp" 2>/dev/null || chmod "$(stat -f '%Lp' "$path")" "$tmp"
  mv -f "$tmp" "$path"
  thinned=$((thinned + 1))
done < <(list_files)

echo "thinned $thinned fat Mach-O files to $ARCH in $APP_PATH ($kept already $ARCH-only)"
