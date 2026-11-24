#!/usr/bin/env bash
# Reads the pull request a cmux-next-hot-verify.yml dispatch names and says whether to look at it, or post its look:
# ok, pr, head, pr_head, web, rust, layers, kind, attempt and event_at lines to GITHUB_OUTPUT. Both dispatch kinds
# run it: the request run's `target` job and the result run's one `publish` job, so a result pays one runner queue
# wait, not two (the result run's `target` sat queued for a shared 4 vCPU Linux runner for hours, 2026-11-19).
# Env: PR, HEAD_SHA, LAYERS, KIND, ATTEMPT, EVENT_AT, GH_TOKEN, GITHUB_REPOSITORY.
set -euo pipefail
[[ "$PR" =~ ^[1-9][0-9]{0,6}$ ]] || { echo "::error::pr must be a pull request number"; exit 1; }
[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::head must be a full commit sha"; exit 1; }
[[ "$LAYERS" =~ ^(web|rust|customize)(,(web|rust|customize)){0,2}$ ]] || { echo "::error::layers takes web, rust and customize"; exit 1; }
# These go into the request job's name, which the build fleet controller parses: only these shapes.
KIND="${KIND:-head}" ATTEMPT="${ATTEMPT:-0}" EVENT_AT="${EVENT_AT:-}"
[[ "$KIND" =~ ^(head|merge)$ ]] || { echo "::error::kind takes head or merge"; exit 1; }
[[ "$ATTEMPT" =~ ^[01]$ ]] || { echo "::error::attempt takes 0 or 1"; exit 1; }
[[ "$EVENT_AT" =~ ^[0-9]{0,11}$ ]] || EVENT_AT=""
rest_jq='[.head.repo.full_name, .head.sha, .base.ref, .state, .draft, (.merged_at // "-"), (.merge_commit_sha // "-")] | @tsv'
# The read used to wait out a spent REST hour on a held runner (gh_budget_wait.sh is gh in this job): 2026-11-23
# 22Z..11-24 22Z, this step held "post the look" and "check the pull request" about 10,000 runner-minutes, up to
# 2,548 s a job (job 138587116931). So: one REST try that never waits; on a rate-limit refusal one GraphQL read, a
# separate hourly budget, of the same fields (as cmux-next-fast-gates.yml's dispatch read); and only if that fails
# too, the old REST read that waits for the reset. Each step fails open to the next, so no answer differs from before.
# shellcheck disable=SC2016 # the GraphQL query's own $variables, not the shell's
pr_query='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      state isDraft mergedAt headRefOid baseRefName headRepository { nameWithOwner } mergeCommit { oid }
    }
  }
}'
graphql_jq='.data.repository.pullRequest | select(. != null and .headRefOid != null and .baseRefName != null)
  | [(.headRepository.nameWithOwner // ""), .headRefOid, .baseRefName,
     (if .state == "OPEN" then "open" else "closed" end), (.isDraft | tostring),
     (.mergedAt // "-"), (.mergeCommit.oid // "-")] | @tsv'
pr_read_errors="$(mktemp)"
if info="$(GH_BUDGET_WAIT_ATTEMPTS=1 gh api "repos/$GITHUB_REPOSITORY/pulls/$PR" --jq "$rest_jq" 2>"$pr_read_errors")"; then
  :
elif grep -qiE 'rate limit|HTTP 429' "$pr_read_errors" &&
  info="$(GH_BUDGET_WAIT_ATTEMPTS=1 gh api graphql -F owner="${GITHUB_REPOSITORY%%/*}" \
    -F name="${GITHUB_REPOSITORY#*/}" -F number="$PR" -f query="$pr_query" --jq "$graphql_jq")" && [[ -n "$info" ]]; then
  echo "hot verify: the REST budget is spent; read #$PR over GraphQL" | tee -a "$GITHUB_STEP_SUMMARY"
else
  cat "$pr_read_errors" >&2
  info="$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR" --jq "$rest_jq")"
fi
rm -f "$pr_read_errors"
IFS=$'\t' read -r head_repo live base_ref state draft merged_at merge_sha <<<"$info"
ok=true
# A merged pull request is looked at too, at its merged head: a look queued behind a busy gateway label
# often starts after the merge, and `look again` runs after it (the worker takes a merged head on GitHub's
# PR API's word, cmuxterm-hq#11742). Or at its merge commit (kind merge, dispatched when it merged with no
# receipt). Closed without a merge, or a draft: no look.
if [[ "$head_repo" != "$GITHUB_REPOSITORY" || "$base_ref" != feat-cmux-next ]]; then
  echo "hot verify: #$PR is not a same-repository pull request into feat-cmux-next; no look" | tee -a "$GITHUB_STEP_SUMMARY"; ok=false
elif [[ "$draft" == true || ( "$state" != open && "$merged_at" == - ) ]]; then
  echo "hot verify: #$PR is $state${draft/true/ (draft)}; no look" | tee -a "$GITHUB_STEP_SUMMARY"; ok=false
elif [[ "$live" != "$HEAD_SHA" && ( "$merged_at" == - || "$merge_sha" != "$HEAD_SHA" ) ]]; then
  echo "hot verify: #$PR moved to ${live:0:12}; its own run looks at it" | tee -a "$GITHUB_STEP_SUMMARY"; ok=false
fi
{
  echo "ok=$ok"
  echo "pr=$PR"
  echo "head=$HEAD_SHA"
  echo "pr_head=$live"
  [[ ",$LAYERS," == *,web,* ]] && echo "web=true" || echo "web=false"
  [[ ",$LAYERS," == *,rust,* ]] && echo "rust=true" || echo "rust=false"
  echo "layers=$LAYERS"
  echo "kind=$KIND"
  echo "attempt=$ATTEMPT"
  echo "event_at=$EVENT_AT"
} >> "$GITHUB_OUTPUT"
