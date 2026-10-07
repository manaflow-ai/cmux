#!/bin/sh
# Rebuilds the committed web bundles from the current sources and stages
# them: the agent pane, Agent Activity page, the React pages, and the webviews app. Run it after merging
# feat-cmux-next into a branch.
#
# .gitattributes routes the generated pages through the `cmux-generated-v1` merge
# driver, which keeps this branch's copy when both sides changed one (a
# minified bundle cannot be merged by lines). That copy is stale until this
# script runs; CI's `--check` steps fail on it until then. Nothing runs this
# automatically: a merge hook that builds the tree would execute whatever the
# merged branch contains.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
PANE="Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
APP="Resources/markdown-viewer/webviews-app"
PAGES="Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
RANKER="Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources/palette-ranker.js"
# Every strings table gen-strings.mjs writes from the xcstrings catalogs, the
# agent pane's included: its build only checks its table.
PAGE_STRINGS="webviews/src/**/generated/strings.json"

cd "$ROOT/webviews"
# The merge may have changed the lockfile; building with the branch's old
# node_modules produces a bundle that only matches on this machine.
bun install --frozen-lockfile
node scripts/pages/gen-strings.mjs
cd "$ROOT"
"$ROOT/scripts/cmux-next/build-agent-pane-web.sh"
"$ROOT/scripts/cmux-next/build-palette-ranker.sh"
"$ROOT/scripts/cmux-next/build-agent-activity-web.sh"
"$ROOT/scripts/build-webviews-app.sh"
"$ROOT/scripts/cmux-next/build-pages-web.sh"
# -A also stages chunks the new build dropped, which resolves a delete/modify
# conflict the driver cannot.
ACTIVITY="Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity"
git add -A -- "$PANE" "$ACTIVITY" "$APP" "$PAGES" "$RANKER" ":(glob)$PAGE_STRINGS"
git status --short -- "$PANE" "$ACTIVITY" "$APP" "$PAGES" "$RANKER" ":(glob)$PAGE_STRINGS"
