#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: build-cmux-size-tui.sh --output <path>

Builds the bundled Rust cmux-size-tui helper.
USAGE
}

OUTPUT_PATH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      if [ "$#" -lt 2 ]; then
        echo "error: --output requires a path" >&2
        exit 1
      fi
      OUTPUT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$OUTPUT_PATH" ]; then
  echo "error: --output is required" >&2
  usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCROOT="${SRCROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SOURCE_PATH="${SRCROOT}/Resources/cmux-size-tui/main.rs"
RUSTC="${RUSTC:-$(command -v rustc || true)}"

if [ ! -f "$SOURCE_PATH" ]; then
  echo "error: missing Rust source at $SOURCE_PATH" >&2
  exit 1
fi

if [ -z "$RUSTC" ]; then
  echo "error: rustc is required to build cmux-size-tui" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
"$RUSTC" --edition=2021 -C opt-level=2 "$SOURCE_PATH" -o "$OUTPUT_PATH"
chmod 755 "$OUTPUT_PATH"
