#!/usr/bin/env bash
# web-bundle-matrix.yml, report job: one revert pull request of the later landing behind a red web bundle matrix.
# Same branch (revert/pr-N) as cmux-next.yml's release-compile-revert, so a red both find opens one revert, and a
# red that stays red over many pushes opens it once. Env: APP_TOKEN, PR, MERGE_SHA, PAIR, SHA, JOB, FILE, LINE,
# MESSAGE, RUN_URL, GITHUB_REPOSITORY(_OWNER); a checkout of feat-cmux-next with history.
set -euo pipefail
[[ "$PR" =~ ^[0-9]+$ && "$MERGE_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::bad culprit output"; exit 1; }
export GH_TOKEN="$APP_TOKEN"
branch="revert/pr-$PR"
open="$(gh api "repos/$GITHUB_REPOSITORY/pulls?state=all&head=${GITHUB_REPOSITORY_OWNER}:${branch}" --jq '.[0].html_url // empty')"
if [[ -n "$open" ]]; then
  echo "A revert of #$PR already exists: $open" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi
# A red the tip already fixed (a newer push is green) needs no revert: ask the tip's own status.
tip="$(git ls-remote "https://github.com/$GITHUB_REPOSITORY.git" refs/heads/feat-cmux-next | cut -f1)"
if [[ "$tip" =~ ^[0-9a-f]{40}$ && "$tip" != "$SHA" ]]; then
  state="$(gh api "repos/$GITHUB_REPOSITORY/commits/$tip/statuses" \
    --jq '[.[] | select(.context=="cmux-next/web-bundle-matrix")][0].state // empty')"
  if [[ "$state" == success ]]; then
    echo "The tip ${tip:0:12} is already green; no revert of #$PR." >> "$GITHUB_STEP_SUMMARY"
    exit 0
  fi
fi
git config user.name "cmux-next web bundle matrix"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
if ! git cat-file -e "$MERGE_SHA^{commit}" 2>/dev/null || ! git merge-base --is-ancestor "$MERGE_SHA" HEAD; then
  echo "::warning title=Web bundle matrix::$MERGE_SHA is not in the last 300 commits of feat-cmux-next; left to #$PR's owner."
  exit 0
fi
mainline=()
if [[ "$(git rev-list --parents -n1 "$MERGE_SHA" | wc -w)" -gt 2 ]]; then mainline=(-m 1); fi
if ! git revert --no-edit ${mainline[@]+"${mainline[@]}"} "$MERGE_SHA"; then
  git revert --abort || true
  echo "::warning title=Web bundle matrix::reverting #$PR ($MERGE_SHA) conflicts with feat-cmux-next's tip; left to its owner."
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
  "Reverts #$PR (\`$MERGE_SHA\`): the web bundle matrix is red at \`$SHA\` in \`$JOB\`: \`$FILE:$LINE\`: ${MESSAGE:0:300}. Pull requests named by the failing lines: ${PAIR:-#$PR}; #$PR landed last. Run: $RUN_URL" \
  "Each of those pull requests was green alone and the merged tree is red (a duplicate import, a name declared twice). The base-break rule restores base first: land this, then reland #$PR with the fix, or close this if a fix already landed." \
  "Opened by web-bundle-matrix.yml.")"
url="$(gh api -X POST "repos/$GITHUB_REPOSITORY/pulls" -f head="$branch" -f base=feat-cmux-next \
  -f title="Revert \"$title\" (broke the feat-cmux-next web bundles)" -f body="$body" --jq .html_url)"
echo "::notice title=Web bundle matrix::$url reverts #$PR"
echo "Revert pull request: $url" >> "$GITHUB_STEP_SUMMARY"
