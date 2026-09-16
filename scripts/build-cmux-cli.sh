#!/usr/bin/env bash
set -euo pipefail

# Build the native cmux command line client and copy it into an app bundle.
#
# This script is intentionally independent of the Swift target.  The Swift
# project can invoke it as an Xcode run-script phase with TARGET_BUILD_DIR set,
# while CI and size checks can pass --output to keep the artifact outside an
# app.  Cargo is only run here; the app never shells out to cargo at runtime.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="${ROOT}/Native/CmuxCLI"
BINARY_NAME="cmux"
OUTPUT_PATH=""
UNIVERSAL=0

usage() {
  cat <<'EOF'
Usage: scripts/build-cmux-cli.sh [--universal | --target <triple>] [--output <path>]

Without --output, an Xcode invocation copies cmux into
$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/bin/cmux.
EOF
}

TARGET_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal) UNIVERSAL=1; shift ;;
    --target) TARGET_OVERRIDE="${2:-}"; [[ -n "$TARGET_OVERRIDE" ]] || { usage >&2; exit 2; }; shift 2 ;;
    --output) OUTPUT_PATH="${2:-}"; [[ -n "$OUTPUT_PATH" ]] || { usage >&2; exit 2; }; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if (( UNIVERSAL )) && [[ -n "$TARGET_OVERRIDE" ]]; then
  echo "error: --universal and --target are mutually exclusive" >&2
  exit 2
fi
[[ -f "${CRATE_DIR}/Cargo.toml" ]] || { echo "error: missing Rust CLI crate at ${CRATE_DIR}" >&2; exit 1; }

export PATH="${CARGO_HOME:-${HOME}/.cargo}/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
CARGO_COMMAND=(cargo)
if [[ -n "${CMUX_CLI_TOOLCHAIN:-}" ]]; then
  command -v rustup >/dev/null 2>&1 || { echo "error: CMUX_CLI_TOOLCHAIN requires rustup" >&2; exit 1; }
  CARGO_COMMAND=(rustup run "$CMUX_CLI_TOOLCHAIN" cargo)
elif ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo is required to build ${BINARY_NAME}" >&2
  exit 1
fi

rust_target_for_arch() {
  case "$1" in
    arm64|arm64e|aarch64) echo "aarch64-apple-darwin" ;;
    x86_64|x86-64) echo "x86_64-apple-darwin" ;;
    *) echo "error: unsupported macOS architecture: $1" >&2; return 1 ;;
  esac
}

rust_target_for_triple() {
  case "$1" in
    aarch64-apple-darwin|x86_64-apple-darwin) echo "$1" ;;
    arm64|arm64e|aarch64|arm64-*) echo "aarch64-apple-darwin" ;;
    x86_64|x86-64|x86_64-*) echo "x86_64-apple-darwin" ;;
    *) echo "error: unsupported Rust target triple: $1" >&2; return 1 ;;
  esac
}

requested_targets=""
if [[ -n "$TARGET_OVERRIDE" ]]; then
  requested_targets="$(rust_target_for_triple "$TARGET_OVERRIDE")"
elif [[ -n "${CMUX_CLI_TARGETS:-}" ]]; then
  requested_targets="${CMUX_CLI_TARGETS}"
else
  requested_archs="${CMUX_CLI_ARCHS:-${ARCHS:-}}"
  if [[ -z "$requested_archs" ]]; then
    if (( UNIVERSAL )); then
      requested_archs="arm64 x86_64"
    else
      case "$(uname -m)" in
        arm64|aarch64) requested_archs="arm64" ;;
        x86_64) requested_archs="x86_64" ;;
        *) echo "error: cannot infer macOS architecture from $(uname -m)" >&2; exit 1 ;;
      esac
    fi
  fi
  for arch in $requested_archs; do
    requested_targets="${requested_targets} $(rust_target_for_arch "$arch")"
  done
fi

if (( UNIVERSAL )); then
  requested_targets="aarch64-apple-darwin x86_64-apple-darwin"
fi

if [[ -z "$OUTPUT_PATH" && -n "${TARGET_BUILD_DIR:-}" ]]; then
  OUTPUT_PATH="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-Contents/Resources}/bin/${BINARY_NAME}"
fi
if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="${CRATE_DIR}/target/cmux-cli/${BINARY_NAME}"
fi

WORK_DIR="${CMUX_CLI_BUILD_DIR:-${CRATE_DIR}/target/cmux-cli-build}"
mkdir -p "$WORK_DIR" "$(dirname "$OUTPUT_PATH")"

# Preserve the exact Swift CLI copied by the preceding Xcode phase. The Rust
# dispatcher delegates only commands not yet migrated to this sibling during
# the opt-in migration, so existing app behavior remains intact.
if [[ -n "${TARGET_BUILD_DIR:-}" && -x "$OUTPUT_PATH" && "${CMUX_CLI_KEEP_SWIFT_FALLBACK:-1}" != "0" ]]; then
  cp "$OUTPUT_PATH" "${OUTPUT_PATH}-swift"
  chmod 755 "${OUTPUT_PATH}-swift"
fi

lock_args=()
if [[ -f "${CRATE_DIR}/Cargo.lock" ]]; then
  lock_args=(--locked)
else
  echo "warning: ${CRATE_DIR}/Cargo.lock is missing; this build is not dependency-locked" >&2
fi

ensure_target() {
  local target="$1"
  if [[ -n "${CMUX_CLI_TOOLCHAIN:-}" ]]; then
    if ! rustup target list --toolchain "$CMUX_CLI_TOOLCHAIN" --installed | grep -qx "$target"; then
      rustup target add --toolchain "$CMUX_CLI_TOOLCHAIN" "$target"
    fi
  elif command -v rustup >/dev/null 2>&1 && ! rustup target list --installed | grep -qx "$target"; then
    rustup target add "$target"
  fi
}

binaries=()
seen=" "
for target in $requested_targets; do
  [[ "$seen" == *" ${target} "* ]] && continue
  seen="${seen}${target} "
  ensure_target "$target"
  target_dir="${WORK_DIR}/${target}"
  mkdir -p "$target_dir"
  cargo_args=(build --manifest-path "${CRATE_DIR}/Cargo.toml" --bin "$BINARY_NAME" --release --target "$target" "${lock_args[@]}")
  CARGO_TARGET_DIR="$target_dir" MACOSX_DEPLOYMENT_TARGET="${CMUX_CLI_MIN_MACOS:-13.0}" "${CARGO_COMMAND[@]}" "${cargo_args[@]}"
  source_binary="${target_dir}/${target}/release/${BINARY_NAME}"
  [[ -x "$source_binary" ]] || { echo "error: missing built CLI at ${source_binary}" >&2; exit 1; }
  binaries+=("$source_binary")
done

if [[ "${#binaries[@]}" -eq 1 ]]; then
  cp "${binaries[0]}" "$OUTPUT_PATH"
else
  lipo -create -output "$OUTPUT_PATH" "${binaries[@]}"
fi
chmod 755 "$OUTPUT_PATH"

if [[ "${#binaries[@]}" -gt 1 ]]; then
  lipo "$OUTPUT_PATH" -verify_arch arm64
  lipo "$OUTPUT_PATH" -verify_arch x86_64
fi
if [[ -n "${TARGET_BUILD_DIR:-}" && "${CODE_SIGNING_ALLOWED:-YES}" != "NO" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$OUTPUT_PATH" >/dev/null
fi
echo "built ${OUTPUT_PATH} ($(stat -f '%z' "$OUTPUT_PATH") bytes)"
