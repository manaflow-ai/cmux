#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_INPUT="$ROOT/Resources/computer-use-mcp/cmux-computer-use-mcp.mjs"
OUTPUT=""
ARCHS_RAW=""

usage() {
  cat <<'USAGE' >&2
usage: scripts/build-computer-use-mcp-server.sh --output <path> [options]

Options:
  --source <path>    MCP server source (default: bundled resource)
  --archs "<archs>"  architectures to build (default: host arch)
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
      SOURCE_INPUT="$2"
      shift 2
      ;;
    --archs)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      ARCHS_RAW="$2"
      shift 2
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
if [[ ! -f "$SOURCE_INPUT" ]]; then
  echo "error: MCP server source not found at $SOURCE_INPUT" >&2
  exit 1
fi

BUN_BIN="${BUN_BIN:-}"
if [[ -z "$BUN_BIN" ]]; then
  BUN_BIN="$(command -v bun 2>/dev/null || true)"
fi
if [[ -z "$BUN_BIN" || ! -x "$BUN_BIN" ]]; then
  echo "error: bun is required to build the bundled cmux computer-use MCP server" >&2
  exit 1
fi

TMPDIR_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cu-mcp.XXXXXX")"
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

BUILT=()
for arch in "${ARCHS[@]}"; do
  case "$arch" in
    arm64|aarch64)
      arch="arm64"
      bun_target="bun-darwin-arm64"
      ;;
    x86_64|amd64)
      arch="x86_64"
      bun_target="bun-darwin-x64-baseline"
      ;;
    *)
      echo "error: unsupported architecture: $arch" >&2
      exit 1
      ;;
  esac
  arch_output="$TMPDIR_BUILD/cmux-computer-use-mcp-$arch"
  "$BUN_BIN" build \
    --compile \
    --target="$bun_target" \
    --no-compile-autoload-dotenv \
    --no-compile-autoload-bunfig \
    "$SOURCE_INPUT" \
    --outfile "$arch_output"
  BUILT+=("$arch_output")
done

if ((${#BUILT[@]} == 1)); then
  cp "${BUILT[0]}" "$OUTPUT"
else
  /usr/bin/lipo -create "${BUILT[@]}" -output "$OUTPUT"
fi
chmod 0755 "$OUTPUT"
