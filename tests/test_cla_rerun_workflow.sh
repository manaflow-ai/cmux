#!/usr/bin/env bash
# Exercise the trusted CLA rerun script against deterministic GitHub API
# fixtures. This runs the workflow code itself, rather than checking text
# shape, so stale generations and fork associations stay covered.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/cla.yml"
test -f "$WORKFLOW"
command -v jq >/dev/null

# The pull_request CI workflow executes this harness against PR-controlled
# workflow text. It must never receive Actions write authority. Only the
# isolated CLA rerun job may have that permission.
python3 - "$ROOT_DIR/.github/workflows/ci.yml" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    document = yaml.safe_load(handle)
permissions = document.get("permissions", {})
if permissions.get("actions") == "write":
    raise SystemExit("CI must not grant top-level actions: write to pull_request jobs")
PY

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rerun_script="$work/rerun.sh"

# Extract only the run block for RerunFailedCLA. The extracted file is
# executed below, so this is a behavior test of the checked-in workflow.
awk '
  /^  RerunFailedCLA:/ { in_job=1; next }
  in_job && /^        run: \|$/ { in_run=1; next }
  in_run && /^  LockMergedPullRequest:/ { exit }
  in_run { sub(/^          /, ""); print }
' "$WORKFLOW" >"$rerun_script"
bash -n "$rerun_script"

export GH_REPO=manaflow-ai/cmux
export EVENT_NAME=issue_comment
export ISSUE_NUMBER=123
export PR_NUMBER=123
export COMMENT_BODY=recheck
export COMMENT_CREATED_AT=2026-08-31T08:00:00Z
export WORKFLOW_PATH=.github/workflows/cla.yml
export WORKFLOW_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export TARGET_EVENT=pull_request_target
export TARGET_BASE_REF=main

# This stub models the API fields used by the rerun guard. In particular, a
# fork-only commit has no result from /commits/:sha/pulls, while the workflow
# run still carries head_repository identity.
gh() {
  local endpoint="${*: -1}"
  local live_state=open
  local live_base=main
  local run_head_repo=contributor/cmux
  local run_head_repo_id=200
  local marker="CLA generation v2 ${WORKFLOW_SHA}"

  case "${FAKE_MODE}" in
    stale-marker) marker="CLA generation v2 cccccccccccccccccccccccccccccccccccccccc" ;;
    wrong-head-repo) run_head_repo=attacker/cmux; run_head_repo_id=201 ;;
    closed-pr) live_state=closed ;;
    retargeted-pr) live_base=release ;;
  esac

  if [[ " $* " == *" --method POST "* ]]; then
    printf 'rerun\n' >>"$FAKE_POST_FILE"
    return 0
  fi

  case "$endpoint" in
    repos/manaflow-ai/cmux/issues/123)
      jq -nc --arg state "$live_state" '{state:$state,pull_request:{url:"https://api.github.com/repos/manaflow-ai/cmux/pulls/123"}}'
      ;;
    repos/manaflow-ai/cmux/pulls/123)
      jq -nc --arg state "$live_state" --arg base "$live_base" \
        '{number:123,state:$state,base:{ref:$base,repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:200,full_name:"contributor/cmux"}}}'
      ;;
    repos/manaflow-ai/cmux/commits/*/pulls)
      printf '[]\n'
      ;;
    repos/manaflow-ai/cmux/actions/workflows\?per_page=100)
      printf '[{"workflows":[{"id":300,"path":".github/workflows/cla.yml","state":"active"}]}]\n'
      ;;
    repos/manaflow-ai/cmux/actions/workflows/300/runs\?event=pull_request_target\&head_sha=*\&per_page=100)
      jq -nc --arg head_repo "$run_head_repo" --argjson head_repo_id "$run_head_repo_id" \
        '[{workflow_runs:[{id:400,workflow_id:300,path:".github/workflows/cla.yml",event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",head_branch:"feature",head_repository:{id:$head_repo_id,full_name:$head_repo},pull_requests:[],created_at:"2026-08-31T07:00:00Z"}]}]'
      ;;
    repos/manaflow-ai/cmux/actions/runs/400)
      jq -nc --arg head_repo "$run_head_repo" --argjson head_repo_id "$run_head_repo_id" \
        '{id:400,workflow_id:300,path:".github/workflows/cla.yml",event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",head_branch:"feature",head_repository:{id:$head_repo_id,full_name:$head_repo},pull_requests:[],created_at:"2026-08-31T07:00:00Z"}'
      ;;
    repos/manaflow-ai/cmux/actions/runs/400/jobs\?per_page=100)
      jq -nc --arg marker "$marker" \
        '[{jobs:[{id:500,run_id:400,name:"CLA Assistant",workflow_name:"CLA Assistant",status:"completed",conclusion:"failure",head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",head_branch:"feature",head_repository:null,steps:[{name:$marker,status:"completed",conclusion:"success"}]}]}]'
      ;;
    repos/manaflow-ai/cmux/actions/jobs/500)
      jq -nc --arg marker "$marker" \
        '{id:500,run_id:400,name:"CLA Assistant",workflow_name:"CLA Assistant",status:"completed",conclusion:"failure",head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",head_branch:"feature",head_repository:null,steps:[{name:$marker,status:"completed",conclusion:"success"}]}'
      ;;
    *)
      echo "unexpected API endpoint: $endpoint" >&2
      return 1
      ;;
  esac
}
export -f gh

run_case() {
  local mode="$1"
  local expected_status="$2"
  local expected_text="$3"
  local expected_posts="$4"
  local output status posts
  : >"$work/posts-$mode"
  set +e
  output="$(FAKE_MODE="$mode" FAKE_POST_FILE="$work/posts-$mode" bash "$rerun_script" 2>&1)"
  status=$?
  set -e
  if [[ "$status" != "$expected_status" ]]; then
    echo "FAIL: $mode exited $status, expected $expected_status" >&2
    echo "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected_text"* ]]; then
    echo "FAIL: $mode did not report '$expected_text'" >&2
    echo "$output" >&2
    exit 1
  fi
  posts="$(wc -l <"$work/posts-$mode" | tr -d ' ')"
  if [[ "$posts" != "$expected_posts" ]]; then
    echo "FAIL: $mode made $posts rerun calls, expected $expected_posts" >&2
    exit 1
  fi
  echo "PASS: $mode"
}

run_case fork-current 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case stale-marker 1 "does not have exactly one failed CLA job" 0
run_case wrong-head-repo 0 "No failed CLA run exists for this pull request head" 0
run_case closed-pr 1 "The issue is not an open pull request" 0
run_case retargeted-pr 1 "The live pull request is not valid" 0
