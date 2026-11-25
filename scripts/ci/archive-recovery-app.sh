#!/usr/bin/env bash
# Archive a signed app for a notarization recovery artifact:
#   archive-recovery-app.sh <app> <archive.tar.gz>
# The archive holds only the app folder. COPYFILE_DISABLE=1 stops macOS bsdtar
# from adding an AppleDouble member ("._<name>") for each file with extended
# attributes, which resolve-notarization-recovery.py --extract-app refuses.
# GNU tar ignores the variable.
set -euo pipefail
[ "$#" -eq 2 ] || { echo "usage: archive-recovery-app.sh <app> <archive.tar.gz>" >&2; exit 2; }
app="$1"
archive="$2"
[ -d "$app/Contents" ] || { echo "archive-recovery-app.sh: not an app bundle: $app" >&2; exit 1; }
rm -f "$archive"
COPYFILE_DISABLE=1 tar -C "$(dirname "$app")" -czf "$archive" "$(basename "$app")"
