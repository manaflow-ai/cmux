#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="${ROOT}/Native/CommandPaletteNucleoFFI"
LIB_NAME="libcmux_command_palette_nucleo_ffi.dylib"
BUILD_OUTPUT_DIR="${TARGET_BUILD_DIR:-${CRATE_DIR}/target}/cmux-nucleo-ffi"

if ! command -v cargo >/dev/null 2>&1; then
  case "${CMUX_NUCLEO_FFI_REQUIRE_CARGO:-${CI:-0}}" in
    1|true|TRUE|yes|YES)
      echo "error: cargo is required to build ${LIB_NAME}" >&2
      exit 1
      ;;
  esac
  echo "warning: cargo not found; skipping optional ${LIB_NAME} build" >&2
  exit 0
fi

requested_archs="${CMUX_NUCLEO_FFI_ARCHS:-${ARCHS:-}}"
if [ -z "${requested_archs}" ]; then
  case "$(uname -m)" in
    arm64|aarch64) requested_archs="arm64" ;;
    x86_64) requested_archs="x86_64" ;;
    *)
      echo "error: cannot infer Rust macOS target for host arch $(uname -m)" >&2
      exit 1
      ;;
  esac
fi

rust_target_for_arch() {
  case "$1" in
    arm64|arm64e) echo "aarch64-apple-darwin" ;;
    x86_64) echo "x86_64-apple-darwin" ;;
    *)
      echo "error: unsupported Rust macOS arch $1" >&2
      return 1
      ;;
  esac
}

ensure_rust_target() {
  local target="$1"
  if rustup target list --installed | grep -qx "$target"; then
    return
  fi
  if command -v rustup >/dev/null 2>&1; then
    rustup target add "$target"
    return
  fi
  echo "error: Rust target $target is not installed and rustup is unavailable" >&2
  exit 1
}

mkdir -p "${BUILD_OUTPUT_DIR}"
libs=()
seen_targets=""
for arch in ${requested_archs}; do
  target="$(rust_target_for_arch "$arch")"
  case " ${seen_targets} " in
    *" ${target} "*) continue ;;
  esac
  seen_targets="${seen_targets} ${target}"
  ensure_rust_target "$target"
  cargo build --manifest-path "${CRATE_DIR}/Cargo.toml" --release --target "$target"
  source_lib="${CRATE_DIR}/target/${target}/release/${LIB_NAME}"
  if [ ! -f "${source_lib}" ]; then
    echo "error: expected nucleo FFI library at ${source_lib}" >&2
    exit 1
  fi
  libs+=("${source_lib}")
done

if [ "${#libs[@]}" -eq 0 ]; then
  echo "error: no Rust macOS architectures requested" >&2
  exit 1
fi

SOURCE_LIB="${BUILD_OUTPUT_DIR}/${LIB_NAME}"
if [ "${#libs[@]}" -eq 1 ]; then
  rsync -a "${libs[0]}" "${SOURCE_LIB}"
else
  lipo -create -output "${SOURCE_LIB}" "${libs[@]}"
fi

DEST_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH:-${CONTENTS_FOLDER_PATH:-Contents}/Frameworks}"
DEST_LIB="${DEST_DIR}/${LIB_NAME}"
mkdir -p "${DEST_DIR}"
rsync -a "${SOURCE_LIB}" "${DEST_LIB}"

if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${DEST_LIB}" >/dev/null
fi
