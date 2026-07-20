#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$PROJECT_DIR/Packages/macOS/CmuxTerminalRenderer"

case "${CONFIGURATION:-Debug}" in
  Release) SWIFT_CONFIGURATION=release ;;
  *) SWIFT_CONFIGURATION=debug ;;
esac

if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${CONTENTS_FOLDER_PATH:-}" || -z "${DERIVED_FILE_DIR:-}" ]]; then
  echo "error: renderer process build must run inside an Xcode app build" >&2
  exit 1
fi

APP_CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
HELPER_DIR="$APP_CONTENTS/Helpers"
SCRATCH_ROOT="$DERIVED_FILE_DIR/cmux-terminal-renderer-processes"

mkdir -p "$HELPER_DIR"

read -r -a BUILD_ARCHS <<< "${ARCHS:-$(uname -m)}"
if [[ "${ONLY_ACTIVE_ARCH:-NO}" == "YES" \
  && -n "${CURRENT_ARCH:-}" \
  && "${CURRENT_ARCH}" != "undefined_arch" ]]; then
  BUILD_ARCHS=("$CURRENT_ARCH")
fi

WORKER_BINARIES=()
for BUILD_ARCH in "${BUILD_ARCHS[@]}"; do
  case "$BUILD_ARCH" in
    arm64) BUILD_TRIPLE="arm64-apple-macosx14.0" ;;
    x86_64) BUILD_TRIPLE="x86_64-apple-macosx14.0" ;;
    *)
      echo "error: unsupported renderer process architecture: $BUILD_ARCH" >&2
      exit 1
      ;;
  esac

  ARCH_SCRATCH="$SCRATCH_ROOT/$BUILD_ARCH"
  xcrun swift build \
    --package-path "$PACKAGE_DIR" \
    --scratch-path "$ARCH_SCRATCH" \
    --configuration "$SWIFT_CONFIGURATION" \
    --triple "$BUILD_TRIPLE" \
    --product CmuxTerminalRendererWorker

  BIN_DIR="$(xcrun swift build \
    --package-path "$PACKAGE_DIR" \
    --scratch-path "$ARCH_SCRATCH" \
    --configuration "$SWIFT_CONFIGURATION" \
    --triple "$BUILD_TRIPLE" \
    --show-bin-path)"
  WORKER_BINARIES+=("$BIN_DIR/CmuxTerminalRendererWorker")
done

WORKER_DEST="$HELPER_DIR/CmuxTerminalRendererWorker"
if [[ ${#BUILD_ARCHS[@]} -eq 1 ]]; then
  cp "${WORKER_BINARIES[0]}" "$WORKER_DEST"
else
  xcrun lipo -create "${WORKER_BINARIES[@]}" -output "$WORKER_DEST"
fi
chmod 755 "$WORKER_DEST"

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
  SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$WORKER_DEST"
fi
