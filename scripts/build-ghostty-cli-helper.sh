#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/build-ghostty-cli-helper.sh [--universal | --target <zig-target>] --output <path>

Options:
  --universal      Build a universal macOS helper (arm64 + x86_64).
  --target <triple>
                   Build a single target, e.g. `aarch64-macos` or `x86_64-macos`.
  --output <path>  Destination path for the built helper.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/ghostty"
source "$SCRIPT_DIR/zig-build-env.sh"

OUTPUT_PATH=""
TARGET_TRIPLE=""
UNIVERSAL="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal)
      UNIVERSAL="true"
      shift
      ;;
    --target)
      TARGET_TRIPLE="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$OUTPUT_PATH" ]]; then
  echo "Missing required --output path" >&2
  usage >&2
  exit 1
fi

# Allow CI to skip the zig build (e.g., macOS 26 where zig 0.15.2 can't link).
# Creates a stub binary so the Xcode Run Script file-existence check passes.
if [[ "${CMUX_SKIP_ZIG_BUILD:-}" == "1" ]]; then
  echo "Skipping zig CLI helper build (CMUX_SKIP_ZIG_BUILD=1)"
  mkdir -p "$(dirname "$OUTPUT_PATH")"
  printf '#!/bin/sh\necho "ghostty CLI helper stub (zig build skipped)" >&2\nexit 1\n' > "$OUTPUT_PATH"
  chmod +x "$OUTPUT_PATH"
  exit 0
fi

if [[ "$UNIVERSAL" == "true" && -n "$TARGET_TRIPLE" ]]; then
  echo "--universal and --target are mutually exclusive" >&2
  usage >&2
  exit 1
fi

if [[ -n "$TARGET_TRIPLE" ]]; then
  case "$TARGET_TRIPLE" in
    aarch64-macos|x86_64-macos)
      ;;
    *)
      echo "Unsupported --target value: $TARGET_TRIPLE" >&2
      exit 1
      ;;
  esac
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "error: zig is required to build the Ghostty CLI helper" >&2
  exit 1
fi

if [[ ! -f "$GHOSTTY_DIR/build.zig" ]]; then
  echo "error: Ghostty submodule is missing at $GHOSTTY_DIR" >&2
  exit 1
fi

build_helper() {
  local prefix="$1"
  local target="${2:-}"
  local args=(
    zig build
    -Dapp-runtime=none
    -Demit-macos-app=true
    -Demit-xcframework=false
    -Dxcframework-target=native
    -Doptimize=ReleaseFast
    --prefix
    "$prefix"
  )

  if [[ -n "$target" ]]; then
    args+=("-Dtarget=$target")
  fi

  (
    cd "$GHOSTTY_DIR"
    cmux_run_zig "${args[@]:1}"
  )
}

helper_binary_path() {
  local prefix="$1"
  local bin_path="$prefix/bin/ghostty"
  local app_path="$prefix/Ghostty.app/Contents/MacOS/ghostty"
  if [[ -x "$bin_path" ]]; then
    printf '%s\n' "$bin_path"
    return 0
  fi
  if [[ -x "$app_path" ]]; then
    printf '%s\n' "$app_path"
    return 0
  fi
  echo "error: Ghostty helper binary missing under $prefix" >&2
  return 1
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ghostty-helper.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$(dirname "$OUTPUT_PATH")"

if [[ "$UNIVERSAL" == "true" ]]; then
  ARM64_PREFIX="$TMP_DIR/arm64"
  X86_PREFIX="$TMP_DIR/x86_64"
  build_helper "$ARM64_PREFIX" "aarch64-macos"
  build_helper "$X86_PREFIX" "x86_64-macos"
  /usr/bin/lipo -create \
    "$(helper_binary_path "$ARM64_PREFIX")" \
    "$(helper_binary_path "$X86_PREFIX")" \
    -output "$OUTPUT_PATH"
else
  SINGLE_PREFIX="$TMP_DIR/single"
  build_helper "$SINGLE_PREFIX" "$TARGET_TRIPLE"
  install -m 755 "$(helper_binary_path "$SINGLE_PREFIX")" "$OUTPUT_PATH"
fi

chmod +x "$OUTPUT_PATH"

# Ghostty's macOS helper binary is linked as if it lives in Contents/MacOS.
# cmux stores it in Contents/Resources/bin, so rewrite the Frameworks rpath to
# point back at Contents/Frameworks from that location.
/usr/bin/install_name_tool \
  -rpath "@executable_path/../Frameworks" "@executable_path/../../Frameworks" \
  "$OUTPUT_PATH"
