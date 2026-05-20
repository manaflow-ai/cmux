#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_REACT="$ROOT/Resources/agent-session-react"
OUT_SOLID="$ROOT/Resources/agent-session-solid"

if ! command -v bun >/dev/null 2>&1; then
  echo "error: bun is required to build AgentSessionWeb" >&2
  exit 1
fi

rm -rf "$OUT_REACT" "$OUT_SOLID"
mkdir -p "$OUT_REACT/assets" "$OUT_SOLID/assets"

bun build "$ROOT/AgentSessionWeb/src/react/main.ts" \
  --target browser \
  --format esm \
  --minify \
  --outfile "$OUT_REACT/assets/app.js"

bun build "$ROOT/AgentSessionWeb/src/solid/main.ts" \
  --target browser \
  --format esm \
  --minify \
  --outfile "$OUT_SOLID/assets/app.js"

cp "$ROOT/AgentSessionWeb/src/shared/styles.css" "$OUT_REACT/assets/styles.css"
cp "$ROOT/AgentSessionWeb/src/shared/styles.css" "$OUT_SOLID/assets/styles.css"
cp "$ROOT/AgentSessionWeb/src/index.html" "$OUT_REACT/index.html"
cp "$ROOT/AgentSessionWeb/src/index.html" "$OUT_SOLID/index.html"
