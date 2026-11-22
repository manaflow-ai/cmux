#!/usr/bin/env bash
# build-web-bundles.sh --from DIR installs bundles that were built elsewhere for the same
# source key (cmux-next.yml's Linux web-bundles job caches them by that key) and stamps them,
# so a Mac job that restores them skips the build. A tree missing a bundle is refused and the
# checkout is left alone. The committed inspector page is never replaced.
#
# The bundles are build output, not committed (41b907dce7b), so the test runs a copy of the
# script in a scratch repository with a synthetic prebuilt tree. It never touches this
# checkout's generated bundles or its .web-bundles.key.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO/scripts/cmux-next"
cp "$ROOT/scripts/cmux-next/build-web-bundles.sh" "$ROOT/scripts/cmux-next/web-bundle-key.py" "$REPO/scripts/cmux-next/"
SCRIPT="$REPO/scripts/cmux-next/build-web-bundles.sh"
git -C "$REPO" init -q

PANE="Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
PAGES="Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
ACTIVITY="Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity"
PALETTE="Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources/palette-ranker.js"
APP="Resources/markdown-viewer/webviews-app"
INSPECTOR="Native/OptChat/optchat-chief/inspector"

# The palette ranker lands in a Resources directory that holds tracked files in a checkout.
mkdir -p "$REPO/$(dirname "$PALETTE")"
# The inspector page is committed (2942c2304af1: optchat-chief compiles it in with include_str!),
# so --from must leave the checkout's copy alone, whatever the prebuilt tree holds.
mkdir -p "$REPO/$INSPECTOR"
printf '<!doctype html><title>committed inspector</title>\n' > "$REPO/$INSPECTOR/index.html"

# A prebuilt tree for this source key, as the Linux web-bundles job caches it.
for path in "$PANE" "$PAGES" "$ACTIVITY" "$APP" "$INSPECTOR"; do
  mkdir -p "$WORK/out/$path"
  printf '<!doctype html><title>%s</title>\n' "$path" > "$WORK/out/$path/index.html"
done
mkdir -p "$WORK/out/$(dirname "$PALETTE")"
printf 'export const rank = () => 0;\n' > "$WORK/out/$PALETTE"

"$SCRIPT" --from "$WORK/out" > "$WORK/log" 2>&1 || { cat "$WORK/log"; echo "FAIL: --from must install a complete prebuilt tree"; exit 1; }
"$SCRIPT" --verify > /dev/null 2>&1 || { echo "FAIL: after --from the bundles must be current without a build"; exit 1; }
for path in "$PANE" "$PAGES" "$ACTIVITY" "$APP"; do
  diff -r "$WORK/out/$path" "$REPO/$path" > /dev/null || { echo "FAIL: --from did not install $path as built"; exit 1; }
done
grep -q "committed inspector" "$REPO/$INSPECTOR/index.html" || { echo "FAIL: --from must leave the committed inspector page alone"; exit 1; }
cmp -s "$WORK/out/$PALETTE" "$REPO/$PALETTE" || { echo "FAIL: --from did not install $PALETTE as built"; exit 1; }

rm -rf "$WORK/out/$PAGES"
rm -f "$REPO/.web-bundles.key"
if "$SCRIPT" --from "$WORK/out" > "$WORK/log" 2>&1; then
  echo "FAIL: --from must refuse a tree that is missing a bundle"; exit 1
fi
[ -f "$REPO/$PAGES/index.html" ] || { echo "FAIL: a refused --from must leave the checkout's bundles alone"; exit 1; }
[ ! -f "$REPO/.web-bundles.key" ] || { echo "FAIL: a refused --from must not stamp the bundles current"; exit 1; }

echo "PASS: build-web-bundles.sh --from installs and stamps a prebuilt tree, and refuses an incomplete one"
