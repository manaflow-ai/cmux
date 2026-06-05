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
ZIG_REQUIRED="${ZIG_REQUIRED:-0.15.2}"

OUTPUT_PATH=""
TARGET_TRIPLE=""
UNIVERSAL="false"

zig_binary_arch() {
  local zig_path="$1"
  file "$zig_path" 2>/dev/null | grep -oE '(arm64|x86_64)' | head -1 || true
}

target_arch_for_triple() {
  case "${1:-}" in
    aarch64-macos) echo "arm64" ;;
    x86_64-macos) echo "x86_64" ;;
  esac
}

# Real host arch, accounting for Rosetta where `uname -m` reports x86_64 on
# Apple Silicon. Used so the default single-arch stub targets the true host.
detected_host_arch() {
  local host_arch=""
  case "$(uname -m)" in
    arm64 | aarch64) host_arch="arm64" ;;
    x86_64) host_arch="x86_64" ;;
  esac
  if [[ "$host_arch" == "x86_64" && "$(sysctl -in hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]]; then
    host_arch="arm64"
  fi
  echo "$host_arch"
}

zig_has_required_version() {
  local zig_path="$1"
  [[ -x "$zig_path" ]] || return 1
  [[ "$("$zig_path" version 2>/dev/null || true)" == "$ZIG_REQUIRED" ]]
}

select_zig_for_target() {
  local target="${1:-}"
  local desired_arch
  desired_arch="$(target_arch_for_triple "$target")"
  local host_arch
  host_arch="$(detected_host_arch)"

  if [[ -n "${CMUX_ZIG:-}" ]]; then
    if [[ ! -x "$CMUX_ZIG" ]]; then
      echo "error: CMUX_ZIG is not executable: $CMUX_ZIG" >&2
      return 1
    fi
    if ! zig_has_required_version "$CMUX_ZIG"; then
      echo "error: CMUX_ZIG must be zig ${ZIG_REQUIRED}: $CMUX_ZIG" >&2
      return 1
    fi
    echo "$CMUX_ZIG"
    return 0
  fi

  local -a candidates=()
  # Prefer Apple Silicon Homebrew Zig on macOS runners. Some CI shells expose
  # /usr/local/bin first or run under Rosetta, but the x86_64 Zig link path can
  # fail against newer macOS SDKs while arm64 Zig cross-compiles both slices.
  candidates+=("/opt/homebrew/bin/zig")
  local path_zig=""
  path_zig="$(command -v zig 2>/dev/null || true)"
  [[ -n "$path_zig" ]] && candidates+=("$path_zig")
  candidates+=("/usr/local/bin/zig")

  local fallback=""
  local host_match=""
  local desired_match=""
  local apple_silicon_match=""
  local seen=" "
  local candidate=""
  local canonical=""
  local arch=""
  for candidate in "${candidates[@]}"; do
    [[ -x "$candidate" ]] || continue
    canonical="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
    [[ "$seen" == *" $canonical "* ]] && continue
    seen="${seen}${canonical} "
    zig_has_required_version "$canonical" || continue
    [[ -z "$fallback" ]] && fallback="$canonical"
    arch="$(zig_binary_arch "$canonical")"
    if [[ -z "$apple_silicon_match" && "$arch" == "arm64" ]]; then
      apple_silicon_match="$canonical"
    fi
    if [[ -n "$host_arch" && -z "$host_match" && "$arch" == "$host_arch" ]]; then
      host_match="$canonical"
    fi
    if [[ -n "$desired_arch" && -z "$desired_match" && "$arch" == "$desired_arch" ]]; then
      desired_match="$canonical"
    fi
  done

  # Prefer the arm64 Zig when it exists because it can cross-compile the x86_64
  # helper slice and avoids Rosetta linker failures on macOS CI runners.
  if [[ -n "$apple_silicon_match" ]]; then
    echo "$apple_silicon_match"
    return 0
  fi

  if [[ -n "$desired_match" ]]; then
    echo "$desired_match"
    return 0
  fi

  if [[ -n "$host_match" ]]; then
    echo "$host_match"
    return 0
  fi

  if [[ -n "$fallback" ]]; then
    echo "$fallback"
    return 0
  fi

  echo "error: zig ${ZIG_REQUIRED} is required to build the Ghostty CLI helper" >&2
  return 1
}

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

write_macho_stub() {
  local output="$1"
  local clang_target="$2"
  local tmp_dir="$3"
  local source="$tmp_dir/ghostty-stub.c"
  cat > "$source" <<'EOF'
#include <stdio.h>

int main(int argc, char **argv) {
  (void)argc;
  (void)argv;
  fputs("ghostty CLI helper stub (zig build skipped)\n", stderr);
  return 1;
}
EOF
  xcrun clang -target "$clang_target" -mmacosx-version-min=14.0 "$source" -o "$output"
}

# Allow CI to skip the Zig helper build where only a valid app bundle shape is
# required. The stub is a Mach-O binary so architecture validation still checks
# the bundle layout and slices instead of accepting a shell script placeholder.
if [[ "${CMUX_SKIP_ZIG_BUILD:-}" == "1" ]]; then
  echo "Skipping zig CLI helper build (CMUX_SKIP_ZIG_BUILD=1)"
  mkdir -p "$(dirname "$OUTPUT_PATH")"
  STUB_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ghostty-helper-stub.XXXXXX")"
  trap 'rm -rf "$STUB_TMP_DIR"' EXIT
  if [[ "$UNIVERSAL" == "true" ]]; then
    write_macho_stub "$STUB_TMP_DIR/ghostty-arm64" "arm64-apple-macos14" "$STUB_TMP_DIR"
    write_macho_stub "$STUB_TMP_DIR/ghostty-x86_64" "x86_64-apple-macos14" "$STUB_TMP_DIR"
    /usr/bin/lipo -create "$STUB_TMP_DIR/ghostty-arm64" "$STUB_TMP_DIR/ghostty-x86_64" -output "$OUTPUT_PATH"
  else
    case "$TARGET_TRIPLE" in
      aarch64-macos) write_macho_stub "$OUTPUT_PATH" "arm64-apple-macos14" "$STUB_TMP_DIR" ;;
      x86_64-macos) write_macho_stub "$OUTPUT_PATH" "x86_64-apple-macos14" "$STUB_TMP_DIR" ;;
      *) write_macho_stub "$OUTPUT_PATH" "$(detected_host_arch)-apple-macos14" "$STUB_TMP_DIR" ;;
    esac
  fi
  chmod +x "$OUTPUT_PATH"
  exit 0
fi

if [[ ! -f "$GHOSTTY_DIR/build.zig" ]]; then
  echo "error: Ghostty submodule is missing at $GHOSTTY_DIR" >&2
  exit 1
fi

build_helper() {
  local prefix="$1"
  local target="${2:-}"
  local zig_bin
  if ! zig_bin="$(select_zig_for_target "$target")"; then
    exit 1
  fi
  local zig_arch
  zig_arch="$(zig_binary_arch "$zig_bin")"
  local desired_arch
  desired_arch="$(target_arch_for_triple "$target")"
  local effective_target="$target"
  if [[ -n "$desired_arch" && "$zig_arch" == "$desired_arch" ]]; then
    # Native compilation avoids Zig 0.15.x cross-linker failures against newer
    # macOS SDKs while still producing the requested helper architecture.
    effective_target=""
  fi

  local args=(
    "$zig_bin"
    build
    cli-helper
    -Dapp-runtime=none
    -Dcrash-report-subdir=cmux/crash
    -Demit-macos-app=false
    -Demit-xcframework=false
    -Doptimize=ReleaseFast
    --prefix
    "$prefix"
  )

  if [[ -n "$effective_target" ]]; then
    args+=("-Dtarget=$effective_target")
  fi

  echo "Building Ghostty CLI helper with $zig_bin${target:+ for $target}"
  (
    cd "$GHOSTTY_DIR"
    # Zig 0.15.x treats SDKROOT as a sysroot override. Xcode exports SDKROOT to
    # the macOS SDK, which makes Zig look for SDK paths under that SDK again and
    # leaves build-runner binaries unlinked against libSystem on a cold cache.
    env -u SDKROOT "${args[@]}"
  )
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ghostty-helper.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$(dirname "$OUTPUT_PATH")"

if [[ "$UNIVERSAL" == "true" ]]; then
  ARM64_PREFIX="$TMP_DIR/arm64"
  X86_PREFIX="$TMP_DIR/x86_64"
  NATIVE_ZIG="$(select_zig_for_target "")"
  ZIG_ARCH="$(zig_binary_arch "$NATIVE_ZIG")"
  if [[ "$ZIG_ARCH" == "arm64" ]]; then
    build_helper "$ARM64_PREFIX" ""
    build_helper "$X86_PREFIX" "x86_64-macos"
  elif [[ "$ZIG_ARCH" == "x86_64" ]]; then
    build_helper "$ARM64_PREFIX" "aarch64-macos"
    build_helper "$X86_PREFIX" ""
  else
    build_helper "$ARM64_PREFIX" "aarch64-macos"
    build_helper "$X86_PREFIX" "x86_64-macos"
  fi
  /usr/bin/lipo -create \
    "$ARM64_PREFIX/bin/ghostty" \
    "$X86_PREFIX/bin/ghostty" \
    -output "$OUTPUT_PATH"
else
  SINGLE_PREFIX="$TMP_DIR/single"
  build_helper "$SINGLE_PREFIX" "$TARGET_TRIPLE"
  install -m 755 "$SINGLE_PREFIX/bin/ghostty" "$OUTPUT_PATH"
fi

chmod +x "$OUTPUT_PATH"
