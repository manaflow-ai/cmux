#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/verify-universal-macos-app.sh <app-path> [--label <name>]

Verifies that the app executable, bundled cmux CLI, and bundled Ghostty helper
all contain both arm64 and x86_64 Mach-O slices.
EOF
}

APP_PATH=""
LABEL="macOS app"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)
      LABEL="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$APP_PATH" ]]; then
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      APP_PATH="$1"
      shift
      ;;
  esac
done

if [[ -z "$APP_PATH" ]]; then
  usage >&2
  exit 1
fi

if [[ -z "$LABEL" ]]; then
  echo "Missing value for --label" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi

LIPO_BIN="${CMUX_LIPO:-lipo}"
if ! command -v "$LIPO_BIN" >/dev/null 2>&1; then
  echo "error: lipo is required to verify universal macOS binaries" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXECUTABLE_NAME=""
if [[ -f "$INFO_PLIST" && -x /usr/libexec/PlistBuddy ]]; then
  EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$INFO_PLIST" 2>/dev/null || true)"
fi
if [[ -z "$EXECUTABLE_NAME" ]]; then
  EXECUTABLE_NAME="$(basename "$APP_PATH" .app)"
fi

APP_BINARY="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
CLI_BINARY="$APP_PATH/Contents/Resources/bin/cmux"
HELPER_BINARY="$APP_PATH/Contents/Resources/bin/ghostty"

verify_binary_archs() {
  local name="$1"
  local path="$2"
  local archs

  if [[ ! -x "$path" ]]; then
    echo "error: $name is missing or not executable at $path" >&2
    exit 1
  fi

  if ! archs="$("$LIPO_BIN" -archs "$path")"; then
    echo "error: failed to inspect $name architectures at $path" >&2
    exit 1
  fi

  echo "$LABEL $name architectures: $archs"
  for expected_arch in arm64 x86_64; do
    case " $archs " in
      *" $expected_arch "*)
        ;;
      *)
        echo "error: $name at $path is missing $expected_arch slice" >&2
        exit 1
        ;;
    esac
  done
}

verify_binary_archs "app binary" "$APP_BINARY"
verify_binary_archs "CLI binary" "$CLI_BINARY"
verify_binary_archs "Ghostty helper" "$HELPER_BINARY"
