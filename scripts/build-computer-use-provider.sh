#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_INPUTS=()
OUTPUT=""
ARCHS_RAW=""
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
REQUIRE_MCP_PARENT=0

usage() {
  cat <<'USAGE' >&2
usage: scripts/build-computer-use-provider.sh --output <path> [options]

Options:
  --source <path>              Swift provider source file or directory; repeatable
  --archs "<archs>"            architectures to build (default: host arch)
  --deployment-target <value>  macOS deployment target (default: env or 13.0)
  --require-mcp-parent         require the bundled MCP server as the provider parent
USAGE
}

while (($#)); do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      OUTPUT="$2"
      shift 2
      ;;
    --source)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      SOURCE_INPUTS+=("$2")
      shift 2
      ;;
    --archs)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      ARCHS_RAW="$2"
      shift 2
      ;;
    --deployment-target)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      DEPLOYMENT_TARGET="$2"
      shift 2
      ;;
    --require-mcp-parent)
      REQUIRE_MCP_PARENT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$OUTPUT" ]]; then
  echo "error: --output is required" >&2
  usage
  exit 2
fi

if ((${#SOURCE_INPUTS[@]} == 0)); then
  SOURCE_INPUTS=(
    "$ROOT/Resources/computer-use-mcp/cmux-computer-use-provider-support.swift"
    "$ROOT/Resources/computer-use-mcp/main.swift"
  )
fi

SOURCE_FILES=()
for source_input in "${SOURCE_INPUTS[@]}"; do
  if [[ -d "$source_input" ]]; then
    while IFS= read -r source_file; do
      SOURCE_FILES+=("$source_file")
    done < <(find "$source_input" -maxdepth 1 -type f -name '*.swift' | sort)
  elif [[ -f "$source_input" ]]; then
    SOURCE_FILES+=("$source_input")
  else
    echo "error: Swift provider source not found at $source_input" >&2
    exit 1
  fi
done

if ((${#SOURCE_FILES[@]} == 0)); then
  echo "error: no Swift provider sources found" >&2
  exit 1
fi

TMPDIR_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cu-provider.XXXXXX")"
cleanup() {
  rm -rf "$TMPDIR_BUILD"
}
trap cleanup EXIT

mkdir -p "$(dirname "$OUTPUT")"

if [[ -z "$ARCHS_RAW" ]]; then
  case "$(uname -m)" in
    arm64|aarch64) ARCHS_RAW="arm64" ;;
    x86_64|amd64) ARCHS_RAW="x86_64" ;;
    *) ARCHS_RAW="$(uname -m)" ;;
  esac
fi

read -r -a ARCHS <<<"$ARCHS_RAW"
if ((${#ARCHS[@]} == 0)); then
  echo "error: no architectures requested" >&2
  exit 1
fi

SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
BUILT=()
SWIFT_FLAGS=()
if [[ "$REQUIRE_MCP_PARENT" -eq 1 ]]; then
  SWIFT_FLAGS+=("-D" "CMUX_REQUIRE_MCP_PARENT")
fi
for arch in "${ARCHS[@]}"; do
  case "$arch" in
    arm64|aarch64)
      arch="arm64"
      target="arm64-apple-macosx${DEPLOYMENT_TARGET}"
      ;;
    x86_64|amd64)
      arch="x86_64"
      target="x86_64-apple-macosx${DEPLOYMENT_TARGET}"
      ;;
    *)
      echo "error: unsupported architecture: $arch" >&2
      exit 1
      ;;
  esac
  arch_output="$TMPDIR_BUILD/cmux-computer-use-provider-$arch"
  /usr/bin/swiftc \
    -O \
    -warnings-as-errors \
    -sdk "$SDK_PATH" \
    -target "$target" \
    "${SWIFT_FLAGS[@]}" \
    "${SOURCE_FILES[@]}" \
    -o "$arch_output"
  BUILT+=("$arch_output")
done

if ((${#BUILT[@]} == 1)); then
  cp "${BUILT[0]}" "$OUTPUT"
else
  /usr/bin/lipo -create "${BUILT[@]}" -output "$OUTPUT"
fi
chmod 0755 "$OUTPUT"

# lipo does not preserve a valid linker signature on the assembled universal
# executable. Seal the final bytes here; Developer ID release signing replaces
# this ad-hoc signature later in scripts/sign-cmux-bundle.sh.
/usr/bin/codesign --force --sign - --timestamp=none "$OUTPUT"
/usr/bin/codesign --verify --strict "$OUTPUT"
