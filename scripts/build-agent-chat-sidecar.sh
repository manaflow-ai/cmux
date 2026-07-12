#!/bin/sh
set -eu

BUN="$(command -v bun 2>/dev/null || true)"
if [ -z "$BUN" ] && [ -x "$HOME/.bun/bin/bun" ]; then
  BUN="$HOME/.bun/bin/bun"
fi
if [ -z "$BUN" ]; then
  echo "error: bun is required to build the Agent Chat sidecar" >&2
  exit 1
fi

BIN_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
DEST="${BIN_DIR}/cmux-agent-chat"
ICON_DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/agent-chat-icons"
mkdir -p "$BIN_DIR" "$ICON_DEST"
rsync -a --delete "${SRCROOT}/Assets.xcassets/AgentIcons/" "$ICON_DEST/"

build_arch() {
  arch="$1"
  output="$2"
  case "$arch" in
    arm64) target="bun-darwin-arm64" ;;
    x86_64) target="bun-darwin-x64" ;;
    *) echo "error: unsupported Agent Chat architecture: $arch" >&2; exit 1 ;;
  esac
  "$BUN" build --compile --minify --target="$target" \
    "${SRCROOT}/agent-chat/server.ts" --outfile "$output"
}

ARCHS_LIST=" ${ARCHS:-$(uname -m)} "
HAS_ARM64=0
HAS_X86_64=0
case "$ARCHS_LIST" in *" arm64 "*) HAS_ARM64=1 ;; esac
case "$ARCHS_LIST" in *" x86_64 "*) HAS_X86_64=1 ;; esac
if [ "$HAS_ARM64" -eq 1 ] && [ "$HAS_X86_64" -eq 1 ]; then
  arm="${TEMP_DIR}/cmux-agent-chat-arm64"
  intel="${TEMP_DIR}/cmux-agent-chat-x86_64"
  build_arch arm64 "$arm"
  build_arch x86_64 "$intel"
  /usr/bin/lipo -create "$arm" "$intel" -output "$DEST"
elif [ "$HAS_ARM64" -eq 1 ]; then
  build_arch arm64 "$DEST"
elif [ "$HAS_X86_64" -eq 1 ]; then
  build_arch x86_64 "$DEST"
else
  echo "error: no supported architecture in ARCHS=${ARCHS:-}" >&2
  exit 1
fi

chmod 755 "$DEST"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --options runtime --timestamp=none "$DEST"
fi
