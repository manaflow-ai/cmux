#!/usr/bin/env bash
# Verify every Mach-O load command in a macOS app resolves inside the bundle or
# to an operating-system path that Gatekeeper may provide.
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 <app-bundle>" >&2
  exit 2
fi

APP_PATH="$1"
if [[ ! -d "$APP_PATH/Contents" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi

APP_ROOT="$(cd "$APP_PATH" && pwd -P)"
OTOOL_TOOL="${OTOOL_TOOL:-/usr/bin/otool}"
FILE_TOOL="${FILE_TOOL:-/usr/bin/file}"
if [[ ! -x "$OTOOL_TOOL" ]]; then
  echo "error: otool tool not found or not executable: $OTOOL_TOOL" >&2
  exit 1
fi
if [[ ! -x "$FILE_TOOL" ]]; then
  echo "error: file tool not found or not executable: $FILE_TOOL" >&2
  exit 1
fi

is_allowed_load_path() {
  local load_path="$1"
  case "$load_path" in
    @*)
      return 0
      ;;
    /usr/lib|/usr/lib/*|/System|/System/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

check_macho() {
  local binary="$1"
  local load_commands
  if ! load_commands="$("$OTOOL_TOOL" -arch all -l "$binary" 2>&1)"; then
    echo "error: could not inspect Mach-O load commands: $binary" >&2
    echo "$load_commands" >&2
    return 1
  fi

  while IFS=$'\t' read -r command load_path; do
    [[ -n "$load_path" ]] || continue
    if ! is_allowed_load_path "$load_path"; then
      echo "error: $binary has $command outside the app/system roots: $load_path" >&2
      echo "  allowed absolute roots: /usr/lib, /System; bundle-internal paths must be @-relative" >&2
      return 1
    fi
  done < <(
    printf '%s\n' "$load_commands" | awk '
      $1 == "cmd" {
        command = $2
        next
      }
      command ~ /^LC_(RPATH|LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|LOAD_UPWARD_DYLIB)$/ &&
        ($1 == "path" || $1 == "name") {
        value = $0
        sub(/^[[:space:]]+(path|name)[[:space:]]+/, "", value)
        sub(/[[:space:]]+\(offset [0-9]+\).*$/, "", value)
        print command "\t" value
        command = ""
      }
    '
  )
}

macho_count=0
while IFS= read -r -d '' candidate; do
  description="$("$FILE_TOOL" -b "$candidate" 2>/dev/null || true)"
  [[ "$description" == *Mach-O* ]] || continue
  macho_count=$((macho_count + 1))
  check_macho "$candidate"
done < <(find "$APP_ROOT" -type f -print0)

if [[ "$macho_count" -eq 0 ]]; then
  echo "error: no Mach-O files found under $APP_PATH" >&2
  exit 1
fi

echo "PASS: Mach-O load commands are distribution-safe ($macho_count files): $APP_PATH"
