#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_SOURCE="$ROOT/Resources/computer-use-mcp/cmux-computer-use-mcp.mjs"
OUTPUT=""
SOURCE_OUTPUT=""
ARCHS_RAW=""
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

usage() {
  cat <<'USAGE' >&2
usage: scripts/build-computer-use-provider.sh --output <path> [options]

Options:
  --source <path>              write the extracted Swift source to this path
  --archs "<archs>"            architectures to build (default: host arch)
  --deployment-target <value>  macOS deployment target (default: env or 13.0)
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
      SOURCE_OUTPUT="$2"
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

TMPDIR_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cu-provider.XXXXXX")"
cleanup() {
  rm -rf "$TMPDIR_BUILD"
}
trap cleanup EXIT

if [[ -z "$SOURCE_OUTPUT" ]]; then
  SOURCE_OUTPUT="$TMPDIR_BUILD/provider.swift"
fi
mkdir -p "$(dirname "$SOURCE_OUTPUT")" "$(dirname "$OUTPUT")"

node - "$MCP_SOURCE" "$SOURCE_OUTPUT" <<'NODE'
const fs = require("node:fs");
const vm = require("node:vm");

const sourcePath = process.argv[2];
const outputPath = process.argv[3];
const source = fs.readFileSync(sourcePath, "utf8");
const match = /const\s+MAC_PROVIDER_SWIFT\s*=\s*`/.exec(source);
if (!match) {
  throw new Error("MAC_PROVIDER_SWIFT template literal not found");
}
const literalStart = match.index + match[0].lastIndexOf("`");
let escaped = false;
let end = -1;
for (let i = literalStart + 1; i < source.length; i += 1) {
  const ch = source[i];
  if (escaped) {
    escaped = false;
    continue;
  }
  if (ch === "\\") {
    escaped = true;
    continue;
  }
  if (ch === "`") {
    end = i;
    break;
  }
}
if (end < 0) {
  throw new Error("MAC_PROVIDER_SWIFT template literal was not terminated");
}
const literal = source.slice(literalStart, end + 1);
if (literal.includes("${")) {
  throw new Error("MAC_PROVIDER_SWIFT must stay a plain template literal without interpolation");
}
const swift = vm.runInNewContext(literal, Object.freeze({}), { timeout: 1000 });
fs.writeFileSync(outputPath, swift, "utf8");
NODE

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
    "$SOURCE_OUTPUT" \
    -o "$arch_output"
  BUILT+=("$arch_output")
done

if ((${#BUILT[@]} == 1)); then
  cp "${BUILT[0]}" "$OUTPUT"
else
  /usr/bin/lipo -create "${BUILT[@]}" -output "$OUTPUT"
fi
chmod 0755 "$OUTPUT"
