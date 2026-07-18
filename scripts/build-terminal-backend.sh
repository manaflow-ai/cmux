#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_PATH=""
RENDERER_OUTPUT_PATH=""
CONFIGURATION="release"
ARCHITECTURES=""
SIGN_IDENTITY="${CMUX_TERMINAL_BACKEND_SIGN_IDENTITY:--}"
SHOULD_SIGN=1
ENTITLEMENTS_PATH="$REPO_ROOT/Resources/cmux-terminal-backend.entitlements"
SIGNING_IDENTIFIER="com.cmuxterm.cmux-terminal-backend"
FINGERPRINT_TOOL="$REPO_ROOT/scripts/terminal-backend-build-fingerprint.py"
RENDERER_BUILD_TOOL="$REPO_ROOT/scripts/build-terminal-renderer.sh"
FINGERPRINT_STAMP=""
DEPENDENCY_FILE=""
PACKAGED_BUILD_ID_PATH=""

export PATH="${CARGO_HOME:-${HOME}/.cargo}/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

usage() {
  echo "Usage: ./scripts/build-terminal-backend.sh --output <path> [--renderer-output <path>] [--configuration debug|release] [--architectures \"arm64 x86_64\"] [--sign-identity <identity> | --skip-signing] [--entitlements <path>] [--fingerprint-stamp <path>] [--dependency-file <path>]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --renderer-output)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      RENDERER_OUTPUT_PATH="$2"
      shift 2
      ;;
    --configuration)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      CONFIGURATION="$2"
      shift 2
      ;;
    --architectures)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ARCHITECTURES="$2"
      shift 2
      ;;
    --sign-identity)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      SIGN_IDENTITY="$2"
      SHOULD_SIGN=1
      shift 2
      ;;
    --skip-signing)
      SHOULD_SIGN=0
      shift
      ;;
    --entitlements)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ENTITLEMENTS_PATH="$2"
      shift 2
      ;;
    --fingerprint-stamp)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      FINGERPRINT_STAMP="$2"
      shift 2
      ;;
    --dependency-file)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      DEPENDENCY_FILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$OUTPUT_PATH" ]] || { echo "error: --output is required" >&2; exit 2; }
RENDERER_OUTPUT_PATH="${RENDERER_OUTPUT_PATH:-$(dirname "$OUTPUT_PATH")/cmux-terminal-renderer}"
case "$CONFIGURATION" in
  debug|release) ;;
  *) echo "error: --configuration must be debug or release" >&2; exit 2 ;;
esac

ZIG_BIN="${ZIG:-/opt/homebrew/opt/zig@0.15/bin/zig}"
[[ -x "$ZIG_BIN" ]] || { echo "error: Zig 0.15 is required at $ZIG_BIN" >&2; exit 1; }
command -v cargo >/dev/null 2>&1 || { echo "error: cargo is required" >&2; exit 1; }
[[ -x "$FINGERPRINT_TOOL" ]] || { echo "error: build fingerprint tool is missing: $FINGERPRINT_TOOL" >&2; exit 1; }
[[ -x "$RENDERER_BUILD_TOOL" ]] || { echo "error: renderer build tool is missing: $RENDERER_BUILD_TOOL" >&2; exit 1; }
[[ -f "$ENTITLEMENTS_PATH" ]] || { echo "error: backend entitlements are missing: $ENTITLEMENTS_PATH" >&2; exit 1; }

ZIG_VERSION="$($ZIG_BIN version)"
RUST_VERSION="$(rustc -Vv)"
CARGO_VERSION="$(cargo -V)"
ENTITLEMENTS_HASH="$(/usr/bin/shasum -a 256 "$ENTITLEMENTS_PATH" | awk '{print $1}')"
FINGERPRINT_ARGS=(
  --root "$REPO_ROOT"
  --metadata "configuration=$CONFIGURATION"
  --metadata "architectures=${ARCHITECTURES:-$(uname -m)}"
  --metadata "deployment=${MACOSX_DEPLOYMENT_TARGET:-14.0}"
  --metadata "sign=$SHOULD_SIGN"
  --metadata "sign-identity=$SIGN_IDENTITY"
  --metadata "entitlements=$ENTITLEMENTS_HASH"
  --metadata "renderer-output=$(basename "$RENDERER_OUTPUT_PATH")"
  --metadata "zig=$ZIG_VERSION"
  --metadata "rust=$RUST_VERSION"
  --metadata "cargo=$CARGO_VERSION"
)
if [[ -n "$DEPENDENCY_FILE" ]]; then
  FINGERPRINT_ARGS+=(
    --dependency-file "$DEPENDENCY_FILE"
    --dependency-target "$OUTPUT_PATH"
  )
fi
FINGERPRINT="$($FINGERPRINT_TOOL "${FINGERPRINT_ARGS[@]}")"
FINGERPRINT_STAMP="${FINGERPRINT_STAMP:-${OUTPUT_PATH}.terminal-backend-fingerprint}"
PACKAGED_BUILD_ID_PATH="${OUTPUT_PATH}.build-id"
if [[ -x "$OUTPUT_PATH" && -x "$RENDERER_OUTPUT_PATH" && -f "$FINGERPRINT_STAMP" \
  && -f "$PACKAGED_BUILD_ID_PATH" ]] \
  && [[ "$(cat "$FINGERPRINT_STAMP")" == "$FINGERPRINT" ]] \
  && [[ "$(cat "$PACKAGED_BUILD_ID_PATH")" == "$FINGERPRINT" ]]; then
  if [[ "$SHOULD_SIGN" -eq 0 ]] \
    || { /usr/bin/codesign --verify --strict "$OUTPUT_PATH" >/dev/null 2>&1 \
      && /usr/bin/codesign --verify --strict "$RENDERER_OUTPUT_PATH" >/dev/null 2>&1; }; then
    echo "Reusing content-addressed terminal backend and renderer: $OUTPUT_PATH"
    exit 0
  fi
fi
rm -f "$FINGERPRINT_STAMP"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-terminal-backend.XXXXXX")"
cleanup() {
  case "$TEMP_DIR" in
    "${TMPDIR:-/tmp}"/cmux-terminal-backend.*) rm -rf "$TEMP_DIR" ;;
  esac
}
trap cleanup EXIT

PROFILE_ARGS=()
PROFILE_DIR="debug"
if [[ "$CONFIGURATION" == "release" ]]; then
  PROFILE_ARGS=(--release)
  PROFILE_DIR="release"
fi

build_target() {
  local target="$1"
  local destination="$2"
  if command -v rustup >/dev/null 2>&1 \
    && ! rustup target list --installed | grep -qx "$target"; then
    rustup target add "$target"
  fi
  env -u SDKROOT \
    ZIG="$ZIG_BIN" \
    CMUX_GHOSTTY_SRC="$REPO_ROOT/ghostty" \
    CMUX_TUI_BUILD_FINGERPRINT="$FINGERPRINT" \
    MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    cargo build \
      --manifest-path "$REPO_ROOT/cmux-tui/Cargo.toml" \
      --locked \
      -p cmux-tui \
      --bin cmux-tui \
      "${PROFILE_ARGS[@]}" \
      --target "$target"
  /usr/bin/install -m 0755 \
    "$REPO_ROOT/cmux-tui/target/$target/$PROFILE_DIR/cmux-tui" \
    "$destination"
}

mkdir -p "$(dirname "$OUTPUT_PATH")"
if [[ -z "$ARCHITECTURES" ]]; then
  env -u SDKROOT \
    ZIG="$ZIG_BIN" \
    CMUX_GHOSTTY_SRC="$REPO_ROOT/ghostty" \
    CMUX_TUI_BUILD_FINGERPRINT="$FINGERPRINT" \
    MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    cargo build \
      --manifest-path "$REPO_ROOT/cmux-tui/Cargo.toml" \
      --locked \
      -p cmux-tui \
      --bin cmux-tui \
      "${PROFILE_ARGS[@]}"
  /usr/bin/install -m 0755 \
    "$REPO_ROOT/cmux-tui/target/$PROFILE_DIR/cmux-tui" \
    "$OUTPUT_PATH"
else
  SLICES=()
  for architecture in $ARCHITECTURES; do
    case "$architecture" in
      arm64) target="aarch64-apple-darwin" ;;
      x86_64) target="x86_64-apple-darwin" ;;
      *) echo "error: unsupported architecture $architecture" >&2; exit 2 ;;
    esac
    slice="$TEMP_DIR/cmux-terminal-backend-$architecture"
    build_target "$target" "$slice"
    SLICES+=("$slice")
  done

  if [[ ${#SLICES[@]} -eq 1 ]]; then
    /usr/bin/install -m 0755 "${SLICES[0]}" "$OUTPUT_PATH"
  else
    /usr/bin/lipo -create "${SLICES[@]}" -output "$OUTPUT_PATH"
    chmod 0755 "$OUTPUT_PATH"
  fi
fi

if [[ "$SHOULD_SIGN" -eq 1 ]]; then
  /usr/bin/codesign \
    --force \
    --options runtime \
    --identifier "$SIGNING_IDENTIFIER" \
    --sign "$SIGN_IDENTITY" \
    --timestamp=none \
    --generate-entitlement-der \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$OUTPUT_PATH" >/dev/null
fi

RENDERER_BUILD_ARGS=(
  --output "$RENDERER_OUTPUT_PATH"
  --configuration "$CONFIGURATION"
  --architectures "$ARCHITECTURES"
  --entitlements "$ENTITLEMENTS_PATH"
)
if [[ "$SHOULD_SIGN" -eq 1 ]]; then
  RENDERER_BUILD_ARGS+=(--sign-identity "$SIGN_IDENTITY")
else
  RENDERER_BUILD_ARGS+=(--skip-signing)
fi
"$RENDERER_BUILD_TOOL" "${RENDERER_BUILD_ARGS[@]}"

BUILD_ID_TEMP="${PACKAGED_BUILD_ID_PATH}.tmp.$$"
printf '%s\n' "$FINGERPRINT" > "$BUILD_ID_TEMP"
chmod 0644 "$BUILD_ID_TEMP"
mv "$BUILD_ID_TEMP" "$PACKAGED_BUILD_ID_PATH"

STAMP_TEMP="${FINGERPRINT_STAMP}.tmp.$$"
mkdir -p "$(dirname "$FINGERPRINT_STAMP")"
printf '%s\n' "$FINGERPRINT" > "$STAMP_TEMP"
mv "$STAMP_TEMP" "$FINGERPRINT_STAMP"
