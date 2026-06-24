#!/usr/bin/env bash
# Select Xcodes for the nightly macOS build.
set -euo pipefail

APPLICATIONS_DIR="${CMUX_XCODE_APPLICATIONS_DIR:-/Applications}"
PRINT_VERSION="${CMUX_SELECT_XCODE_PRINT_VERSION:-1}"

sdk_major() {
  local v="$1" maj
  maj="${v%%.*}"
  case "$maj" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%d' "$maj"
}

sdk_rank() {
  local v="$1" maj min
  maj="${v%%.*}"
  min="${v#*.}"
  [ "$min" = "$v" ] && min=0
  min="${min%%.*}"
  case "$maj" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$min" in
    ''|*[!0-9]*) min=0 ;;
  esac
  printf '%d' "$(( maj * 1000 + min ))"
}

APP_DEVELOPER_DIR=""
APP_SDK_VER=""
APP_RANK=-1
HELPER_DEVELOPER_DIR=""
HELPER_SDK_VER=""
HELPER_RANK=-1

while IFS= read -r app; do
  [ -n "$app" ] || continue
  dev="$app/Contents/Developer"
  [ -d "$dev" ] || continue
  sdk_ver="$(DEVELOPER_DIR="$dev" xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
  [ -n "$sdk_ver" ] || continue
  if ! major="$(sdk_major "$sdk_ver")"; then
    echo "Ignoring $app with unparsable macOS SDK version: $sdk_ver" >&2
    continue
  fi
  if ! rank="$(sdk_rank "$sdk_ver")"; then
    echo "Ignoring $app with unparsable macOS SDK version: $sdk_ver" >&2
    continue
  fi
  echo "Found $app -> macOS SDK $sdk_ver (rank $rank)"
  if [ "$major" -ge 26 ]; then
    if [ "$rank" -gt "$APP_RANK" ]; then
      APP_DEVELOPER_DIR="$dev"
      APP_SDK_VER="$sdk_ver"
      APP_RANK="$rank"
    fi
  else
    if [ "$rank" -gt "$HELPER_RANK" ]; then
      HELPER_DEVELOPER_DIR="$dev"
      HELPER_SDK_VER="$sdk_ver"
      HELPER_RANK="$rank"
    fi
  fi
done < <(find "$APPLICATIONS_DIR" -maxdepth 1 -name 'Xcode*.app' -print 2>/dev/null | sort)

if [ -z "$APP_DEVELOPER_DIR" ]; then
  echo "No Xcode with the macOS 26+ SDK found; the app would ship without Liquid Glass on Tahoe." >&2
  exit 1
fi

if [ -z "$HELPER_DEVELOPER_DIR" ]; then
  HELPER_DEVELOPER_DIR="$APP_DEVELOPER_DIR"
  HELPER_SDK_VER="$APP_SDK_VER"
  echo "No pre-26 Xcode found for the Ghostty CLI helper; falling back to the app Xcode. The universal helper build and lipo verification remain required." >&2
fi

echo "App build Xcode (DEVELOPER_DIR): $APP_DEVELOPER_DIR (macOS SDK $APP_SDK_VER)"
echo "Helper build Xcode (HELPER_DEVELOPER_DIR): $HELPER_DEVELOPER_DIR (macOS SDK $HELPER_SDK_VER)"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "DEVELOPER_DIR=$APP_DEVELOPER_DIR" >> "$GITHUB_ENV"
  echo "HELPER_DEVELOPER_DIR=$HELPER_DEVELOPER_DIR" >> "$GITHUB_ENV"
fi

if [ "$PRINT_VERSION" != "0" ]; then
  DEVELOPER_DIR="$APP_DEVELOPER_DIR" xcodebuild -version
fi
