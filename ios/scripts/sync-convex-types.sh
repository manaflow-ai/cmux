#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SOURCE_ROOT="$HOME/fun/cmux"
OUT_FILE="$IOS_ROOT/Sources/Generated/ConvexApiTypes.swift"

usage() {
    cat <<'EOF'
Usage:
  ./scripts/sync-convex-types.sh [--source-root <path>] [--out <path>]

Generates iOS Convex API Swift types using the Convex schema from the cmux web
repo and writes them into this iOS app.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-root)
            SOURCE_ROOT="$2"
            shift 2
            ;;
        --out)
            OUT_FILE="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if ! command -v bun >/dev/null 2>&1; then
    echo "bun is required to generate Convex Swift types" >&2
    exit 1
fi

if [[ ! -d "$SOURCE_ROOT" ]]; then
    echo "Missing source root: $SOURCE_ROOT" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"

(
    cd "$SOURCE_ROOT"
    bun run gen:swift-api-types -- --out="$OUT_FILE" --no-format
)

echo "Updated $OUT_FILE from $SOURCE_ROOT/packages/convex"
