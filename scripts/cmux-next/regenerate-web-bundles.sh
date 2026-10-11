#!/bin/sh
# Rebuilds the generated files that are still committed and stages them, after
# merging feat-cmux-next (or main) into a branch, or after editing their inputs:
# the strings tables (webviews/src/**/generated/, from the xcstrings catalogs)
# and the optchat memory inspector page. Build paths only check them
# (build-web-bundles.sh fails on a stale copy and never writes one).
#
# The web bundles (agent pane, pages, Agent Activity, palette ranker, webviews
# app) are build output since cx-vn5 and gitignored; every build path runs
# scripts/cmux-next/build-web-bundles.sh. A merge with a branch from before that
# change gets modify/delete conflicts on them. This resolves those by removing
# them from the index (`git rm --cached`; the deletion wins), which is also how
# a main -> feat-cmux-next sync resolves main's changes to
# Resources/markdown-viewer/webviews-app.
#
# .gitattributes routes the still-committed files through the
# `cmux-generated-v1` merge driver, which keeps this branch's copy when both
# sides changed one. That copy is stale until this script runs. Nothing runs
# this automatically: a merge hook that builds the tree would execute whatever
# the merged branch contains.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
INSPECTOR="Native/OptChat/optchat-chief/inspector/index.html"
# The build outputs that were committed before cx-vn5. Only their placeholders
# (GENERATED.md) stay in the index.
FORMER="Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane
Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity
Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages
Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources/palette-ranker.js
Resources/markdown-viewer/webviews-app"

cd "$ROOT"
# shellcheck disable=SC2086 # FORMER is a newline-separated list of fixed paths.
stale="$(git ls-files -- $FORMER | grep -v '/GENERATED\.md$' || true)"
if [ -n "$stale" ]; then
  printf '%s\n' "$stale" | git rm -q --cached --pathspec-from-file=-
  echo "removed $(printf '%s\n' "$stale" | wc -l | tr -d ' ') former build outputs from the index"
fi

cd "$ROOT/webviews"
# The merge may have changed the lockfile; building with the branch's old
# node_modules produces output that only matches on this machine.
bun install --frozen-lockfile
bun scripts/pages/gen-strings.mjs
cd "$ROOT"
"$ROOT/scripts/cmux-next/build-optchat-inspector-web.sh"
git add -A -- ":(glob)webviews/src/**/generated/**" "$INSPECTOR"
git status --short -- ":(glob)webviews/src/**/generated/**" "$INSPECTOR"
