#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_ROOT="${ROOT}/cmux-tui"
LIB_NAME="libcmux_terminal_client.dylib"
BUILD_OUTPUT_DIR="${TARGET_BUILD_DIR:-${CRATE_ROOT}/target}/cmux-tui-client"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo is required to build ${LIB_NAME}" >&2
  exit 1
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

rust_target_for_triple() {
  case "$1" in
    aarch64-apple-darwin|x86_64-apple-darwin) echo "$1" ;;
    arm64-*|arm64e-*|aarch64-*) echo "aarch64-apple-darwin" ;;
    x86_64-*) echo "x86_64-apple-darwin" ;;
    *)
      echo "error: unsupported Rust macOS target triple $1" >&2
      return 1
      ;;
  esac
}

ensure_rust_target() {
  local target="$1"
  if command -v rustup >/dev/null 2>&1 && ! rustup target list --installed | grep -qx "$target"; then
    rustup target add "$target"
  fi
}

requested_targets="${CMUX_TUI_CLIENT_TARGETS:-}"
if [ -z "${requested_targets}" ] && [ -n "${TARGET_TRIPLE:-}" ]; then
  requested_targets="$(rust_target_for_triple "${TARGET_TRIPLE}")"
fi

if [ -z "${requested_targets}" ]; then
  requested_archs="${CMUX_TUI_CLIENT_ARCHS:-${ARCHS:-}}"
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
  for arch in ${requested_archs}; do
    requested_targets="${requested_targets} $(rust_target_for_arch "$arch")"
  done
fi

mkdir -p "${BUILD_OUTPUT_DIR}"
libs=()
seen_targets=""
for target in ${requested_targets}; do
  case " ${seen_targets} " in
    *" ${target} "*) continue ;;
  esac
  seen_targets="${seen_targets} ${target}"
  ensure_rust_target "$target"
  cargo build \
    --manifest-path "${CRATE_ROOT}/Cargo.toml" \
    --package cmux-terminal-client \
    --no-default-features \
    --features native-renderer \
    --release \
    --locked \
    --target "$target"
  source_lib="${CRATE_ROOT}/target/${target}/release/${LIB_NAME}"
  if [ ! -f "${source_lib}" ]; then
    echo "error: expected cmux-tui client library at ${source_lib}" >&2
    exit 1
  fi
  libs+=("${source_lib}")
done

if [ "${#libs[@]}" -eq 0 ]; then
  echo "error: no Rust macOS architectures requested" >&2
  exit 1
fi

output_lib="${BUILD_OUTPUT_DIR}/${LIB_NAME}"
if [ "${#libs[@]}" -eq 1 ]; then
  rsync -a "${libs[0]}" "${output_lib}"
else
  lipo -create -output "${output_lib}" "${libs[@]}"
fi
/usr/bin/install_name_tool -id "@rpath/${LIB_NAME}" "${output_lib}"

if [ -z "${TARGET_BUILD_DIR:-}" ]; then
  echo "built ${output_lib}"
  exit 0
fi

destination_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH:-${CONTENTS_FOLDER_PATH:-Contents}/Frameworks}"
destination_lib="${destination_dir}/${LIB_NAME}"
mkdir -p "${destination_dir}"
rsync -a "${output_lib}" "${destination_lib}"

if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${destination_lib}" >/dev/null
fi
