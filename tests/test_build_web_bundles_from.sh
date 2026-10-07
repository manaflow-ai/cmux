#!/usr/bin/env bash
# build-web-bundles.sh --from DIR installs bundles that were built elsewhere for the same
# source key (cmux-next.yml's Linux web-bundles job caches them by that key) and stamps them,
# so a Mac job that restores them skips the build. A tree missing a bundle is refused and the
# checkout is left alone.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/cmux-next/build-web-bundles.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"

PANE="Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
PAGES="Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
ACTIVITY="Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity"
PALETTE="Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources/palette-ranker.js"
APP="Resources/markdown-viewer/webviews-app"

# A prebuilt tree: the committed bundles stand in for the cached build of this source key.
for path in "$PANE" "$PAGES" "$ACTIVITY" "$APP"; do
  mkdir -p "$WORK/out/$(dirname "$path")"
  cp -R "$path" "$WORK/out/$path"
done
mkdir -p "$WORK/out/$(dirname "$PALETTE")"
cp "$PALETTE" "$WORK/out/$PALETTE"

rm -f .web-bundles.key
"$SCRIPT" --from "$WORK/out" > "$WORK/log" 2>&1 || { cat "$WORK/log"; echo "FAIL: --from must install a complete prebuilt tree"; exit 1; }
"$SCRIPT" --verify > /dev/null 2>&1 || { echo "FAIL: after --from the bundles must be current without a build"; exit 1; }
git diff --quiet -- "$PANE" "$PAGES" "$ACTIVITY" "$PALETTE" "$APP" \
  || { echo "FAIL: --from changed the committed bundles"; exit 1; }

rm -rf "$WORK/out/$PAGES"
rm -f .web-bundles.key
if "$SCRIPT" --from "$WORK/out" > "$WORK/log" 2>&1; then
  echo "FAIL: --from must refuse a tree that is missing a bundle"; exit 1
fi
[ -d "$PAGES" ] || { echo "FAIL: a refused --from must leave the checkout's bundles alone"; exit 1; }
[ ! -f .web-bundles.key ] || { echo "FAIL: a refused --from must not stamp the bundles current"; exit 1; }

echo "PASS: build-web-bundles.sh --from installs and stamps a prebuilt tree, and refuses an incomplete one"
