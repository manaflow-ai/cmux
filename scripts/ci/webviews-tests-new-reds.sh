#!/usr/bin/env bash
# Runs the webviews tests (run-webviews-tests.sh, from webviews/) and, given BASE, fails only on the
# tests this change turns red; a test red on BASE too is a warning (guards_new_reds.py).
#
#   ../scripts/ci/webviews-tests-new-reds.sh [BASE]
#
# About 25 browser tests were red on feat-cmux-next for every pull request, and #23090's 2 new reds
# (agent-pane-peer-chat, agent-pane-working-counts) landed unseen among them (2026-10-21). With BASE
# (a pull request's merge parent, HEAD^1), each file red on the head runs again, one at a time, in a
# BASE checkout with its own install and web bundles (and the same way on the head first), and the
# results compare per test name. No BASE (a
# push) keeps every red the job's, so a red branch stays red. A base that cannot be set up counts
# every head red as the change's.
set -euo pipefail

base_ref="${1:-}"
here="$(cd "$(dirname "$0")" && pwd -P)"
work="$(mktemp -d)"
base_tree="$work/base"
cleanup() {
  if [ -d "$base_tree" ]; then git worktree remove --force "$base_tree" > /dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

status=0
CMUX_WEB_TEST_RESULTS="$work/head.json" bash "$here/run-webviews-tests.sh" || status=$?
# 0 is green; anything but 1 (one or more files red) is a broken run, never a base red.
if [ "$status" -ne 1 ] || [ -z "$base_ref" ] || [ ! -s "$work/head.json" ]; then exit "$status"; fi

# Each red file again on the head, one at a time like the base's rerun below: a test that fails only
# beside other files (load, a shared port) would otherwise count as the change's. Together, the
# reruns still crowd each other: composer-draft-wrap timed out beside 2 other red files and passed
# alone on the base (#23209, 2026-10-21). A file that passes alone is a warning; one that fails
# again keeps its first run's reds.
echo "::group::the red files again on the head, alone"
python3 "$here/webviews_test_results.py" --failed-files "$work/head.json" > "$work/head-files"
(CMUX_WEB_TEST_FILES="$(cat "$work/head-files")" CMUX_WEB_TEST_RESULTS="$work/again.json" CMUX_WEB_TEST_JOBS=1 \
  env -u CMUX_WEB_TEST_SHARD -u CMUX_WEB_TEST_SHARD_COUNT \
  bash "$here/run-webviews-tests.sh" > "$work/again.log" 2>&1) || true
sed -n '/^### webviews tests:/,$p' "$work/again.log"
echo "::endgroup::"
python3 "$here/webviews_test_results.py" --passed-alone "$work/head.json" "$work/again.json"
if [ -z "$(python3 "$here/webviews_test_results.py" --failed-files "$work/head.json")" ]; then exit 0; fi

# The red files BASE has; a file only the head has is new, so its reds are the change's.
prefix="$(git rev-parse --show-prefix)"
: > "$work/files"
while read -r file; do
  if [ -n "$file" ] && git cat-file -e "$base_ref:$prefix$file" 2> /dev/null; then
    echo "$file" >> "$work/files"
  fi
done < <(python3 "$here/webviews_test_results.py" --failed-files "$work/head.json")

echo "::group::the red files again on the base ($base_ref)"
if [ -s "$work/files" ] && git worktree add -q --detach "$base_tree" "$base_ref" > /dev/null &&
  (cd "$base_tree/$prefix" && bun install --frozen-lockfile &&
    # The base's own Playwright engines: a change that bumps Playwright would leave the base's
    # browser tests red on a missing executable, and every head browser red would match them.
    ./node_modules/.bin/playwright install --only-shell chromium webkit &&
    "$base_tree/scripts/cmux-next/build-web-bundles.sh" --force); then
  # Every red file runs, one at a time, whatever this job's shard. prScope.ts gets no changed files (in the base
  # checkout its `git diff HEAD^1` has no parent and would crash the file) and warns only: the
  # head's run already counted just the change's own findings, so the base's findings, all of
  # them unscoped, must not turn the same test red there and pass the change's off as old.
  (cd "$base_tree/$prefix" && CMUX_WEB_TEST_FILES="$(cat "$work/files")" CMUX_WEB_TEST_RESULTS="$work/base.json" CMUX_WEB_TEST_JOBS=1 \
    env -u CMUX_WEB_TEST_SHARD -u CMUX_WEB_TEST_SHARD_COUNT -u CMUX_PR_CHANGED_FILES CMUX_NEXT_STYLE_GUARDS=warn \
    bash "$here/run-webviews-tests.sh" > "$work/base.log" 2>&1) || true
  sed -n '/^### webviews tests:/,$p' "$work/base.log"
elif [ -s "$work/files" ]; then
  echo "the base did not set up: every red counts as this change's"
else
  echo "{}" > "$work/base.json"
fi
echo "::endgroup::"
python3 "$here/guards_new_reds.py" --label "Webview test" "$work/head.json" "$work/base.json"
