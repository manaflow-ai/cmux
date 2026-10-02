#!/bin/sh
# Rebuilds the two committed web bundles from the current sources and stages
# them: the agent pane page (scripts/cmux-next/build-agent-pane-web.sh) and the
# webviews app (scripts/build-webviews-app.sh). Run it after merging
# feat-cmux-next into a branch.
#
# .gitattributes routes both bundles through the `cmux-generated-v1` merge
# driver, which keeps this branch's copy when both sides changed one (a
# minified bundle cannot be merged by lines). That copy is stale until this
# script runs; CI's `--check` steps fail on it until then. Nothing runs this
# automatically: a merge hook that builds the tree would execute whatever the
# merged branch contains.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
PANE="Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
APP="Resources/markdown-viewer/webviews-app"

cd "$ROOT/webviews"
# The merge may have changed the lockfile; building with the branch's old
# node_modules produces a bundle that only matches on this machine.
bun install --frozen-lockfile
cd "$ROOT"
"$ROOT/scripts/cmux-next/build-agent-pane-web.sh"
"$ROOT/scripts/build-webviews-app.sh"
# -A also stages chunks the new build dropped, which resolves a delete/modify
# conflict the driver cannot.
git add -A -- "$PANE" "$APP"
git status --short -- "$PANE" "$APP"
