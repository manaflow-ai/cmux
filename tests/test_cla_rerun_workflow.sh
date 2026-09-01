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
# isolated CLA rerun job may have that permission. Use awk here because this
# check runs before CI installs its optional Python dependencies.
if awk '
  /^permissions:[[:space:]]*$/ { in_permissions=1; next }
  in_permissions && /^[^[:space:]]/ { in_permissions=0 }
  in_permissions && /^[[:space:]]+actions:[[:space:]]*write([[:space:]]*#.*)?$/ { found=1 }
  END { exit found ? 0 : 1 }
' "$ROOT_DIR/.github/workflows/ci.yml"; then
  echo "CI must not grant top-level actions: write to pull_request jobs" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rerun_script="$ROOT_DIR/.github/scripts/rerun-failed-cla.sh"
test -f "$rerun_script"
bash -n "$rerun_script"

# The privileged job checks out only the immutable workflow revision and
# launches the checked-in guard. Keep the launcher below the Actions step-size
# limit, and reject any future attempt to execute the pull-request head.
grep -Fq 'uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2' "$WORKFLOW"
grep -Fq "repository: \${{ github.repository }}" "$WORKFLOW"
grep -Fq "ref: \${{ github.workflow_sha }}" "$WORKFLOW"
grep -Fq 'sparse-checkout: .github/scripts/rerun-failed-cla.sh' "$WORKFLOW"
grep -Fq 'bash .github/scripts/rerun-failed-cla.sh' "$WORKFLOW"
grep -Fq "COMMENT_ID: \${{ github.event.comment.id }}" "$WORKFLOW"
grep -Fq '      - .github/scripts/rerun-failed-cla.sh' "$ROOT_DIR/.github/workflows/ci.yml"
if grep -Fq "ref: \${{ github.event.pull_request" "$WORKFLOW"; then
  echo 'FAIL: CLA rerun checkout must never use a pull-request ref' >&2
  exit 1
fi
launcher_bytes="$(awk '
  /^  RerunFailedCLA:/ { in_job=1; next }
  in_job && /^  LockMergedPullRequest:/ { exit }
  in_job && /^        run: \|$/ { in_run=1; next }
  in_run { sub(/^          /, ""); print }
' "$WORKFLOW" | wc -c | tr -d ' ')"
[[ "$launcher_bytes" =~ ^[0-9]+$ && "$launcher_bytes" -lt 21000 ]] || {
  echo "FAIL: CLA rerun launcher is too large (${launcher_bytes} bytes)" >&2
  exit 1
}

export GH_REPO=manaflow-ai/cmux
export EVENT_NAME=issue_comment
export ISSUE_NUMBER=123
export PR_NUMBER=123
export COMMENT_ID=900
export COMMENT_BODY=recheck
export COMMENT_CREATED_AT=2026-08-31T08:00:00Z
export COMMENT_AUTHOR_ID=300
export COMMENT_AUTHOR_LOGIN=contributor
export COMMENT_AUTHOR_TYPE=User
export COMMENT_AUTHOR_ASSOCIATION=NONE
export WORKFLOW_PATH=.github/workflows/cla.yml
export CLA_GENERATION=v2.2-action-bc206ed9b52ad0b0cbe85244ce522e5e9b65c10e
export TARGET_EVENT=pull_request_target
export TARGET_BASE_REF=main
export SIGNATURE_RECORDED=false

# This stub models the API fields used by the rerun guard. In particular, a
# fork-only commit has no result from /commits/:sha/pulls, while the workflow
# run still carries head_repository identity. GitHub may report the source PR
# SHA or a different execution SHA on a pull_request_target run, so this fixture
# keeps the live PR head at `aaaa...` and, for the populated-association case,
# the selected run/job execution SHA at `bbbb...`. A populated pull_requests
# object binds that differing execution to the source PR. An empty association
# must use the exact live PR head SHA or fail closed.
gh() {
  local endpoint=""
  local api_page=1
  local arg
  for arg in "$@"; do
    if [[ "$arg" == page=* ]]; then
      api_page="${arg#page=}"
    fi
    if [[ "$arg" == repos/* ]]; then
      endpoint="$arg"
    fi
  done
  [[ -n "$endpoint" ]] || {
    echo "missing API endpoint" >&2
    return 1
  }
  if [[ "$endpoint" == repos/manaflow-ai/cmux/commits/*/pulls &&
        " $* " != *" --method GET "* ]]; then
    echo "commit association lookup must use GET" >&2
    return 1
  fi
  local live_state=open
  local live_base=main
  local live_head_repo=contributor/cmux
  local live_head_repo_id=200
  local run_head_repo=contributor/cmux
  local run_head_repo_id=200
  local run_head_repository_null=false
  local omit_job_head_repository=false
  local run_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  local marker="CLA generation ${CLA_GENERATION}"
  local run_path=.github/workflows/cla.yml
  local run_prs='[{"number":123,"base":{"ref":"main","repo":{"id":100,"full_name":"manaflow-ai/cmux"}},"head":{"ref":"feature","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"id":200,"full_name":"contributor/cmux"}}}]'
  local ledger_id=400
  local ledger_login=coauthor
  local ledger_comment_id=900

  case "${FAKE_MODE}" in
    stale-marker) marker="CLA generation v2.2-action-0000000000000000000000000000000000000000" ;;
    unrelated-main-commit) marker="CLA generation ${CLA_GENERATION}" ;;
    wrong-head-repo) run_head_repo=attacker/cmux; run_head_repo_id=201; run_prs='[]' ;;
    association-overflow) run_prs='[]' ;;
    fork-current|empty-run-association) run_prs='[]'; run_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
    empty-different-execution-associated) run_prs='[]' ;;
    same-repo-empty)
      run_prs='[]'
      run_head_repo=manaflow-ai/cmux
      run_head_repo_id=100
      run_head_repository_null=true
      run_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      live_head_repo=manaflow-ai/cmux
      live_head_repo_id=100
      ;;
    stale-empty-execution) run_prs='[]'; run_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
    empty-mismatched-newer) run_prs='[]' ;;
    unbound-signer) ledger_id=401; ledger_login=other-signer; ledger_comment_id=901 ;;
    minimal-run-association) run_prs='[{"number":123,"base":{"ref":"main","repo":{"id":100}},"head":{"ref":"feature","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"id":200}}}]' ;;
    wrong-run-association) run_prs='[{"number":124,"base":{"ref":"main","repo":{"id":100,"full_name":"manaflow-ai/cmux"}},"head":{"ref":"feature","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"id":200,"full_name":"contributor/cmux"}}}]' ;;
    malformed-run-association) run_prs='{}' ;;
    invalid-run-association) run_prs='false' ;;
    closed-pr) live_state=closed ;;
    retargeted-pr) live_base=release ;;
    suffixed-path) run_path=.github/workflows/cla.yml@main ;;
    job-missing-head-repository) omit_job_head_repository=true ;;
  esac

  if [[ " $* " == *" --method POST "* ]]; then
    printf '%s\n' "$endpoint" >>"$FAKE_POST_FILE"
    return 0
  fi

  case "$endpoint" in
    repos/manaflow-ai/cmux/issues/123)
      jq -nc --arg state "$live_state" '{state:$state,pull_request:{url:"https://api.github.com/repos/manaflow-ai/cmux/pulls/123"}}'
      ;;
    repos/manaflow-ai/cmux/pulls/123)
      jq -nc --arg state "$live_state" --arg base "$live_base" --arg head_repo "$live_head_repo" --argjson head_repo_id "$live_head_repo_id" \
        '{number:123,state:$state,user:{id:300,login:"contributor"},base:{ref:$base,repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:$head_repo_id,full_name:$head_repo}}}'
      ;;
    repos/manaflow-ai/cmux/commits/*/pulls)
      if [[ "${FAKE_MODE}" == association-not-found ]]; then
        printf '{"message":"Not Found","status":404}\n'
        return 1
      elif [[ "${FAKE_MODE}" == association-validation-error ]]; then
        printf '{"message":"No commit found for SHA: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"422"}\n'
        return 1
      elif [[ "${FAKE_MODE}" == association-stderr-not-found ]]; then
        printf 'gh: Not Found (HTTP 404)\n' >&2
        return 1
      elif [[ "${FAKE_MODE}" == association-stderr-validation-error ]]; then
        printf 'gh: No commit found for SHA: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (HTTP 422)\n' >&2
        return 1
      elif [[ "${FAKE_MODE}" == association-api-failure ]]; then
        printf '{"message":"API unavailable","status":503}\n'
        return 1
      elif [[ "${FAKE_MODE}" == association-overflow ]]; then
        jq -nc '[range(0; 100) | {number:(1000 + .),base:{ref:"main",repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:200,full_name:"contributor/cmux"}}}]'
      elif [[ "${FAKE_MODE}" == paginated-associations && "${api_page}" == 1 ]]; then
        jq -nc '[range(0; 100) | {number:(1000 + .),base:{ref:"main",repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"cccccccccccccccccccccccccccccccccccccccc",repo:{id:200,full_name:"contributor/cmux"}}}]'
      elif [[ "${FAKE_MODE}" == paginated-associations && "${api_page}" == 2 ]]; then
        jq -nc '[{number:123,base:{ref:"main",repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:200,full_name:"contributor/cmux"}}}]'
      elif [[ "${FAKE_MODE}" == same-repo-empty ]]; then
        jq -nc '[{number:123,base:{ref:"main",repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:100,full_name:"manaflow-ai/cmux"}}}]'
      else
        printf '[]\n'
      fi
      ;;
    repos/manaflow-ai/cmux/contents/signatures/version2/cla.json)
      ledger_content="{\"signedContributors\":[{\"name\":\"${ledger_login}\",\"id\":${ledger_id},\"comment_id\":${ledger_comment_id},\"created_at\":\"2026-08-31T08:00:00Z\",\"repoId\":100,\"pullRequestNo\":123}]}"
      if [[ "${FAKE_MODE}" == wrapped-ledger || "${FAKE_MODE}" == oversized-ledger ]]; then
        local target_bytes=1000000
        [[ "${FAKE_MODE}" == oversized-ledger ]] && target_bytes=1000001
        local padding=$((target_bytes - ${#ledger_content} - 13))
        local padding_text
        (( padding > 0 )) || {
          echo "ledger fixture core unexpectedly exceeds target size" >&2
          return 1
        }
        padding_text="$(printf '%*s' "$padding" '' | tr ' ' 'A')"
        ledger_content="${ledger_content%?},\"padding\":\"${padding_text}\"}"
      fi
      if [[ "${FAKE_MODE}" == malformed-ledger ]]; then
        encoded_ledger='not-valid-base64'
      elif [[ "${FAKE_MODE}" == wrapped-ledger || "${FAKE_MODE}" == oversized-ledger ]]; then
        encoded_ledger="$(printf '%s' "$ledger_content" | base64)"
      else
        encoded_ledger="$(printf '%s' "$ledger_content" | base64 | tr -d '\n')"
      fi
      # Stream the potentially near-limit fixture through jq instead of
      # passing it as an argv value, which exceeds macOS ARG_MAX.
      printf '{"type":"file","encoding":"base64","content":'
      printf '%s' "$encoded_ledger" | jq -Rs .
      printf '}\n'
      ;;
    repos/manaflow-ai/cmux/pulls)
      local association_call=1
      if [[ -n "${FAKE_ASSOC_CALL_FILE:-}" ]]; then
        if [[ -s "${FAKE_ASSOC_CALL_FILE}" ]]; then
          read -r association_call <"${FAKE_ASSOC_CALL_FILE}"
          association_call=$((association_call + 1))
        fi
        printf '%s\n' "$association_call" >"${FAKE_ASSOC_CALL_FILE}"
      fi
      if [[ "${FAKE_MODE}" == paginated-open-prs && "${api_page}" == 1 ]]; then
        jq -nc '[range(0; 100) | {number:(1000 + .),state:"open",base:{ref:"main",repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"cccccccccccccccccccccccccccccccccccccccc",repo:{id:200,full_name:"contributor/cmux"}}}]'
      elif [[ "${FAKE_MODE}" == paginated-open-prs && "${api_page}" == 2 ]]; then
        jq -nc '[{number:123,state:"open",base:{ref:"main",repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:200,full_name:"contributor/cmux"}}}]'
      elif [[ "${FAKE_MODE}" == ambiguous-association || ( "${FAKE_MODE}" == late-ambiguous && "$association_call" -gt 1 ) ]]; then
        jq -nc '[
          {number:123,state:"open",base:{ref:"main",repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:200,full_name:"contributor/cmux"}}},
          {number:124,state:"open",base:{ref:"main",repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:200,full_name:"contributor/cmux"}}}
        ]'
      else
        jq -nc --arg head_repo "$live_head_repo" --argjson head_repo_id "$live_head_repo_id" '[{number:123,state:"open",base:{ref:"main",repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:$head_repo_id,full_name:$head_repo}}}]'
      fi
      ;;
    repos/manaflow-ai/cmux/actions/workflows)
      if [[ "${FAKE_MODE}" == paginated-workflows && "${api_page}" == 1 ]]; then
        jq -nc '{workflows:[range(0; 100) | {id:(1000 + .),path:(".github/workflows/other-" + (.|tostring) + ".yml"),state:"active"}]}'
      else
        printf '{"workflows":[{"id":300,"path":".github/workflows/cla.yml","state":"active"}]}\n'
      fi
      ;;
    repos/manaflow-ai/cmux/actions/workflows/300/runs)
      if [[ "${FAKE_MODE}" == full-run-window ]]; then
        if [[ "${api_page}" == 10 ]]; then
          jq -nc --arg path "$run_path" --arg run_sha "$run_sha" --argjson run_prs "$run_prs" \
            '{workflow_runs:([range(0; 99) | {id:(1000 + .),workflow_id:300,path:$path,event:"pull_request_target",status:"completed",conclusion:"success",head_sha:"cccccccccccccccccccccccccccccccccccccccc",head_branch:"other",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:[],created_at:"2026-08-31T07:45:00Z"}] + [{id:400,workflow_id:300,path:$path,event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:$run_prs,created_at:"2026-08-31T07:00:00Z"}])}'
        else
          jq -nc '{workflow_runs:[range(0; 100) | {id:(1000 + .),workflow_id:300,path:".github/workflows/cla.yml",event:"pull_request_target",status:"completed",conclusion:"success",head_sha:"cccccccccccccccccccccccccccccccccccccccc",head_branch:"other",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:[],created_at:"2026-08-31T07:45:00Z"}]}'
        fi
      elif [[ "${FAKE_MODE}" == full-run-window-no-match ]]; then
        jq -nc '{workflow_runs:[range(0; 100) | {id:(1000 + .),workflow_id:300,path:".github/workflows/cla.yml",event:"pull_request_target",status:"completed",conclusion:"success",head_sha:"cccccccccccccccccccccccccccccccccccccccc",head_branch:"other",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:[],created_at:"2026-08-31T07:45:00Z"}]}'
      elif [[ "${FAKE_MODE}" == paginated-runs && "${api_page}" == 1 ]]; then
        jq -nc '{workflow_runs:[range(0; 100) | {id:(1000 + .),workflow_id:300,path:".github/workflows/cla.yml",event:"pull_request_target",status:"completed",conclusion:"success",head_sha:"cccccccccccccccccccccccccccccccccccccccc",head_branch:"other",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:[],created_at:"2026-08-31T07:45:00Z"}]}'
      elif [[ "${FAKE_MODE}" == empty-mismatched-newer ]]; then
        jq -nc '{workflow_runs:[
          {id:400,workflow_id:300,path:".github/workflows/cla.yml",event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",head_branch:"feature",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:[],created_at:"2026-08-31T07:00:00Z"},
          {id:401,workflow_id:300,path:".github/workflows/cla.yml",event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",head_branch:"feature",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:[],created_at:"2026-08-31T07:30:00Z"}
        ]}'
      elif [[ "${FAKE_MODE}" == duplicate-runs ]]; then
        jq -nc --arg head_repo "$run_head_repo" --argjson head_repo_id "$run_head_repo_id" --argjson head_repo_null "$run_head_repository_null" --arg run_sha "$run_sha" --arg path "$run_path" --argjson run_prs "$run_prs" \
          '{workflow_runs:[
            {id:400,workflow_id:300,path:$path,event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:(if $head_repo_null then null else {id:$head_repo_id,full_name:$head_repo} end),pull_requests:$run_prs,created_at:"2026-08-31T07:00:00Z"},
            {id:401,workflow_id:300,path:$path,event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:(if $head_repo_null then null else {id:$head_repo_id,full_name:$head_repo} end),pull_requests:$run_prs,created_at:"2026-08-31T07:30:00Z"}
          ]}'
      else
        jq -nc --arg head_repo "$run_head_repo" --argjson head_repo_id "$run_head_repo_id" --argjson head_repo_null "$run_head_repository_null" --arg run_sha "$run_sha" --arg path "$run_path" --argjson run_prs "$run_prs" \
          '{workflow_runs:[{id:400,workflow_id:300,path:$path,event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:(if $head_repo_null then null else {id:$head_repo_id,full_name:$head_repo} end),pull_requests:$run_prs,created_at:"2026-08-31T07:00:00Z"}]}'
      fi
      ;;
    repos/manaflow-ai/cmux/actions/runs/400|repos/manaflow-ai/cmux/actions/runs/401)
      local run_id=400
      local created_at=2026-08-31T07:00:00Z
      if [[ "$endpoint" == repos/manaflow-ai/cmux/actions/runs/401 ]]; then
        run_id=401
        created_at=2026-08-31T07:30:00Z
      fi
      local detail_sha="$run_sha"
      if [[ "${FAKE_MODE}" == empty-mismatched-newer ]]; then
        if [[ "$run_id" == 400 ]]; then detail_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; else detail_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; fi
      fi
      jq -nc --argjson run_id "$run_id" --arg created_at "$created_at" --arg head_repo "$run_head_repo" --argjson head_repo_id "$run_head_repo_id" --argjson head_repo_null "$run_head_repository_null" --arg run_sha "$detail_sha" --arg path "$run_path" --argjson run_prs "$run_prs" \
        '{id:$run_id,workflow_id:300,path:$path,event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:(if $head_repo_null then null else {id:$head_repo_id,full_name:$head_repo} end),pull_requests:$run_prs,created_at:$created_at}'
      ;;
    repos/manaflow-ai/cmux/actions/runs/400/jobs|repos/manaflow-ai/cmux/actions/runs/401/jobs)
      local run_id=400
      local job_id=500
      if [[ "$endpoint" == repos/manaflow-ai/cmux/actions/runs/401/jobs ]]; then
        run_id=401
        job_id=501
      fi
      local jobs_sha="$run_sha"
      if [[ "${FAKE_MODE}" == empty-mismatched-newer && "$run_id" == 400 ]]; then
        jobs_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      fi
      if [[ "${FAKE_MODE}" == paginated-jobs && "${api_page}" == 1 ]]; then
        jq -nc --argjson run_id "$run_id" --arg run_sha "$jobs_sha" '{jobs:[range(0; 100) | {id:(1000 + .),run_id:$run_id,name:"unrelated",status:"completed",conclusion:"success",head_sha:$run_sha,steps:[]}]}'
      elif [[ "${FAKE_MODE}" == compatibility-failed ]]; then
        jq -nc --argjson run_id "$run_id" --argjson job_id "$job_id" --arg marker "$marker" --arg run_sha "$run_sha" \
          '{jobs:[
            {id:$job_id,run_id:$run_id,name:"CLA Assistant v2",workflow_name:"CLA Assistant v2",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[{name:$marker,status:"completed",conclusion:"success"}]},
            {id:502,run_id:$run_id,name:"CLA Assistant",workflow_name:"CLA Assistant v2",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[]}
          ]}'
      elif [[ "${FAKE_MODE}" == unexpected-failure ]]; then
        jq -nc --argjson run_id "$run_id" --argjson job_id "$job_id" --arg marker "$marker" --arg run_sha "$run_sha" \
          '{jobs:[
            {id:$job_id,run_id:$run_id,name:"CLA Assistant v2",workflow_name:"CLA Assistant v2",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[{name:$marker,status:"completed",conclusion:"success"}]},
            {id:503,run_id:$run_id,name:"Unexpected privileged job",workflow_name:"CLA Assistant v2",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[]}
          ]}'
      elif [[ "${FAKE_MODE}" == cancelled-job ]]; then
        jq -nc --argjson run_id "$run_id" --argjson job_id "$job_id" --arg marker "$marker" --arg run_sha "$run_sha" \
          '{jobs:[
            {id:$job_id,run_id:$run_id,name:"CLA Assistant v2",workflow_name:"CLA Assistant v2",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[{name:$marker,status:"completed",conclusion:"success"}]},
            {id:504,run_id:$run_id,name:"CLA Assistant",workflow_name:"CLA Assistant v2",status:"completed",conclusion:"cancelled",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[]}
          ]}'
      else
        jq -nc --argjson run_id "$run_id" --argjson job_id "$job_id" --arg marker "$marker" --arg run_sha "$jobs_sha" --argjson omit "$omit_job_head_repository" \
          '{jobs:[({id:$job_id,run_id:$run_id,name:"CLA Assistant v2",status:"completed",conclusion:"failure",head_sha:$run_sha,steps:[{name:$marker,status:"completed",conclusion:"success"}]} + (if $omit then {} else {head_repository:null} end))]}'
      fi
      ;;
    repos/manaflow-ai/cmux/actions/jobs/500|repos/manaflow-ai/cmux/actions/jobs/501)
      local job_id=500
      local run_id=400
      if [[ "$endpoint" == repos/manaflow-ai/cmux/actions/jobs/501 ]]; then
        job_id=501
        run_id=401
      fi
      local job_sha="$run_sha"
      if [[ "${FAKE_MODE}" == empty-mismatched-newer && "$run_id" == 400 ]]; then
        job_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      fi
      jq -nc --argjson job_id "$job_id" --argjson run_id "$run_id" --arg marker "$marker" --arg run_sha "$job_sha" --argjson omit "$omit_job_head_repository" \
        '({id:$job_id,run_id:$run_id,name:"CLA Assistant v2",status:"completed",conclusion:"failure",head_sha:$run_sha,steps:[{name:$marker,status:"completed",conclusion:"success"}]} + (if $omit then {} else {head_repository:null} end))'
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
  local expected_post="${5:-}"
  local output status posts comment_author=contributor comment_author_id=300 comment_type=User comment_association=NONE comment_body=recheck signature_recorded=false
  if [[ "$mode" == untrusted-recheck ]]; then
    comment_author=untrusted-user
    comment_author_id=301
  elif [[ "$mode" == recheck-unset-output ]]; then
    signature_recorded=''
  elif [[ "$mode" == external-signer ]]; then
    comment_author=coauthor
    comment_author_id=400
    comment_body='I have read the CLA Document v2.2 and I hereby sign the CLA'
    signature_recorded=true
  elif [[ "$mode" == unrecorded-signer || "$mode" == unbound-signer ]]; then
    comment_author=coauthor
    comment_author_id=400
    comment_body='I have read the CLA Document v2.2 and I hereby sign the CLA'
    if [[ "$mode" == unbound-signer ]]; then
      signature_recorded=true
    fi
  elif [[ "$mode" == wrapped-ledger || "$mode" == oversized-ledger || "$mode" == malformed-ledger ]]; then
    comment_author=coauthor
    comment_author_id=400
    comment_body='I have read the CLA Document v2.2 and I hereby sign the CLA'
    signature_recorded=true
  fi
  : >"$work/posts-$mode"
  printf '0\n' >"$work/association-$mode"
  set +e
  output="$(
    FAKE_MODE="$mode" \
    FAKE_POST_FILE="$work/posts-$mode" \
    FAKE_ASSOC_CALL_FILE="$work/association-$mode" \
    COMMENT_BODY="$comment_body" \
    COMMENT_AUTHOR_ID="$comment_author_id" \
    COMMENT_AUTHOR_LOGIN="$comment_author" \
    COMMENT_AUTHOR_TYPE="$comment_type" \
    COMMENT_AUTHOR_ASSOCIATION="$comment_association" \
    SIGNATURE_RECORDED="$signature_recorded" \
    bash "$rerun_script" 2>&1
  )"
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
  if [[ -n "$expected_post" ]] && ! grep -Fxq "$expected_post" "$work/posts-$mode"; then
    echo "FAIL: $mode did not rerun the expected endpoint '$expected_post'" >&2
    cat "$work/posts-$mode" >&2
    exit 1
  fi
  echo "PASS: $mode"
}

run_case run-association 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case minimal-run-association 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case fork-current 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case association-not-found 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case association-validation-error 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case association-stderr-not-found 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case association-stderr-validation-error 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case association-api-failure 1 "Could not query pull request associations" 0
run_case empty-run-association 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case same-repo-empty 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case association-overflow 1 "Too many pull request associations" 0
run_case paginated-associations 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case paginated-open-prs 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case paginated-workflows 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case paginated-runs 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case full-run-window 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case full-run-window-no-match 1 "workflow-run result window is full" 0
run_case paginated-jobs 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case empty-different-execution-associated 1 "no pull request association and its execution SHA does not match" 0
run_case stale-empty-execution 1 "no pull request association and its execution SHA does not match" 0
run_case empty-mismatched-newer 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case wrong-run-association 0 "No failed CLA run exists for this pull request head" 0
run_case malformed-run-association 1 "malformed pull request associations" 0
run_case invalid-run-association 1 "malformed pull request associations" 0
run_case stale-marker 1 "older workflow generation" 0
run_case unrelated-main-commit 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case wrong-head-repo 0 "No failed CLA run exists for this pull request head" 0
run_case closed-pr 1 "The issue is not an open pull request" 0
run_case retargeted-pr 1 "The live pull request is not valid" 0
run_case ambiguous-association 1 "Expected exactly one open pull request for this head" 0
run_case untrusted-recheck 1 "Only the pull request author or a trusted repository participant" 0
run_case recheck-unset-output 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case suffixed-path 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case late-ambiguous 1 "Expected exactly one open pull request for this head" 0
run_case external-signer 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case unrecorded-signer 1 "did not result in a persisted signature" 0
run_case unbound-signer 1 "signing comment was not the signature persisted" 0
run_case duplicate-runs 0 "Requested rerun for CLA job 501 in workflow run 401" 1 \
  "repos/manaflow-ai/cmux/actions/jobs/501/rerun"
run_case job-missing-head-repository 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case wrapped-ledger 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case oversized-ledger 1 "exceeds the 1 MB limit" 0
run_case malformed-ledger 1 "not valid base64" 0
run_case compatibility-failed 0 "Requested rerun for failed CLA jobs (v2 and compatibility) in workflow run 400" 1 \
  "repos/manaflow-ai/cmux/actions/runs/400/rerun-failed-jobs"
run_case unexpected-failure 1 "unexpected failed job" 0
run_case cancelled-job 1 "cancelled or non-failure job" 0
