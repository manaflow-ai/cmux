#!/usr/bin/env bash
# build-web-bundles.sh --from DIR installs bundles that were built elsewhere for the same
# source key (cmux-next.yml's Linux web-bundles job caches them by that key) and stamps them,
# so a Mac job that restores them skips the build. A tree missing a bundle is refused and the
# checkout is left alone. The committed inspector page is never replaced, and a prebuilt tree whose
# generated inspector page differs from it is refused, as an in-tree build refuses it.
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
# The source key reads the declared bun version from webviews/package.json (#27680).
mkdir -p "$REPO/webviews"
cp "$ROOT/webviews/package.json" "$REPO/webviews/package.json"
git -C "$REPO" init -q
# web-bundle-key.py reads the declared bun version from webviews/package.json.
mkdir -p "$REPO/webviews"
cp "$ROOT/webviews/package.json" "$REPO/webviews/"
git -C "$REPO" add webviews/package.json

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

# A commit keeps a GENERATED.md note in the pane, pages and activity directories, and the app
# bundles it; an --out-root build writes none, so --from must keep the checkout's.
for path in "$PANE" "$PAGES" "$ACTIVITY"; do
  mkdir -p "$REPO/$path"
  printf 'generated: %s\n' "$path" > "$REPO/$path/GENERATED.md"
  printf 'stale build output\n' > "$REPO/$path/stale.js"
done
git -C "$REPO" add -f "$PANE/GENERATED.md" "$PAGES/GENERATED.md" "$ACTIVITY/GENERATED.md"

# A prebuilt tree for this source key, as the Linux web-bundles job caches it. Its inspector
# page is the one it generated, which matches the committed page while that is current.
for path in "$PANE" "$PAGES" "$ACTIVITY" "$APP"; do
  mkdir -p "$WORK/out/$path"
  printf '<!doctype html><title>%s</title>\n' "$path" > "$WORK/out/$path/index.html"
done
mkdir -p "$WORK/out/$INSPECTOR"
cp "$REPO/$INSPECTOR/index.html" "$WORK/out/$INSPECTOR/index.html"
mkdir -p "$WORK/out/$(dirname "$PALETTE")"
printf 'export const rank = () => 0;\n' > "$WORK/out/$PALETTE"

"$SCRIPT" --from "$WORK/out" > "$WORK/log" 2>&1 || { cat "$WORK/log"; echo "FAIL: --from must install a complete prebuilt tree"; exit 1; }
"$SCRIPT" --verify > /dev/null 2>&1 || { echo "FAIL: after --from the bundles must be current without a build"; exit 1; }
for path in "$PANE" "$PAGES" "$ACTIVITY" "$APP"; do
  diff -r -x GENERATED.md "$WORK/out/$path" "$REPO/$path" > /dev/null || { echo "FAIL: --from did not install $path as built"; exit 1; }
done
grep -q "committed inspector" "$REPO/$INSPECTOR/index.html" || { echo "FAIL: --from must leave the committed inspector page alone"; exit 1; }
cmp -s "$WORK/out/$PALETTE" "$REPO/$PALETTE" || { echo "FAIL: --from did not install $PALETTE as built"; exit 1; }
for path in "$PANE" "$PAGES" "$ACTIVITY"; do
  grep -qx "generated: $path" "$REPO/$path/GENERATED.md" || { echo "FAIL: --from must keep the committed $path/GENERATED.md"; exit 1; }
  [ ! -e "$REPO/$path/stale.js" ] || { echo "FAIL: --from must drop build output the prebuilt tree does not hold ($path/stale.js)"; exit 1; }
done

# Exercise the nightly producer and the real installer together: a handoff must
# include every file --from needs, including the checked-in inspector page.
mkdir -p "$REPO/scripts/ci"
cp "$ROOT/scripts/ci/nightly_inputs.py" "$REPO/scripts/ci/"
git -C "$REPO" add scripts "$INSPECTOR/index.html"
git -C "$REPO" -c core.hooksPath=/dev/null -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
key="$(python3 "$REPO/scripts/cmux-next/web-bundle-key.py" "$REPO" --source)"
python3 "$REPO/scripts/ci/nightly_inputs.py" pack-web "$WORK/handoff" --source-key "$key"
python3 "$REPO/scripts/ci/nightly_inputs.py" install-web "$WORK/handoff"
"$SCRIPT" --verify
# A changed source must miss instead of installing yesterday's bundles.
printf '\n# changed input\n' >> "$REPO/scripts/cmux-next/build-web-bundles.sh"
status=0
python3 "$REPO/scripts/ci/nightly_inputs.py" install-web "$WORK/handoff" || status=$?
[ "$status" = 3 ] || { echo "FAIL: changed inputs must refuse a handoff"; exit 1; }
git -C "$REPO" checkout -- scripts/cmux-next/build-web-bundles.sh

# A committed inspector page that differs from the one generated for this source key is stale:
# an in-tree build refuses it (build-optchat-inspector-web.sh --check), and so must --from.
cp -R "$WORK/out" "$WORK/stale"
printf '<!doctype html><title>regenerated inspector</title>\n' > "$WORK/stale/$INSPECTOR/index.html"
rm -f "$REPO/.web-bundles.key"
if "$SCRIPT" --from "$WORK/stale" > "$WORK/log" 2>&1; then
  echo "FAIL: --from must refuse a tree whose inspector page differs from the committed one"; exit 1
fi
grep -q "generated file is stale" "$WORK/log" || { cat "$WORK/log"; echo "FAIL: a stale inspector page must be named"; exit 1; }
[ ! -f "$REPO/.web-bundles.key" ] || { echo "FAIL: a stale inspector page must not stamp the bundles current"; exit 1; }
grep -q "committed inspector" "$REPO/$INSPECTOR/index.html" || { echo "FAIL: a refused --from must leave the committed inspector page alone"; exit 1; }

rm -rf "$WORK/out/$PAGES"
rm -f "$REPO/.web-bundles.key"
if "$SCRIPT" --from "$WORK/out" > "$WORK/log" 2>&1; then
  echo "FAIL: --from must refuse a tree that is missing a bundle"; exit 1
fi
[ -f "$REPO/$PAGES/index.html" ] || { echo "FAIL: a refused --from must leave the checkout's bundles alone"; exit 1; }
[ ! -f "$REPO/.web-bundles.key" ] || { echo "FAIL: a refused --from must not stamp the bundles current"; exit 1; }

# A copy that fails after the checkout's build output was cleared must still leave the
# committed notes in place, so the fallback build ships them. The failure is a directory in
# the prebuilt tree where the checkout tracks a file: cp cannot replace a file with a
# directory, for root too (unlike an unreadable file).
cp -R "$WORK/out" "$WORK/conflict"
mkdir -p "$WORK/conflict/$PAGES/conflict"
printf 'x\n' > "$WORK/conflict/$PAGES/conflict/inner.js"
printf 'tracked file\n' > "$REPO/$PAGES/conflict"
git -C "$REPO" add -f "$PAGES/conflict"
rm -f "$REPO/.web-bundles.key"
if "$SCRIPT" --from "$WORK/conflict" > "$WORK/log" 2>&1; then
  echo "FAIL: --from must fail when the prebuilt tree cannot be copied"; exit 1
fi
for path in "$PANE" "$PAGES" "$ACTIVITY"; do
  grep -qx "generated: $path" "$REPO/$path/GENERATED.md" || { echo "FAIL: a failed copy must keep the committed $path/GENERATED.md"; exit 1; }
done
[ ! -f "$REPO/.web-bundles.key" ] || { echo "FAIL: a failed copy must not stamp the bundles current"; exit 1; }

echo "PASS: build-web-bundles.sh --from installs and stamps a prebuilt tree, and refuses an incomplete one or a stale inspector page, and keeps committed files"
