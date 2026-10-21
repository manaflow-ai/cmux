#!/usr/bin/env bash
# Runs the webviews tests (run-webviews-tests.sh, from webviews/) and, given BASE, fails only on the
# tests this change turns red; a test red on BASE too is a warning (guards_new_reds.py).
#
#   ../scripts/ci/webviews-tests-new-reds.sh [BASE]
#
# About 25 browser tests were red on feat-cmux-next for every pull request, and #23090's 2 new reds
# (agent-pane-peer-chat, agent-pane-working-counts) landed unseen among them (2026-10-21). With BASE
# (a pull request's merge parent, HEAD^1), each file red on the head runs again, alone, in a BASE
# checkout with its own install and web bundles, and the results compare per test name. No BASE (a
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
    "$base_tree/scripts/cmux-next/build-web-bundles.sh" --force); then
  (cd "$base_tree/$prefix" && CMUX_WEB_TEST_FILES="$(cat "$work/files")" CMUX_WEB_TEST_RESULTS="$work/base.json" \
    bash "$here/run-webviews-tests.sh" > "$work/base.log" 2>&1) || true
  sed -n '/^### webviews tests:/,$p' "$work/base.log"
elif [ -s "$work/files" ]; then
  echo "the base did not set up: every red counts as this change's"
else
  echo "{}" > "$work/base.json"
fi
echo "::endgroup::"
python3 "$here/guards_new_reds.py" --label "Webview test" "$work/head.json" "$work/base.json"
