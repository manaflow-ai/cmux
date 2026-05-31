#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
  set +a
fi

PROJECT_PATH="$ROOT_DIR/cmux.xcodeproj"
XCCONFIG_PATH="${PANECHO_XCCONFIG:-$ROOT_DIR/Config/PrivacyOverrides.xcconfig}"
DERIVED_DATA_PATH="${PANECHO_DERIVED_DATA_PATH:-$ROOT_DIR/build/panecho-derived-data}"
SCHEME="${PANECHO_SCHEME:-cmux}"
CONFIGURATION="${PANECHO_CONFIGURATION:-Release}"
DESTINATION="${PANECHO_DESTINATION:-platform=macOS}"
SOURCE_APP_NAME="${PANECHO_SOURCE_APP_NAME:-cmux.app}"
STAGED_APP_NAME="${PANECHO_STAGED_APP_NAME:-Panecho.app}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is not available. Install full Xcode and run xcode-select --switch /Applications/Xcode.app." >&2
  exit 1
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: xcodebuild exists but is not usable. Install full Xcode and point xcode-select at it." >&2
  exit 1
fi

if [[ ! -f "$XCCONFIG_PATH" ]]; then
  echo "error: missing privacy overlay at $XCCONFIG_PATH" >&2
  exit 1
fi

mkdir -p "$DERIVED_DATA_PATH"

XCODEBUILD_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -xcconfig "$XCCONFIG_PATH"
)

if [[ "${PANECHO_ALLOW_CODESIGN:-0}" != "1" ]]; then
  XCODEBUILD_ARGS+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
fi

xcodebuild "${XCODEBUILD_ARGS[@]}" "$@" build

BUILT_APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$SOURCE_APP_NAME"
STAGED_APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$STAGED_APP_NAME"

if [[ ! -d "$BUILT_APP_PATH" ]]; then
  echo "error: expected built app at $BUILT_APP_PATH" >&2
  exit 1
fi

"$ROOT_DIR/scripts/stage-panecho-app.sh" "$BUILT_APP_PATH" "$STAGED_APP_PATH"
