#!/usr/bin/env bash
# Install the rolling cmux NEXT DEV build without quarantine.
#
# One-line use from a checkout:
#   bash scripts/cmux-next/update-dev-daily.sh
#
# The optional argument is the app path (default: ~/Applications/cmux NEXT DEV.app).
# The archive is downloaded with curl, verified against the adjacent SHA-256
# asset, and atomically swapped after asking the running app to quit through its
# normal app quit path. No process-name matching or forced termination is used.
set -euo pipefail

repo="${CMUX_NEXT_DEV_REPO:-manaflow-ai/cmux}"
tag="${CMUX_NEXT_DEV_TAG:-cmux-next-dev}"
archive_name="${CMUX_NEXT_DEV_ARCHIVE:-cmux-NEXT-DEV.zip}"
app_name="cmux NEXT DEV.app"
app_path="${1:-$HOME/Applications/$app_name}"
base_url="https://github.com/$repo/releases/download/$tag"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-next-dev-update.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

archive="$tmp/$archive_name"
checksum="$tmp/$archive_name.sha256"
curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
  "$base_url/$archive_name" -o "$archive"
curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
  "$base_url/$archive_name.sha256" -o "$checksum"
(cd "$tmp" && shasum -a 256 -c "$(basename "$checksum")")

unpacked="$tmp/unpacked"
mkdir -p "$unpacked"
/usr/bin/ditto -x -k "$archive" "$unpacked"
downloaded="$(find "$unpacked" -maxdepth 2 -type d -name "$app_name" -print -quit)"
[[ -d "$downloaded" ]] || { echo "cmux NEXT DEV app not found in $archive_name" >&2; exit 1; }
actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$downloaded/Contents/Info.plist")"
[[ "$actual_id" == com.cmuxterm.app.debug.next ]] || {
  echo "unexpected cmux NEXT DEV bundle id: $actual_id" >&2
  exit 1
}
/usr/bin/codesign --verify --deep --strict "$downloaded"

mkdir -p "$(dirname "$app_path")"
osascript -e 'tell application "cmux NEXT DEV" to quit' >/dev/null 2>&1 || true
running="true"
for _ in $(seq 1 30); do
  running="$(osascript -e 'tell application "System Events" to (exists process "cmux NEXT DEV")' 2>/dev/null || echo unknown)"
  [[ "$running" == "false" ]] && break
  sleep 1
done
[[ "$running" == "false" ]] || { echo "cmux NEXT DEV did not exit after quit" >&2; exit 1; }
staged="$(dirname "$app_path")/.cmux NEXT DEV.app.new.$$"
backup="$(dirname "$app_path")/.cmux NEXT DEV.app.old.$$"
rm -rf -- "$staged" "$backup"
/usr/bin/ditto "$downloaded" "$staged"
if [[ -e "$app_path" ]]; then
  mv "$app_path" "$backup"
fi
if ! mv "$staged" "$app_path"; then
  if [[ -e "$backup" ]]; then mv "$backup" "$app_path"; fi
  exit 1
fi
rm -rf -- "$backup"
echo "Installed cmux NEXT DEV from $tag at $app_path"
