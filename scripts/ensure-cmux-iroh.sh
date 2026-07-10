#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="${ROOT}/native/cmux-iroh"
HEADER_DIR="${CRATE_DIR}/include"
LIB_NAME="libcmux_iroh_ffi.a"
XCFRAMEWORK_NAME="CmuxIrohFFI.xcframework"
LOCAL_XCFRAMEWORK="${ROOT}/${XCFRAMEWORK_NAME}"
CACHE_ROOT="${CMUX_IROH_CACHE_DIR:-${CRATE_DIR}/target/xcframework-cache}"

TARGETS=(
  aarch64-apple-darwin
  x86_64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
)

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo is required to build ${XCFRAMEWORK_NAME}" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun is required to build ${XCFRAMEWORK_NAME}" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is required to build ${XCFRAMEWORK_NAME}" >&2
  exit 1
fi

ensure_rust_target() {
  local target="$1"
  if command -v rustup >/dev/null 2>&1; then
    if rustup target list --installed | grep -qx "$target"; then
      return
    fi
    rustup target add "$target"
  fi
}

hash_sources() {
  {
    printf '%s\n' "cmux-iroh-xcframework-v1"
    shasum -a 256 "${BASH_SOURCE[0]}"
    find "${CRATE_DIR}" -type f \
      ! -path "${CRATE_DIR}/target/*" \
      ! -name ".DS_Store" \
      -print0 |
      sort -z |
      while IFS= read -r -d '' file; do
        shasum -a 256 "$file"
      done
  } | shasum -a 256 | awk '{print $1}'
}

build_target() {
  local target="$1"
  ensure_rust_target "$target"
  case "$target" in
    aarch64-apple-ios)
      SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
        IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}" \
        cargo build --manifest-path "${CRATE_DIR}/Cargo.toml" --release --target "$target"
      ;;
    aarch64-apple-ios-sim)
      SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)" \
        IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}" \
        cargo build --manifest-path "${CRATE_DIR}/Cargo.toml" --release --target "$target"
      ;;
    *-apple-darwin)
      SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
        MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
        cargo build --manifest-path "${CRATE_DIR}/Cargo.toml" --release --target "$target"
      ;;
    *)
      echo "error: unsupported Rust target ${target}" >&2
      exit 1
      ;;
  esac
}

refresh_archive_index() {
  local archive="$1"
  if [ -f "$archive" ]; then
    xcrun ranlib "$archive"
  fi
}

link_local_xcframework() {
  local built="$1"
  rm -rf "${LOCAL_XCFRAMEWORK}"
  ln -s "$built" "${LOCAL_XCFRAMEWORK}"
}

mkdir -p "${CACHE_ROOT}"
BUILD_KEY="$(hash_sources)"
CACHE_DIR="${CACHE_ROOT}/${BUILD_KEY}"
CACHE_XCFRAMEWORK="${CACHE_DIR}/${XCFRAMEWORK_NAME}"

if [ -d "${CACHE_XCFRAMEWORK}" ]; then
  link_local_xcframework "${CACHE_XCFRAMEWORK}"
  echo "using cached ${LOCAL_XCFRAMEWORK}"
  exit 0
fi

LOCK_DIR="${CACHE_ROOT}/.${BUILD_KEY}.lock"
while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
  if [ -d "${CACHE_XCFRAMEWORK}" ]; then
    link_local_xcframework "${CACHE_XCFRAMEWORK}"
    echo "using cached ${LOCAL_XCFRAMEWORK}"
    exit 0
  fi
  sleep 1
done
cleanup_lock() {
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}
trap cleanup_lock EXIT

if [ -d "${CACHE_XCFRAMEWORK}" ]; then
  link_local_xcframework "${CACHE_XCFRAMEWORK}"
  echo "using cached ${LOCAL_XCFRAMEWORK}"
  exit 0
fi

for target in "${TARGETS[@]}"; do
  build_target "$target"
done

TMP_DIR="$(mktemp -d "${CACHE_ROOT}/build-${BUILD_KEY}.XXXXXX")"
cleanup_tmp() {
  rm -rf "${TMP_DIR}"
}
trap 'cleanup_tmp; cleanup_lock' EXIT

mkdir -p "${TMP_DIR}/macos" "${TMP_DIR}/ios-device" "${TMP_DIR}/ios-simulator"

MACOS_ARM_LIB="${CRATE_DIR}/target/aarch64-apple-darwin/release/${LIB_NAME}"
MACOS_X86_LIB="${CRATE_DIR}/target/x86_64-apple-darwin/release/${LIB_NAME}"
IOS_DEVICE_LIB="${CRATE_DIR}/target/aarch64-apple-ios/release/${LIB_NAME}"
IOS_SIM_LIB="${CRATE_DIR}/target/aarch64-apple-ios-sim/release/${LIB_NAME}"

for lib in "${MACOS_ARM_LIB}" "${MACOS_X86_LIB}" "${IOS_DEVICE_LIB}" "${IOS_SIM_LIB}"; do
  if [ ! -f "$lib" ]; then
    echo "error: expected Rust static library at ${lib}" >&2
    exit 1
  fi
done

xcrun lipo -create -output "${TMP_DIR}/macos/${LIB_NAME}" "${MACOS_ARM_LIB}" "${MACOS_X86_LIB}"
cp "${IOS_DEVICE_LIB}" "${TMP_DIR}/ios-device/${LIB_NAME}"
cp "${IOS_SIM_LIB}" "${TMP_DIR}/ios-simulator/${LIB_NAME}"

refresh_archive_index "${TMP_DIR}/macos/${LIB_NAME}"
refresh_archive_index "${TMP_DIR}/ios-device/${LIB_NAME}"
refresh_archive_index "${TMP_DIR}/ios-simulator/${LIB_NAME}"

xcodebuild -create-xcframework \
  -library "${TMP_DIR}/macos/${LIB_NAME}" -headers "${HEADER_DIR}" \
  -library "${TMP_DIR}/ios-device/${LIB_NAME}" -headers "${HEADER_DIR}" \
  -library "${TMP_DIR}/ios-simulator/${LIB_NAME}" -headers "${HEADER_DIR}" \
  -output "${TMP_DIR}/${XCFRAMEWORK_NAME}"

mkdir -p "${CACHE_DIR}"
mv "${TMP_DIR}/${XCFRAMEWORK_NAME}" "${CACHE_XCFRAMEWORK}"
link_local_xcframework "${CACHE_XCFRAMEWORK}"

echo "built ${LOCAL_XCFRAMEWORK}"
