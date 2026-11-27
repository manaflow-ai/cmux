#!/usr/bin/env bash
# Reads the pull request a cmux-next-hot-verify.yml dispatch names and says whether to look at it, or post its look:
# ok, pr, head, pr_head, publish_web, rust, layers, kind, attempt and event_at lines to GITHUB_OUTPUT. Both dispatch kinds
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
# The read never sleeps first. When the REST hour is spent (every workflow's github.token shares it), the same
# fields come from GraphQL, which has an hour of its own; only when both refuse does the call wait for a reset, for
# at most the caller's GH_BUDGET_WAIT_MAX_SECONDS. On 11-23T18..11-24T18 this one GET slept through the REST reset
# in 931 runs (post the look p50 919 s, check the pull request killed at its 5-minute timeout): 8,833 runner-min.
# GH_BUDGET_WAIT_MAX_SECONDS=0 makes gh_budget_wait.sh try every spare pool, then return the refusal unslept.
rest_jq='[.head.repo.full_name, .head.sha, .base.ref, .state, .draft, (.merged_at // "-"), (.merge_commit_sha // "-")] | @tsv'
owner="${GITHUB_REPOSITORY%%/*}" name="${GITHUB_REPOSITORY#*/}"
gql='query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){pullRequest(number:$pr){headRepository{nameWithOwner} headRefOid baseRefName state isDraft mergedAt mergeCommit{oid}}}}'
# GraphQL's state is OPEN, CLOSED or MERGED; REST's is open or closed (a merged PR is closed with merged_at).
gql_jq='.data.repository.pullRequest | [(.headRepository.nameWithOwner // "-"), .headRefOid, .baseRefName, (if .state == "OPEN" then "open" else "closed" end), .isDraft, (.mergedAt // "-"), (.mergeCommit.oid // "-")] | @tsv'
info="$(GH_BUDGET_WAIT_MAX_SECONDS=0 gh api "repos/$GITHUB_REPOSITORY/pulls/$PR" --jq "$rest_jq" 2>/dev/null)" ||
  info="$(GH_BUDGET_WAIT_MAX_SECONDS=0 gh api graphql -f query="$gql" -f owner="$owner" -f name="$name" -F pr="$PR" --jq "$gql_jq" 2>/dev/null)" ||
  info="$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR" --jq "$rest_jq")"
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
  # A merged web PR gets its layer from the base push. Its branch may already
  # be gone. The look still requests every layer in LAYERS from the worker.
  [[ "$state" == open && ",$LAYERS," == *,web,* ]] && echo "publish_web=true" || echo "publish_web=false"
  [[ ",$LAYERS," == *,rust,* ]] && echo "rust=true" || echo "rust=false"
  echo "layers=$LAYERS"
  echo "kind=$KIND"
  echo "attempt=$ATTEMPT"
  echo "event_at=$EVENT_AT"
} >> "$GITHUB_OUTPUT"
