#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/strip-release-bundle.sh <path-to-cmux.app>

Strips cmux-owned Release Mach-O binaries before codesigning: executables fully,
plug-ins and libraries down to their global symbols.
The dSYM UUID is preserved, so Sentry symbol upload continues to match crashes.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi

APP_PATH="$1"
if [ ! -d "$APP_PATH/Contents" ]; then
  echo "error: app bundle not found: $APP_PATH" >&2
  exit 1
fi

FILE_TOOL="${CMUX_FILE_TOOL:-file}"
STRIP_TOOL="${CMUX_STRIP_TOOL:-strip}"

# strip_if_macho <path> [full]. By default it uses -S -x, which keeps global
# symbols for plug-ins, libraries and extensions.
strip_if_macho() {
  local path="$1"
  local mode="${2:-}"
  [ -f "$path" ] || return 0
  [ -x "$path" ] || return 0
  if ! "$FILE_TOOL" "$path" | grep -q 'Mach-O'; then
    return 0
  fi
  echo "stripping release binary: $path"
  if [ "$mode" = full ]; then
    "$STRIP_TOOL" "$path"
  else
    "$STRIP_TOOL" -S -x "$path"
  fi
}

# cmux's own executables keep only what dyld needs: plain strip on a dynamically
# linked executable saves undefined and dynamically referenced symbols (-u -r).
# Nothing looks their other symbols up at runtime, and crashes symbolicate from
# the dSYMs uploaded to Sentry. Measured on arm64: 10.4 MB in the app, 2.8 MB in
# the CLI.
strip_executable() {
  strip_if_macho "$1" full
}

strip_executable "$APP_PATH/Contents/MacOS/cmux"
strip_executable "$APP_PATH/Contents/Resources/bin/cmux"
strip_executable "$APP_PATH/Contents/Resources/bin/cmux-tui"
strip_executable "$APP_PATH/Contents/Resources/bin/cmux-diff-sidecar"

# cmux-tui SSH bootstrap payloads are installed 0644, so strip_if_macho's
# executable check would skip them. Only the macOS builds are Mach-O; the Linux
# builds arrive stripped. sign-cmux-tui-ssh-payloads.sh signs these afterwards
# and re-pins their checksums in manifest.json, so the strip needs no re-pin.
if [ -d "$APP_PATH/Contents/Resources/bin/cmux-tui-ssh" ]; then
  while IFS= read -r -d '' payload; do
    if "$FILE_TOOL" "$payload" | grep -q 'Mach-O'; then
      echo "stripping cmux-tui SSH payload: $payload"
      "$STRIP_TOOL" -S -x "$payload"
    fi
  done < <(find "$APP_PATH/Contents/Resources/bin/cmux-tui-ssh" -maxdepth 1 -name 'cmux-tui-*-apple-darwin' -type f -print0 | sort -z)
fi

if [ -d "$APP_PATH/Contents/PlugIns" ]; then
  while IFS= read -r -d '' binary; do
    strip_if_macho "$binary"
  done < <(find "$APP_PATH/Contents/PlugIns" -path '*/Contents/MacOS/*' -type f -print0)
fi

if [ -d "$APP_PATH/Contents/Frameworks" ]; then
  while IFS= read -r -d '' binary; do
    strip_if_macho "$binary"
  done < <(find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -name 'libcmux_*.dylib' -type f -print0)
fi

if [ -d "$APP_PATH/Contents/Library/SystemExtensions" ]; then
  while IFS= read -r -d '' binary; do
    strip_if_macho "$binary"
  done < <(find "$APP_PATH/Contents/Library/SystemExtensions" -path '*/Contents/MacOS/*' -type f -print0)
fi
