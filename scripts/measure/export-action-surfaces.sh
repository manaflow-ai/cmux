#!/usr/bin/env bash
# Regenerates plans/cmux-next/action-surfaces.json and actions.md, then the
# docs copy web/data/cmux-shortcuts.generated.json, on a fleet step (never on
# a laptop), and prints them base64 between BEGIN/END markers:
#   cmux-ci run --class exclusive --script scripts/measure/export-action-surfaces.sh --ref <sha> [--arg=--catalog-only]
set -euo pipefail
# Fleet steps run with a short PATH; look where bun installs too.
BUN="$(command -v bun || true)"
for candidate in "$HOME/.bun/bin/bun" /opt/homebrew/bin/bun /usr/local/bin/bun; do
  [[ -n "$BUN" ]] && break
  [[ -x "$candidate" ]] && BUN="$candidate"
done
# `--catalog-only` (cmux-ci run --arg=--catalog-only) is the explicit way to
# export only the catalog; then run `bun web/scripts/export-docs-shortcuts.ts`
# where bun is.
if [[ "${1:-}" == "--catalog-only" ]]; then
  echo "export-action-surfaces: NOT regenerating web/data/cmux-shortcuts.generated.json (--catalog-only);" >&2
  echo "run bun web/scripts/export-docs-shortcuts.ts before landing, or web/tests/docs-shortcuts.test.ts fails." >&2
  BUN=""
elif [[ -z "$BUN" ]]; then
  echo "export-action-surfaces: bun not found (PATH, ~/.bun/bin, /opt/homebrew/bin, /usr/local/bin); it regenerates" >&2
  echo "web/data/cmux-shortcuts.generated.json (DOCS-SHORTCUTS-FROM-CATALOG). Install bun on this worker." >&2
  exit 1
fi
export CMUX_UPDATE_ACTION_SURFACES=1
GHOSTTY_SHA="$(git rev-parse HEAD:ghostty)" ./scripts/download-prebuilt-ghosttykit.sh
scripts/cmux-next/prefix-ghosttykit-archives.sh GhosttyKit.xcframework
swift test --package-path Packages/macOS/CmuxNext --filter ActionSurfaceParityTests
files=(plans/cmux-next/action-surfaces.json plans/cmux-next/actions.md)
if [[ -n "$BUN" ]]; then
  "$BUN" web/scripts/export-docs-shortcuts.ts
  files+=(web/data/cmux-shortcuts.generated.json)
fi
for file in "${files[@]}"; do
  echo "BEGIN_ARTIFACT:$file"
  base64 < "$file" | tr -d '\n'
  echo
  echo "END_ARTIFACT:$file"
done
