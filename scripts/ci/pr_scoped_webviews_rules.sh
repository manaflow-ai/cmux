#!/usr/bin/env bash
# ci-web.yml's "Check PR-scoped webview rules" (react-apps-check shard 1), from the repository root: the PR-scoped
# webview rule tests at the head; on a pull request a red there is charged only when the merge parent (HEAD^1) passes
# it (guards_new_reds.py). Its own file so the shard can start it in the background (scripts/ci/bg_step.sh) beside
# the Oxlint step; the commands are the step's own, moved here unchanged.
set -eo pipefail
check=scripts/tests/test_pr_scoped_webviews_checks.py
if [ "${GITHUB_EVENT_NAME:-}" != pull_request ]; then exec python3 "$check"; fi
python3 scripts/ci/unittest_results.py "$check" "$RUNNER_TEMP/pr-scoped-head.json" && exit 0
base="$RUNNER_TEMP/pr-scoped-base"
git worktree add --detach "$base" HEAD^1
ln -s "$PWD/webviews/node_modules" "$base/webviews/node_modules"
if [ -f "$base/$check" ]; then
  python3 scripts/ci/unittest_results.py "$base/$check" "$RUNNER_TEMP/pr-scoped-base.json" || true
fi
python3 scripts/ci/guards_new_reds.py --label "PR-scoped webview rule" \
  "$RUNNER_TEMP/pr-scoped-head.json" "$RUNNER_TEMP/pr-scoped-base.json"
