#!/usr/bin/env bash
# Install or update the rolling cmux NEXT DEV build without quarantine.
#
# One-line use from a checkout:
#   bash scripts/cmux-next/update-dev-daily.sh [--force] [APP_PATH]
#
# APP_PATH defaults to ~/Applications/cmux NEXT DEV.app.
#
# Nothing new: when the release asset's `updated_at` (or, if GitHub's API does
# not answer, its SHA-256) is the one this script installed last, it says so
# and leaves the app alone. --force reinstalls anyway.
#
# An update: the archive is downloaded with curl, verified against the
# adjacent SHA-256 asset, and swapped in atomically. A running app is asked to
# Quit and Keep Sessions through its own CLI, so terminals, agents and chats
# keep running under their session daemons, and it is opened again afterwards;
# the new build reattaches to them. No process-name matching or forced
# termination is used. A first install quits nothing and opens the app.
set -euo pipefail

force=false
if [[ "${1:-}" == "--force" ]]; then
  force=true
  shift
fi

repo="${CMUX_NEXT_DEV_REPO:-manaflow-ai/cmux}"
tag="${CMUX_NEXT_DEV_TAG:-cmux-next-dev}"
archive_name="${CMUX_NEXT_DEV_ARCHIVE:-cmux-NEXT-DEV.zip}"
app_name="cmux NEXT DEV.app"
process_name="cmux NEXT DEV"
app_path="${1:-$HOME/Applications/$app_name}"
base_url="https://github.com/$repo/releases/download/$tag"
api_url="https://api.github.com/repos/$repo/releases/tags/$tag"
# What this script installed last at app_path: the asset's updated_at, then
# its SHA-256 line.
installed_record="$(dirname "$app_path")/.$app_name.installed"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-next-dev-update.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

fetch() {
  curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error "$@"
}

# The archive asset's updated_at; empty when the API does not answer (an
# unauthenticated client gets 60 requests an hour).
asset_updated_at() {
  local json="$tmp/release.json" count i
  fetch -H 'Accept: application/vnd.github+json' "$api_url" -o "$json" 2>/dev/null || return 0
  count="$(plutil -extract assets raw -o - "$json" 2>/dev/null)" || return 0
  for ((i = 0; i < count; i++)); do
    if [[ "$(plutil -extract "assets.$i.name" raw -o - "$json" 2>/dev/null)" == "$archive_name" ]]; then
      plutil -extract "assets.$i.updated_at" raw -o - "$json" 2>/dev/null || true
      return 0
    fi
  done
}

# true, false, or unknown (System Events did not answer).
app_running() {
  osascript -e "tell application \"System Events\" to (exists process \"$process_name\")" 2>/dev/null || echo unknown
}

record() {
  printf '%s\n%s\n' "$1" "$2" > "$installed_record"
}

installed_at=""
installed_sha=""
if [[ -d "$app_path" && -f "$installed_record" ]]; then
  { IFS= read -r installed_at; IFS= read -r installed_sha; } < "$installed_record" || true
fi

updated_at="$(asset_updated_at)"
if ! $force && [[ -n "$updated_at" && "$updated_at" == "$installed_at" ]]; then
  echo "cmux NEXT DEV is up to date: $archive_name (published $updated_at) is installed at $app_path."
  exit 0
fi

archive="$tmp/$archive_name"
checksum="$tmp/$archive_name.sha256"
fetch "$base_url/$archive_name.sha256" -o "$checksum"
sha_line="$(head -n 1 "$checksum")"
# The same archive uploaded again is nothing new either.
# The recorded updated_at stays: the archive may be uploaded ahead of its
# checksum, and recording its new updated_at would skip it once both are up.
if ! $force && [[ -n "$installed_sha" && "$sha_line" == "$installed_sha" ]]; then
  echo "cmux NEXT DEV is up to date: $archive_name is the build installed at $app_path."
  exit 0
fi
fetch "$base_url/$archive_name" -o "$archive"
(cd "$tmp" && shasum -a 256 -c "$(basename "$checksum")")

unpacked="$tmp/unpacked"
mkdir -p "$unpacked"
ditto -x -k "$archive" "$unpacked"
downloaded="$(find "$unpacked" -maxdepth 2 -type d -name "$app_name" -print -quit)"
[[ -d "$downloaded" ]] || { echo "cmux NEXT DEV app not found in $archive_name" >&2; exit 1; }
actual_id="$(plutil -extract CFBundleIdentifier raw -o - "$downloaded/Contents/Info.plist")"
[[ "$actual_id" == com.cmuxterm.app.debug.next ]] || {
  echo "unexpected cmux NEXT DEV bundle id: $actual_id" >&2
  exit 1
}
codesign --verify --deep --strict "$downloaded"

mkdir -p "$(dirname "$app_path")"
# A first install has no app to quit. Asking System Events would answer
# "unknown" over ssh, and that is not a running app.
first_install=true
[[ -e "$app_path" ]] && first_install=false
was_running=false
if ! $first_install && [[ "$(app_running)" != "false" ]]; then
  was_running=true
  # Quit and Keep Sessions: a plain Quit may ask whether to end them. In
  # another cmux's terminal these variables name that app; the bundled CLI
  # then finds its own.
  env -u CMUX_SOCKET_PATH -u CMUX_BUNDLE_ID -u CMUX_TAG \
    "$app_path/Contents/Resources/bin/cmux" app quit-keep-sessions >/dev/null 2>&1 || true
  running="true"
  for attempt in $(seq 1 30); do
    running="$(app_running)"
    [[ "$running" == "false" ]] && break
    # An app too old for the CLI quit, or one that did not hear it.
    if [[ "$attempt" == 5 ]]; then
      osascript -e "tell application \"$process_name\" to quit" >/dev/null 2>&1 || true
    fi
    sleep 1
  done
  [[ "$running" == "false" ]] || { echo "cmux NEXT DEV did not exit after quit" >&2; exit 1; }
fi
staged="$(dirname "$app_path")/.$app_name.new.$$"
backup="$(dirname "$app_path")/.$app_name.old.$$"
rm -rf -- "$staged" "$backup"
ditto "$downloaded" "$staged"
if [[ -e "$app_path" ]]; then
  mv "$app_path" "$backup"
fi
if ! mv "$staged" "$app_path"; then
  if [[ -e "$backup" ]]; then mv "$backup" "$app_path"; fi
  exit 1
fi
rm -rf -- "$backup"
record "$updated_at" "$sha_line"
echo "Installed cmux NEXT DEV from $tag at $app_path"
if $first_install; then
  open "$app_path"
  echo "Opened cmux NEXT DEV. Next time, run this script again to update it."
elif $was_running; then
  open "$app_path"
  echo "Reopened cmux NEXT DEV; its sessions, agents and chats reattach."
fi
