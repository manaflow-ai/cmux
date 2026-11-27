#!/usr/bin/env bash
# cmux-next.yml job `release-compile-revert`, step "Open the revert pull request". Moved out of the workflow to keep it under
# GitHub's workflow file size limit (tests/test_ci_workflow_file_size.py); its env: stays in the workflow.
set -euo pipefail
[[ "$PR" =~ ^[0-9]+$ && "$MERGE_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::bad culprit output"; exit 1; }
export GH_TOKEN="$APP_TOKEN"
branch="revert/pr-$PR"
open="$(gh api "repos/$GITHUB_REPOSITORY/pulls?state=all&head=${GITHUB_REPOSITORY_OWNER}:${branch}" --jq '.[0].html_url // empty')"
if [[ -n "$open" ]]; then
  echo "A revert of #$PR already exists: $open" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi
git config user.name "cmux-next compile revert"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
if ! git cat-file -e "$MERGE_SHA^{commit}" 2>/dev/null || ! git merge-base --is-ancestor "$MERGE_SHA" HEAD; then
  echo "::warning title=Release compile revert::$MERGE_SHA is not in the last 200 commits of feat-cmux-next; left to #$PR's owner."
  exit 0
fi
mainline=()
if [[ "$(git rev-list --parents -n1 "$MERGE_SHA" | wc -w)" -gt 2 ]]; then
  mainline=(-m 1)  # a merge commit: undo what it brought onto feat-cmux-next
fi
if ! git revert --no-edit ${mainline[@]+"${mainline[@]}"} "$MERGE_SHA"; then
  git revert --abort || true
  echo "::warning title=Release compile revert::reverting #$PR ($MERGE_SHA) conflicts with feat-cmux-next's tip; left to its owner."
  exit 0
fi
auth="$(printf 'x-access-token:%s' "$APP_TOKEN" | base64 -w0)"
echo "::add-mask::$auth"
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" \
GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth" \
  git push --quiet "https://github.com/$GITHUB_REPOSITORY.git" "HEAD:refs/heads/$branch"
title="$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR" --jq .title)"
body="$(printf '%s\n\n%s\n\n%s\n' \
  "Reverts #$PR (\`$MERGE_SHA\`): the feat-cmux-next push run $RUN_URL failed its Mac Release compile (\`cmux-next Release compile (Xcode 26)\`) at \`$GITHUB_SHA\`; it last passed at \`$GOOD\`, and #$PR is the one merge since." \
  "Pull requests get the fleet compile at -Onone, so -O codegen and the final app link are first compiled on the base push. The base-break rule restores base first: land this, then reland #$PR with the fix." \
  "Opened by cmux-next.yml release-compile-revert.")"
url="$(gh api -X POST "repos/$GITHUB_REPOSITORY/pulls" -f head="$branch" -f base=feat-cmux-next \
  -f title="Revert \"$title\" (broke the feat-cmux-next Release compile)" -f body="$body" --jq .html_url)"
echo "::notice title=Release compile revert::$url reverts #$PR"
echo "Revert pull request: $url" >> "$GITHUB_STEP_SUMMARY"
