#!/usr/bin/env bash
set -euo pipefail

HELPER_NAME="com.cmuxterm.sudo-helper"
SRCROOT="${SRCROOT:?SRCROOT is required}"
TARGET_BUILD_DIR="${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}"
CONTENTS_FOLDER_PATH="${CONTENTS_FOLDER_PATH:?CONTENTS_FOLDER_PATH is required}"
PRODUCT_BUNDLE_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER:?PRODUCT_BUNDLE_IDENTIFIER is required}"

HELPER_SRC="${SRCROOT}/PrivilegedHelpers/cmux-sudo-helper/main.swift"
PLIST_SRC="${SRCROOT}/PrivilegedHelpers/cmux-sudo-helper/${HELPER_NAME}.plist"
APP_CONTENTS="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}"
LAUNCH_SERVICES_DIR="${APP_CONTENTS}/Library/LaunchServices"
LAUNCH_DAEMONS_DIR="${APP_CONTENTS}/Library/LaunchDaemons"
HELPER_DEST="${LAUNCH_SERVICES_DIR}/${HELPER_NAME}"
PLIST_DEST="${LAUNCH_DAEMONS_DIR}/${HELPER_NAME}.plist"

if [[ ! -f "$HELPER_SRC" ]]; then
  echo "error: missing sudo helper source at $HELPER_SRC" >&2
  exit 1
fi
if [[ ! -f "$PLIST_SRC" ]]; then
  echo "error: missing sudo helper plist at $PLIST_SRC" >&2
  exit 1
fi

mkdir -p "$LAUNCH_SERVICES_DIR" "$LAUNCH_DAEMONS_DIR"

SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
SWIFTC="${TOOLCHAIN_DIR:-$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain}/usr/bin/swiftc"
if [[ ! -x "$SWIFTC" ]]; then
  SWIFTC="$(xcrun --find swiftc)"
fi

DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
ARCH_LIST="${ARCHS:-${CURRENT_ARCH:-$(uname -m)}}"
TMPDIR_HELPER="$(mktemp -d "${TMPDIR:-/tmp}/cmux-sudo-helper.XXXXXX")"
trap 'rm -rf "$TMPDIR_HELPER"' EXIT

BUILT_HELPERS=()
for ARCH in $ARCH_LIST; do
  case "$ARCH" in
    arm64) TARGET_TRIPLE="arm64-apple-macos${DEPLOYMENT_TARGET}" ;;
    x86_64) TARGET_TRIPLE="x86_64-apple-macos${DEPLOYMENT_TARGET}" ;;
    *)
      echo "error: unsupported sudo helper arch $ARCH" >&2
      exit 1
      ;;
  esac

  OUT="${TMPDIR_HELPER}/${HELPER_NAME}-${ARCH}"
  EXTRA_FLAGS=()
  if [[ "${CONFIGURATION:-}" == "Debug" ]]; then
    EXTRA_FLAGS+=("-D" "DEBUG")
  fi
  "$SWIFTC" \
    -parse-as-library \
    -O \
    -sdk "$SDKROOT" \
    -target "$TARGET_TRIPLE" \
    "${EXTRA_FLAGS[@]}" \
    -o "$OUT" \
    "$HELPER_SRC"
  BUILT_HELPERS+=("$OUT")
done

if [[ "${#BUILT_HELPERS[@]}" -eq 1 ]]; then
  cp "${BUILT_HELPERS[0]}" "$HELPER_DEST"
else
  lipo -create "${BUILT_HELPERS[@]}" -output "$HELPER_DEST"
fi
chmod 755 "$HELPER_DEST"

sed "s|@CMUX_BUNDLE_IDENTIFIER@|${PRODUCT_BUNDLE_IDENTIFIER}|g" "$PLIST_SRC" > "$PLIST_DEST"
chmod 644 "$PLIST_DEST"
/usr/bin/plutil -lint "$PLIST_DEST" >/dev/null

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
  SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
  if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
    SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-${CODE_SIGN_IDENTITY:-}}"
  fi
  if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" || "$SIGN_IDENTITY" == "Sign to Run Locally" ]]; then
    SIGN_IDENTITY="-"
  fi

  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --identifier "$HELPER_NAME")
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--options runtime)
  fi
  HELPER_ENTITLEMENTS="${HELPER_ENTITLEMENTS:-}"
  if [[ -n "$HELPER_ENTITLEMENTS" && -s "$HELPER_ENTITLEMENTS" ]]; then
    SIGN_ARGS+=(--entitlements "$HELPER_ENTITLEMENTS")
  fi

  /usr/bin/codesign "${SIGN_ARGS[@]}" "$HELPER_DEST"
fi
