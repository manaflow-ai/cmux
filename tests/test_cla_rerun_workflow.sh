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
grep -Fq 'uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd' "$WORKFLOW"
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
WORKFLOW="$WORKFLOW" ruby -ryaml <<'RUBY'
workflow = YAML.safe_load(File.read(ENV.fetch("WORKFLOW")), aliases: false)
rerun = workflow.fetch("jobs").fetch("RerunFailedCLA")
expected_group = "cla-rerun-${{ github.repository }}-${{ github.event.issue.number || github.event.pull_request.number }}"
abort "CLA rerun queue is not serialized per pull request" unless
  rerun.fetch("concurrency") == {
    "group" => expected_group,
    "cancel-in-progress" => false
  }
abort "CLA rerun job cannot read check runs" unless rerun.fetch("permissions") == {
  "actions" => "write",
  "checks" => "read",
  "contents" => "read",
  "issues" => "read",
  "pull-requests" => "read"
}
RUBY
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
WORKFLOW_SHA="$(git rev-parse HEAD)"
export WORKFLOW_SHA
export CLA_GENERATION=v2.2-action-212a0f2dd659b24b48a30ba35966e06dc41736af
export TARGET_EVENT=pull_request_target
export TARGET_BASE_REF=main
export SIGNATURE_RECORDED=false

# This stub models the API fields used by the rerun guard. In particular, a
# fork-only commit has no result from /commits/:sha/pulls, while the workflow
# run still carries head_repository identity. GitHub may report the source PR
# SHA or a different execution SHA on a pull_request_target run, so this fixture
# keeps the live PR head at `aaaa...` and the normal selected run/job execution
# SHA at the live base `cccc...`. A production-shaped empty association is accepted only when the
# run has complete source metadata and can be bound to the live PR. A source
# or execution SHA then needs the matching live association and check. A
# null-repository, stale-base, or mismatched metadata run must fail closed.
gh() {
  local endpoint=""
  local api_page=1
  local api_filter=""
  local api_check_name=""
  local api_app_id=""
  local arg
  for arg in "$@"; do
    if [[ "$arg" == page=* ]]; then
      api_page="${arg#page=}"
    fi
    if [[ "$arg" == filter=* ]]; then
      api_filter="${arg#filter=}"
    fi
    if [[ "$arg" == check_name=* ]]; then
      api_check_name="${arg#check_name=}"
    fi
    if [[ "$arg" == app_id=* ]]; then
      api_app_id="${arg#app_id=}"
    fi
    if [[ "$arg" == repos/* ]]; then
      endpoint="$arg"
    fi
  done
  [[ -n "$endpoint" ]] || {
    echo "missing API endpoint" >&2
    return 1
  }
  if [[ "$endpoint" == repos/manaflow-ai/cmux/commits/*/check-runs &&
        "$api_filter" != all ]]; then
    echo "check-runs lookup must request filter=all" >&2
    return 1
  fi
  if [[ "$endpoint" == repos/manaflow-ai/cmux/commits/*/check-runs &&
        ( "$api_check_name" != "CLA Assistant v3" && "$api_check_name" != "CLA Assistant" ||
          "$api_app_id" != 15368 ) ]]; then
    echo "check-runs lookup must bind the expected CLA check and app" >&2
    return 1
  fi
  if [[ "$endpoint" == repos/manaflow-ai/cmux/commits/*/pulls &&
        " $* " != *" --method GET "* ]]; then
    echo "commit association lookup must use GET" >&2
    return 1
  fi
  local live_state=open
  local live_base=main
  local live_base_sha=cccccccccccccccccccccccccccccccccccccccc
  local live_head_repo=contributor/cmux
  local live_head_repo_id=200
  local run_head_repo=contributor/cmux
  local run_head_repo_id=200
  local run_head_repository_null=false
  local omit_job_head_repository=false
  local run_sha=cccccccccccccccccccccccccccccccccccccccc
  local older_run_sha="${run_sha}"
  local newer_run_sha="${run_sha}"
  local marker="CLA generation ${CLA_GENERATION}"
  local run_path=.github/workflows/cla.yml
  local run_name='CLA Assistant v3'
  local check_app_id=15368
  local fetched_comment_association="${FAKE_COMMENT_ASSOCIATION:-${COMMENT_AUTHOR_ASSOCIATION}}"
  local run_prs='[{"number":123,"base":{"ref":"main","sha":"cccccccccccccccccccccccccccccccccccccccc","repo":{"id":100,"full_name":"manaflow-ai/cmux"}},"head":{"ref":"feature","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"id":200,"full_name":"contributor/cmux"}}}]'
  local ledger_id=400
  local ledger_login=coauthor
  local ledger_comment_id=900

  case "${FAKE_MODE}" in
    stale-marker) marker="CLA generation v2.2-action-0000000000000000000000000000000000000000" ;;
    unrelated-main-commit) marker="CLA generation ${CLA_GENERATION}" ;;
    wrong-head-repo) run_head_repo=attacker/cmux; run_head_repo_id=201; run_prs='[]' ;;
    stale-base-association)
      run_prs='[{"number":123,"base":{"ref":"main","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"id":100,"full_name":"manaflow-ai/cmux"}},"head":{"ref":"feature","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"id":200,"full_name":"contributor/cmux"}}}]'
      ;;
    association-overflow) run_prs='[]' ;;
    fork-current|empty-run-association) run_prs='[]'; run_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
    empty-different-execution-associated|empty-different-execution-source-mismatch|empty-different-execution-check-bound|empty-different-execution-check-mismatch)
      run_prs='[]'
      run_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      ;;
    empty-different-execution-source-bound)
      run_prs='[]'
      run_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      live_base_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      ;;
    check-wrong-app|check-wrong-app-id|check-wrong-sha|check-wrong-job|check-missing-final|oversized-check-response)
      run_prs='[]'
      run_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      live_base_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      ;;
    wrong-workflow-name) run_name='Untrusted workflow' ;;
    fork-null-head-check-bound|fork-null-head-no-check)
      run_prs='[]'
      run_head_repository_null=true
      live_base_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      ;;
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
    binding-mode-newer)
      older_run_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      newer_run_sha=cccccccccccccccccccccccccccccccccccccccc
      ;;
    stale-comment-association) fetched_comment_association=NONE ;;
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
      if [[ "${FAKE_MODE}" == oversized-api-response ]]; then
        printf '%s' '{"state":"open","pull_request":{"url":"https://api.github.com/repos/manaflow-ai/cmux/pulls/123"},"padding":"'
        head -c 2100000 /dev/zero | tr '\0' 'A'
        printf '%s\n' '"}'
      else
        jq -nc --arg state "$live_state" '{state:$state,pull_request:{url:"https://api.github.com/repos/manaflow-ai/cmux/pulls/123"}}'
      fi
      ;;
    repos/manaflow-ai/cmux/issues/comments/900)
      jq -nc \
        --arg body "${COMMENT_BODY}" \
        --argjson author_id "${COMMENT_AUTHOR_ID}" \
        --arg author_login "${COMMENT_AUTHOR_LOGIN}" \
        --arg author_type "${COMMENT_AUTHOR_TYPE}" \
        --arg author_association "${fetched_comment_association}" \
        --arg created_at "${COMMENT_CREATED_AT}" \
        '{issue_url:"https://api.github.com/repos/manaflow-ai/cmux/issues/123",body:$body,user:{id:$author_id,login:$author_login,type:$author_type},author_association:$author_association,created_at:$created_at,updated_at:$created_at}'
      ;;
    repos/manaflow-ai/cmux/pulls/123)
      jq -nc --arg state "$live_state" --arg base "$live_base" --arg base_sha "$live_base_sha" --arg head_repo "$live_head_repo" --argjson head_repo_id "$live_head_repo_id" \
        '{number:123,state:$state,user:{id:300,login:"contributor"},base:{ref:$base,sha:$base_sha,repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:$head_repo_id,full_name:$head_repo}}}'
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
      elif [[ "${FAKE_MODE}" == empty-different-execution-source-bound ||
              "${FAKE_MODE}" == empty-different-execution-source-mismatch ]]; then
        local commit_sha="${endpoint#repos/manaflow-ai/cmux/commits/}"
        commit_sha="${commit_sha%/pulls}"
        if [[ "${FAKE_MODE}" == empty-different-execution-source-bound &&
              "${commit_sha}" == bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]]; then
          jq -nc --arg base_sha "$live_base_sha" '[{number:123,base:{ref:"main",sha:$base_sha,repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:200,full_name:"contributor/cmux"}}}]'
        elif [[ "${FAKE_MODE}" == empty-different-execution-source-mismatch &&
                "${commit_sha}" == bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]]; then
          jq -nc --arg base_sha "$live_base_sha" '[{number:124,base:{ref:"main",sha:$base_sha,repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:200,full_name:"contributor/cmux"}}}]'
        else
          printf '[]\n'
        fi
      elif [[ "${FAKE_MODE}" == association-overflow ]]; then
        jq -nc --arg base_sha "$live_base_sha" '[range(0; 100) | {number:(1000 + .),base:{ref:"main",sha:$base_sha,repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:200,full_name:"contributor/cmux"}}}]'
      elif [[ "${FAKE_MODE}" == paginated-associations && "${api_page}" == 1 ]]; then
        jq -nc --arg base_sha "$live_base_sha" '[range(0; 100) | {number:(1000 + .),base:{ref:"main",sha:$base_sha,repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"cccccccccccccccccccccccccccccccccccccccc",repo:{id:200,full_name:"contributor/cmux"}}}]'
      elif [[ "${FAKE_MODE}" == paginated-associations && "${api_page}" == 2 ]]; then
          jq -nc --arg base_sha "$live_base_sha" '[{number:123,base:{ref:"main",sha:$base_sha,repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:200,full_name:"contributor/cmux"}}}]'
      elif [[ "${FAKE_MODE}" == same-repo-empty ]]; then
        jq -nc --arg base_sha "$live_base_sha" '[{number:123,base:{ref:"main",sha:$base_sha,repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:100,full_name:"manaflow-ai/cmux"}}}]'
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
        jq -nc --arg base_sha "$live_base_sha" '[range(0; 100) | {number:(1000 + .),state:"open",base:{ref:"main",sha:$base_sha,repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"cccccccccccccccccccccccccccccccccccccccc",repo:{id:200,full_name:"contributor/cmux"}}}]'
      elif [[ "${FAKE_MODE}" == paginated-open-prs && "${api_page}" == 2 ]]; then
        jq -nc --arg base_sha "$live_base_sha" '[{number:123,state:"open",base:{ref:"main",sha:$base_sha,repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:200,full_name:"contributor/cmux"}}}]'
      elif [[ "${FAKE_MODE}" == empty-different-execution-source-mismatch ]]; then
        jq -nc --arg base_sha "$live_base_sha" '[{number:124,state:"open",base:{ref:"main",sha:$base_sha,repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:200,full_name:"contributor/cmux"}}}]'
      elif [[ "${FAKE_MODE}" == ambiguous-association || ( "${FAKE_MODE}" == late-ambiguous && "$association_call" -gt 1 ) ]]; then
        jq -nc '[
          {number:123,state:"open",base:{ref:"main",sha:"cccccccccccccccccccccccccccccccccccccccc",repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:200,full_name:"contributor/cmux"}}},
          {number:124,state:"open",base:{ref:"main",sha:"cccccccccccccccccccccccccccccccccccccccc",repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:200,full_name:"contributor/cmux"}}}
        ]'
      else
        jq -nc --arg base_sha "$live_base_sha" --arg head_repo "$live_head_repo" --argjson head_repo_id "$live_head_repo_id" '[{number:123,state:"open",base:{ref:"main",sha:$base_sha,repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{ref:"feature",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{id:$head_repo_id,full_name:$head_repo}}}]'
      fi
      ;;
    repos/manaflow-ai/cmux/commits/*/check-runs)
      local check_call=1
      local check_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      local check_app_slug=github-actions
      local check_id=9000
      local check_name="CLA Assistant v3"
      local check_details="https://github.com/manaflow-ai/cmux/actions/runs/400/job/500"
      local check_prefix=repos/manaflow-ai/cmux/commits/
      check_sha="${endpoint#"${check_prefix}"}"
      check_sha="${check_sha%/check-runs}"
      if [[ "${FAKE_MODE}" == binding-mode-newer ]]; then
        check_details="https://github.com/manaflow-ai/cmux/actions/runs/401/job/501"
      fi
      if [[ -n "${FAKE_CHECK_CALL_FILE:-}" ]]; then
        if [[ -s "${FAKE_CHECK_CALL_FILE}" ]]; then
          read -r check_call <"${FAKE_CHECK_CALL_FILE}"
          check_call=$((check_call + 1))
        fi
        printf '%s\n' "$check_call" >"${FAKE_CHECK_CALL_FILE}"
      fi
      if [[ "${FAKE_MODE}" == fork-null-head-no-check ||
            "${FAKE_MODE}" == empty-different-execution-check-mismatch ||
            "${FAKE_MODE}" == empty-different-execution-associated ||
            "${FAKE_MODE}" == stale-empty-execution ||
            "${FAKE_MODE}" == check-missing-final && "${check_call}" -gt 1 ]]; then
        printf '%s\n' '{"check_runs":[]}'
      elif [[ "${FAKE_MODE}" == empty-different-execution-check-bound ]]; then
        printf '%s\n' '{"check_runs":[{"id":9000,"name":"CLA Assistant v3","status":"completed","conclusion":"failure","head_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","app":{"id":15368,"slug":"github-actions"},"details_url":"https://github.com/manaflow-ai/cmux/actions/runs/400/job/500"}]}'
      elif [[ "${FAKE_MODE}" == oversized-check-response ]]; then
        printf '%s' '{"check_runs":[{"id":9000,"name":"CLA Assistant v3","status":"completed","conclusion":"failure","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","app":{"id":15368,"slug":"github-actions"},"details_url":"https://github.com/manaflow-ai/cmux/actions/runs/400/job/500","padding":"'
        head -c 2100000 /dev/zero | tr '\0' 'A'
        printf '%s\n' '"}]}'
      elif [[ "${FAKE_MODE}" == check-wrong-app ]]; then
        printf '%s\n' '{"check_runs":[{"id":9000,"name":"CLA Assistant v3","status":"completed","conclusion":"failure","head_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","app":{"id":15368,"slug":"untrusted-app"},"details_url":"https://github.com/manaflow-ai/cmux/actions/runs/400/job/500"}]}'
      elif [[ "${FAKE_MODE}" == check-wrong-app-id ]]; then
        printf '%s\n' '{"check_runs":[{"id":9000,"name":"CLA Assistant v3","status":"completed","conclusion":"failure","head_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","app":{"id":999,"slug":"github-actions"},"details_url":"https://github.com/manaflow-ai/cmux/actions/runs/400/job/500"}]}'
      elif [[ "${FAKE_MODE}" == check-wrong-sha ]]; then
        printf '%s\n' '{"check_runs":[{"id":9000,"name":"CLA Assistant v3","status":"completed","conclusion":"failure","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","app":{"id":15368,"slug":"github-actions"},"details_url":"https://github.com/manaflow-ai/cmux/actions/runs/400/job/500"}]}'
      elif [[ "${FAKE_MODE}" == check-wrong-job ]]; then
        printf '%s\n' '{"check_runs":[{"id":9000,"name":"CLA Assistant v3","status":"completed","conclusion":"failure","head_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","app":{"id":15368,"slug":"github-actions"},"details_url":"https://github.com/manaflow-ai/cmux/actions/runs/400/job/999"}]}'
      elif [[ "${FAKE_MODE}" == duplicate-runs ]]; then
        jq -nc --arg sha "$check_sha" '{id:9000,check_runs:[{id:9000,name:"CLA Assistant v3",status:"completed",conclusion:"failure",head_sha:$sha,app:{id:15368,slug:"github-actions"},details_url:"https://github.com/manaflow-ai/cmux/actions/runs/401/job/501"}]}'
      else
        jq -nc --arg sha "$check_sha" --arg slug "$check_app_slug" --argjson app_id "$check_app_id" --argjson id "$check_id" --arg name "$check_name" --arg details "$check_details" \
          '{check_runs:[{id:$id,name:$name,status:"completed",conclusion:"failure",head_sha:$sha,app:{id:$app_id,slug:$slug},details_url:$details}]}'
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
          jq -nc --arg path "$run_path" --arg name "$run_name" --arg run_sha "$run_sha" --argjson run_prs "$run_prs" \
            '{workflow_runs:([range(0; 99) | {id:(1000 + .),workflow_id:300,name:$name,path:$path,event:"pull_request_target",status:"completed",conclusion:"success",head_sha:"cccccccccccccccccccccccccccccccccccccccc",head_branch:"other",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:[],created_at:"2026-08-31T07:45:00Z"}] + [{id:400,workflow_id:300,name:$name,path:$path,event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:$run_prs,created_at:"2026-08-31T07:00:00Z"}])}'
        else
          jq -nc --arg name "$run_name" '{workflow_runs:[range(0; 100) | {id:(1000 + .),workflow_id:300,name:$name,path:".github/workflows/cla.yml",event:"pull_request_target",status:"completed",conclusion:"success",head_sha:"cccccccccccccccccccccccccccccccccccccccc",head_branch:"other",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:[],created_at:"2026-08-31T07:45:00Z"}]}'
        fi
      elif [[ "${FAKE_MODE}" == full-run-window-no-match ]]; then
        jq -nc --arg name "$run_name" '{workflow_runs:[range(0; 100) | {id:(1000 + .),workflow_id:300,name:$name,path:".github/workflows/cla.yml",event:"pull_request_target",status:"completed",conclusion:"success",head_sha:"cccccccccccccccccccccccccccccccccccccccc",head_branch:"other",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:[],created_at:"2026-08-31T07:45:00Z"}]}'
      elif [[ "${FAKE_MODE}" == paginated-runs && "${api_page}" == 1 ]]; then
        jq -nc --arg name "$run_name" '{workflow_runs:[range(0; 100) | {id:(1000 + .),workflow_id:300,name:$name,path:".github/workflows/cla.yml",event:"pull_request_target",status:"completed",conclusion:"success",head_sha:"cccccccccccccccccccccccccccccccccccccccc",head_branch:"other",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:[],created_at:"2026-08-31T07:45:00Z"}]}'
      elif [[ "${FAKE_MODE}" == empty-mismatched-newer ]]; then
        jq -nc --arg name "$run_name" '{workflow_runs:[
          {id:400,workflow_id:300,name:$name,path:".github/workflows/cla.yml",event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",head_branch:"feature",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:[],created_at:"2026-08-31T07:00:00Z"},
          {id:401,workflow_id:300,name:$name,path:".github/workflows/cla.yml",event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",head_branch:"feature",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:[],created_at:"2026-08-31T07:30:00Z"}
        ]}'
      elif [[ "${FAKE_MODE}" == binding-mode-newer ]]; then
        jq -nc --arg name "$run_name" --arg older_sha "$older_run_sha" --arg newer_sha "$newer_run_sha" --argjson run_prs "$run_prs" '{workflow_runs:[
          {id:400,workflow_id:300,name:$name,path:".github/workflows/cla.yml",event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:$older_sha,head_branch:"feature",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:$run_prs,created_at:"2026-08-31T07:00:00Z"},
          {id:401,workflow_id:300,name:$name,path:".github/workflows/cla.yml",event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:$newer_sha,head_branch:"feature",head_repository:{id:200,full_name:"contributor/cmux"},pull_requests:[],created_at:"2026-08-31T07:30:00Z"}
        ]}'
      elif [[ "${FAKE_MODE}" == duplicate-runs ]]; then
        jq -nc --arg head_repo "$run_head_repo" --argjson head_repo_id "$run_head_repo_id" --argjson head_repo_null "$run_head_repository_null" --arg run_sha "$run_sha" --arg path "$run_path" --arg name "$run_name" --argjson run_prs "$run_prs" \
          '{workflow_runs:[
            {id:400,workflow_id:300,name:$name,path:$path,event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:(if $head_repo_null then null else {id:$head_repo_id,full_name:$head_repo} end),pull_requests:$run_prs,created_at:"2026-08-31T07:00:00Z"},
            {id:401,workflow_id:300,name:$name,path:$path,event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:(if $head_repo_null then null else {id:$head_repo_id,full_name:$head_repo} end),pull_requests:$run_prs,created_at:"2026-08-31T07:30:00Z"}
          ]}'
      else
        jq -nc --arg head_repo "$run_head_repo" --argjson head_repo_id "$run_head_repo_id" --argjson head_repo_null "$run_head_repository_null" --arg run_sha "$run_sha" --arg path "$run_path" --arg name "$run_name" --argjson run_prs "$run_prs" \
          '{workflow_runs:[{id:400,workflow_id:300,name:$name,path:$path,event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:(if $head_repo_null then null else {id:$head_repo_id,full_name:$head_repo} end),pull_requests:$run_prs,created_at:"2026-08-31T07:00:00Z"}]}'
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
      local detail_prs="$run_prs"
      if [[ "${FAKE_MODE}" == empty-mismatched-newer ]]; then
        if [[ "$run_id" == 400 ]]; then detail_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; else detail_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; fi
      fi
      if [[ "${FAKE_MODE}" == binding-mode-newer && "$run_id" == 401 ]]; then
        detail_sha="${newer_run_sha}"
        detail_prs='[]'
      elif [[ "${FAKE_MODE}" == binding-mode-newer && "$run_id" == 400 ]]; then
        detail_sha="${older_run_sha}"
      fi
      jq -nc --argjson run_id "$run_id" --arg created_at "$created_at" --arg head_repo "$run_head_repo" --argjson head_repo_id "$run_head_repo_id" --argjson head_repo_null "$run_head_repository_null" --arg run_sha "$detail_sha" --arg path "$run_path" --arg name "$run_name" --argjson run_prs "$detail_prs" \
        '{id:$run_id,workflow_id:300,name:$name,path:$path,event:"pull_request_target",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:(if $head_repo_null then null else {id:$head_repo_id,full_name:$head_repo} end),pull_requests:$run_prs,created_at:$created_at}'
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
      elif [[ "${FAKE_MODE}" == empty-mismatched-newer && "$run_id" == 401 ]]; then
        jobs_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      elif [[ "${FAKE_MODE}" == binding-mode-newer && "$run_id" == 400 ]]; then
        jobs_sha="${older_run_sha}"
      elif [[ "${FAKE_MODE}" == binding-mode-newer && "$run_id" == 401 ]]; then
        jobs_sha="${newer_run_sha}"
      fi
      if [[ "${FAKE_MODE}" == paginated-jobs && "${api_page}" == 1 ]]; then
        jq -nc --argjson run_id "$run_id" --arg run_sha "$jobs_sha" '{jobs:[range(0; 100) | {id:(1000 + .),run_id:$run_id,name:"unrelated",status:"completed",conclusion:"success",head_sha:$run_sha,steps:[]}]}'
      elif [[ "${FAKE_MODE}" == compatibility-failed ]]; then
        jq -nc --argjson run_id "$run_id" --argjson job_id "$job_id" --arg marker "$marker" --arg run_sha "$run_sha" \
          '{jobs:[
            {id:$job_id,run_id:$run_id,name:"CLA Assistant v3",workflow_name:"CLA Assistant v3",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[{name:$marker,status:"completed",conclusion:"failure"}]},
            {id:502,run_id:$run_id,name:"CLA Assistant",workflow_name:"CLA Assistant v3",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[{name:"Mirror CLA Assistant compatibility result",status:"completed",conclusion:"failure"}]}
          ]}'
      elif [[ "${FAKE_MODE}" == signing-stale-writer ]]; then
        jq -nc --argjson run_id "$run_id" --argjson job_id "$job_id" --arg marker "$marker" --arg run_sha "$run_sha" \
          '{jobs:[
            {id:505,run_id:$run_id,name:"CLA ledger writer",workflow_name:"CLA Assistant v3",status:"completed",conclusion:"success",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[]},
            {id:$job_id,run_id:$run_id,name:"CLA Assistant v3",workflow_name:"CLA Assistant v3",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[{name:$marker,status:"completed",conclusion:"failure"}]},
            {id:506,run_id:$run_id,name:"CLA Assistant",workflow_name:"CLA Assistant v3",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[{name:"Mirror CLA Assistant compatibility result",status:"completed",conclusion:"failure"}]}
          ]}'
      elif [[ "${FAKE_MODE}" == writer-failed ]]; then
        jq -nc --argjson run_id "$run_id" --argjson job_id "$job_id" --arg marker "$marker" --arg run_sha "$run_sha" \
          '{jobs:[
            {id:505,run_id:$run_id,name:"CLA ledger writer",workflow_name:"CLA Assistant v3",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[]},
            {id:$job_id,run_id:$run_id,name:"CLA Assistant v3",workflow_name:"CLA Assistant v3",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[{name:$marker,status:"completed",conclusion:"failure"}]},
            {id:506,run_id:$run_id,name:"CLA Assistant",workflow_name:"CLA Assistant v3",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[{name:"Mirror CLA Assistant compatibility result",status:"completed",conclusion:"failure"}]}
          ]}'
      elif [[ "${FAKE_MODE}" == writer-only-failed ]]; then
        jq -nc --argjson run_id "$run_id" --argjson job_id "$job_id" --arg marker "$marker" --arg run_sha "$run_sha" \
          '{jobs:[
            {id:505,run_id:$run_id,name:"CLA ledger writer",workflow_name:"CLA Assistant v3",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[]},
            {id:$job_id,run_id:$run_id,name:"CLA Assistant v3",workflow_name:"CLA Assistant v3",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[{name:$marker,status:"completed",conclusion:"failure"}]}
          ]}'
      elif [[ "${FAKE_MODE}" == unexpected-failure ]]; then
        jq -nc --argjson run_id "$run_id" --argjson job_id "$job_id" --arg marker "$marker" --arg run_sha "$run_sha" \
          '{jobs:[
            {id:$job_id,run_id:$run_id,name:"CLA Assistant v3",workflow_name:"CLA Assistant v3",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[{name:$marker,status:"completed",conclusion:"failure"}]},
            {id:503,run_id:$run_id,name:"Unexpected privileged job",workflow_name:"CLA Assistant v3",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[]}
          ]}'
      elif [[ "${FAKE_MODE}" == cancelled-job ]]; then
        jq -nc --argjson run_id "$run_id" --argjson job_id "$job_id" --arg marker "$marker" --arg run_sha "$run_sha" \
          '{jobs:[
            {id:$job_id,run_id:$run_id,name:"CLA Assistant v3",workflow_name:"CLA Assistant v3",status:"completed",conclusion:"failure",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[{name:$marker,status:"completed",conclusion:"failure"}]},
            {id:504,run_id:$run_id,name:"CLA Assistant",workflow_name:"CLA Assistant v3",status:"completed",conclusion:"cancelled",head_sha:$run_sha,head_branch:"feature",head_repository:null,steps:[]}
          ]}'
      else
        jq -nc --argjson run_id "$run_id" --argjson job_id "$job_id" --arg marker "$marker" --arg run_sha "$jobs_sha" --argjson omit "$omit_job_head_repository" \
          '{jobs:[({id:$job_id,run_id:$run_id,name:"CLA Assistant v3",status:"completed",conclusion:"failure",head_sha:$run_sha,steps:[{name:$marker,status:"completed",conclusion:"failure"}]} + (if $omit then {} else {head_repository:null} end))]}'
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
      elif [[ "${FAKE_MODE}" == empty-mismatched-newer && "$run_id" == 401 ]]; then
        job_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      elif [[ "${FAKE_MODE}" == binding-mode-newer && "$run_id" == 400 ]]; then
        job_sha="${older_run_sha}"
      elif [[ "${FAKE_MODE}" == binding-mode-newer && "$run_id" == 401 ]]; then
        job_sha="${newer_run_sha}"
      fi
      jq -nc --argjson job_id "$job_id" --argjson run_id "$run_id" --arg marker "$marker" --arg run_sha "$job_sha" --argjson omit "$omit_job_head_repository" \
        '({id:$job_id,run_id:$run_id,name:"CLA Assistant v3",status:"completed",conclusion:"failure",head_sha:$run_sha,steps:[{name:$marker,status:"completed",conclusion:"failure"}]} + (if $omit then {} else {head_repository:null} end))'
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
  local expected_checks="${6:-}"
  local output status posts comment_author=contributor comment_author_id=300 comment_type=User comment_association=NONE fetched_comment_association=NONE comment_body=recheck signature_recorded=false generation="${CLA_GENERATION}"
  if [[ -n "${ONLY_MODE:-}" && "${ONLY_MODE}" != "${mode}" ]]; then
    return 0
  fi
  if [[ "$mode" == untrusted-recheck ]]; then
    comment_author=untrusted-user
    comment_author_id=301
  elif [[ "$mode" == recheck-unset-output ]]; then
    signature_recorded=''
  elif [[ "$mode" == external-signer || "$mode" == signing-stale-writer ]]; then
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
  elif [[ "$mode" == alternate-generation ]]; then
    generation=v2.2-action-deadbeef
  elif [[ "$mode" == malformed-comment-login ]]; then
    comment_author=$'contributor\nattacker'
  elif [[ "$mode" == stale-comment-association ]]; then
    comment_author=untrusted-user
    comment_author_id=301
    comment_association=OWNER
    fetched_comment_association=NONE
  fi
  : >"$work/posts-$mode"
  printf '0\n' >"$work/association-$mode"
  printf '0\n' >"$work/check-$mode"
  set +e
  output="$(
    FAKE_MODE="$mode" \
    FAKE_POST_FILE="$work/posts-$mode" \
    FAKE_ASSOC_CALL_FILE="$work/association-$mode" \
    FAKE_CHECK_CALL_FILE="$work/check-$mode" \
    COMMENT_BODY="$comment_body" \
    COMMENT_AUTHOR_ID="$comment_author_id" \
    COMMENT_AUTHOR_LOGIN="$comment_author" \
    COMMENT_AUTHOR_TYPE="$comment_type" \
    COMMENT_AUTHOR_ASSOCIATION="$comment_association" \
    FAKE_COMMENT_ASSOCIATION="$fetched_comment_association" \
    SIGNATURE_RECORDED="$signature_recorded" \
    CLA_GENERATION="$generation" \
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
  if [[ -n "$expected_checks" ]]; then
    local checks=0
    if [[ -s "$work/check-$mode" ]]; then
      read -r checks <"$work/check-$mode"
    fi
    if [[ "$checks" != "$expected_checks" ]]; then
      echo "FAIL: $mode made $checks check lookups, expected $expected_checks" >&2
      exit 1
    fi
  fi
  echo "PASS: $mode"
}

run_case run-association 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case oversized-api-response 1 "Could not query the issue" 0
run_case minimal-run-association 0 "No failed CLA run exists for this pull request head" 0
run_case fork-current 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case association-not-found 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case association-validation-error 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case association-stderr-not-found 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case association-stderr-validation-error 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case association-api-failure 1 "Could not query pull request associations" 0
run_case empty-run-association 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case same-repo-empty 1 "no pull request association with complete source metadata" 0
run_case association-overflow 1 "Too many pull request associations" 0
run_case paginated-associations 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case paginated-open-prs 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case paginated-workflows 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case paginated-runs 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case full-run-window 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case full-run-window-no-match 1 "workflow-run result window is full" 0
run_case paginated-jobs 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case empty-different-execution-associated 1 "No failed CLA check is bound to the exact pull request source head" 0 "" 1
run_case empty-different-execution-source-bound 0 "Requested rerun for CLA job 500 in workflow run 400" 1 "" 2
run_case empty-different-execution-source-mismatch 1 "live head is associated with a different pull request" 0
run_case empty-different-execution-check-bound 1 "No failed CLA check is bound to the exact pull request source head" 0 "" 1
run_case empty-different-execution-check-mismatch 1 "No failed CLA check is bound to the exact pull request source head" 0 "" 1
run_case fork-null-head-check-bound 1 "no pull request association with complete source metadata" 0
run_case fork-null-head-no-check 1 "no pull request association with complete source metadata" 0
run_case check-wrong-app 1 "No failed CLA check is bound" 0 "" 1
run_case check-wrong-app-id 1 "No failed CLA check is bound" 0 "" 1
run_case check-wrong-sha 1 "No failed CLA check is bound" 0 "" 1
run_case check-wrong-job 1 "No failed CLA check is bound" 0 "" 1
run_case check-missing-final 1 "No failed CLA check is bound" 0 "" 2
run_case oversized-check-response 1 "Could not query checks for the selected CLA execution" 0 "" 1
run_case stale-empty-execution 1 "No failed CLA check is bound to the exact pull request source head" 0 "" 1
run_case empty-mismatched-newer 1 "No failed CLA check is bound to the exact pull request source head" 0 "" 1
run_case wrong-run-association 0 "No failed CLA run exists for this pull request head" 0
run_case malformed-run-association 1 "malformed pull request associations" 0
run_case invalid-run-association 1 "malformed pull request associations" 0
run_case stale-marker 1 "older workflow generation" 0
run_case unrelated-main-commit 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case wrong-head-repo 1 "no pull request association with complete source metadata" 0
run_case closed-pr 1 "The issue is not an open pull request" 0
run_case retargeted-pr 1 "The live pull request is not valid" 0
run_case ambiguous-association 1 "Expected exactly one open pull request for this head" 0
run_case untrusted-recheck 1 "Only the pull request author or a trusted repository participant" 0
run_case recheck-unset-output 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case suffixed-path 0 "No failed CLA run exists for this pull request head" 0
run_case wrong-workflow-name 0 "No failed CLA run exists for this pull request head" 0
run_case stale-base-association 1 "outdated or malformed pull request base SHA" 0
run_case alternate-generation 1 "Unexpected CLA generation marker" 0
run_case malformed-comment-login 1 "Comment author is malformed" 0
run_case late-ambiguous 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case external-signer 0 "Requested rerun for CLA workflow run 400 (refresh writer and result jobs)" 1 \
  "repos/manaflow-ai/cmux/actions/runs/400/rerun"
run_case signing-stale-writer 0 "Requested rerun for CLA workflow run 400 (refresh writer and result jobs)" 1 \
  "repos/manaflow-ai/cmux/actions/runs/400/rerun"
run_case unrecorded-signer 1 "did not result in a persisted signature" 0
run_case unbound-signer 1 "signing comment was not the signature persisted" 0
run_case duplicate-runs 0 "Requested rerun for CLA job 501 in workflow run 401" 1 \
  "repos/manaflow-ai/cmux/actions/jobs/501/rerun"
run_case binding-mode-newer 0 "Requested rerun for CLA job 501 in workflow run 401" 1 \
  "repos/manaflow-ai/cmux/actions/jobs/501/rerun"
run_case stale-comment-association 1 "Only the pull request author or a trusted repository participant" 0
run_case job-missing-head-repository 0 "Requested rerun for CLA job 500 in workflow run 400" 1
run_case wrapped-ledger 0 "Requested rerun for CLA workflow run 400 (refresh writer and result jobs)" 1 \
  "repos/manaflow-ai/cmux/actions/runs/400/rerun"
run_case oversized-ledger 1 "exceeds the 1 MB limit" 0
run_case malformed-ledger 1 "not valid base64" 0
run_case compatibility-failed 0 "Requested rerun for failed CLA result jobs (writer, v3, and compatibility) in workflow run 400" 1 \
  "repos/manaflow-ai/cmux/actions/runs/400/rerun-failed-jobs"
run_case writer-failed 0 "Requested rerun for failed CLA result jobs (writer, v3, and compatibility) in workflow run 400" 1 \
  "repos/manaflow-ai/cmux/actions/runs/400/rerun-failed-jobs"
run_case writer-only-failed 0 "Requested rerun for failed CLA result jobs (writer, v3, and compatibility) in workflow run 400" 1 \
  "repos/manaflow-ai/cmux/actions/runs/400/rerun-failed-jobs"
run_case unexpected-failure 1 "unexpected failed job" 0
run_case cancelled-job 1 "cancelled or non-failure job" 0
