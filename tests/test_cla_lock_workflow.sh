#!/usr/bin/env bash
# Exercise the merged-PR lock shell block against deterministic API fixtures.
# This verifies the live identity recheck, rather than only checking YAML text.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/cla.yml"
test -f "$WORKFLOW"
command -v jq >/dev/null
grep -Fq "group: cla-lock-\${{ github.repository }}-\${{ github.event.pull_request.number }}" "$WORKFLOW"
grep -Fq '      issues: write' "$WORKFLOW"
grep -Fq '      pull-requests: read' "$WORKFLOW"

# The merge-lock queue must remain independent from the signature queue. A
# later sign/comment event must not replace a pending merge lock.
lock_block="$(awk '
  /^  LockMergedPullRequest:/ { in_job=1; next }
  in_job && /^  [A-Za-z0-9_]+:/ { exit }
  in_job { print }
' "$WORKFLOW")"
expected_lock_group="group: cla-lock-\${{ github.repository }}-\${{ github.event.pull_request.number }}"
[[ "$lock_block" == *"$expected_lock_group"* ]]
[[ "$lock_block" != *'group: cla-signatures-'* ]]

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
lock_script="$work/lock.sh"

awk '
  /^  LockMergedPullRequest:/ { in_job=1; next }
  in_job && /^        run: \|$/ { in_run=1; next }
  in_run { sub(/^          /, ""); print }
' "$WORKFLOW" >"$lock_script"
bash -n "$lock_script"

export GH_REPO=manaflow-ai/cmux
export PR_NUMBER=123
export EVENT_BASE_REF=main
export EVENT_BASE_REPO=manaflow-ai/cmux
export EVENT_BASE_REPO_ID=100
export EVENT_HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export EVENT_HEAD_REF=feature/review
export EVENT_HEAD_REPO=contributor/cmux
export EVENT_HEAD_REPO_ID=200
export EVENT_OPENER_ID=42
export EVENT_OPENER_LOGIN=contributor

gh() {
  local endpoint=""
  local arg
  for arg in "$@"; do
    if [[ "$arg" == repos/* ]]; then
      endpoint="$arg"
      break
    fi
  done
  [[ -n "$endpoint" ]] || {
    echo "missing API endpoint" >&2
    return 1
  }

  if [[ "${FAKE_MODE:-}" == api-failure && "$endpoint" == repos/*/pulls/123 ]]; then
    return 1
  fi
  if [[ "${FAKE_MODE:-}" == already-locked-read-failure &&
        "$endpoint" == repos/*/pulls/123 &&
        -f "${FAKE_LOCK_FILE}.recheck" ]]; then
    return 1
  fi

  case "$endpoint" in
    repos/manaflow-ai/cmux/pulls/123)
      if [[ "${FAKE_MODE:-}" == already-locked-reopen-after-final-read ]]; then
        local pull_read_count=0
        [[ -f "${FAKE_LOCK_FILE}.pull-reads" ]] && pull_read_count="$(<"${FAKE_LOCK_FILE}.pull-reads")"
        pull_read_count=$((pull_read_count + 1))
        printf '%s\n' "$pull_read_count" >"${FAKE_LOCK_FILE}.pull-reads"
      fi
      local state=closed
      local merged=true
      local base_ref=main
      local head_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      local head_repo=contributor/cmux
      local head_repo_id=200
      local opener_id=42
      local opener_login=contributor
      case "${FAKE_MODE:-}" in
        reopened) state=open; merged=false ;;
        already-locked-reopen-after-read)
          if [[ -f "${FAKE_LOCK_FILE}.recheck" ]]; then
            state=open
            merged=false
          fi
          ;;
        already-locked-reopen-after-final-read)
          if [[ -f "${FAKE_LOCK_FILE}.recheck" &&
                -f "${FAKE_LOCK_FILE}.pull-reads" &&
                "$(<"${FAKE_LOCK_FILE}.pull-reads")" -ge 3 ]]; then
            state=open
            merged=false
          fi
          ;;
        reopen-after-lock)
          if [[ -f "${FAKE_LOCK_FILE}" ]] && [[ "$(<"${FAKE_LOCK_FILE}")" == true ]]; then
            state=open
            merged=false
          fi
          ;;
        retargeted) base_ref=release ;;
        changed-head) head_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
        changed-head-repo) head_repo=attacker/cmux; head_repo_id=201 ;;
        changed-opener) opener_id=43; opener_login=attacker ;;
        malformed-head) head_repo=""; head_repo_id=0 ;;
        deleted-fork) head_repo=""; head_repo_id=0 ;;
      esac
      if [[ "${FAKE_MODE:-}" == deleted-fork ]]; then
        jq -nc \
          --arg state "$state" \
          --argjson merged "$merged" \
          --arg base_ref "$base_ref" \
          --arg head_sha "$head_sha" \
          --arg head_ref "$EVENT_HEAD_REF" \
          --argjson opener_id "$opener_id" \
          --arg opener_login "$opener_login" \
          '{number:123,state:$state,merged:$merged,base:{ref:$base_ref,repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{sha:$head_sha,ref:$head_ref,repo:null},user:{id:$opener_id,login:$opener_login}}'
      else
        jq -nc \
          --arg state "$state" \
          --argjson merged "$merged" \
          --arg base_ref "$base_ref" \
          --arg head_sha "$head_sha" \
          --arg head_ref "$EVENT_HEAD_REF" \
          --arg head_repo "$head_repo" \
          --argjson head_repo_id "$head_repo_id" \
          --argjson opener_id "$opener_id" \
          --arg opener_login "$opener_login" \
          '{number:123,state:$state,merged:$merged,base:{ref:$base_ref,repo:{id:100,full_name:"manaflow-ai/cmux"}},head:{sha:$head_sha,ref:$head_ref,repo:{id:$head_repo_id,full_name:$head_repo}},user:{id:$opener_id,login:$opener_login}}'
      fi
      ;;
    repos/manaflow-ai/cmux/issues/123)
      local locked=false
      [[ -f "${FAKE_LOCK_FILE}" ]] && locked="$(<"${FAKE_LOCK_FILE}")"
      if [[ " $* " == *" --jq .locked "* ]]; then
  if [[ "${FAKE_MODE:-}" == already-locked-reopen-after-read ||
              "${FAKE_MODE:-}" == already-locked-read-failure ||
              "${FAKE_MODE:-}" == already-locked-reopen-after-final-read ]]; then
          printf 'seen\n' >"${FAKE_LOCK_FILE}.recheck"
        fi
        printf '%s\n' "$locked"
      else
        jq -nc --argjson locked "$locked" '{locked:$locked}'
      fi
      ;;
    repos/manaflow-ai/cmux/issues/123/lock)
      if [[ " $* " == *" --method PUT "* ]]; then
        printf '%s\n' "$endpoint" >>"${FAKE_POST_FILE}"
        if [[ "${FAKE_MODE:-}" == lock-failure ]]; then return 1; fi
        printf 'true\n' >"${FAKE_LOCK_FILE}"
      elif [[ " $* " == *" --method DELETE "* ]]; then
        printf '%s\n' "$endpoint" >>"${FAKE_POST_FILE}"
        printf 'false\n' >"${FAKE_LOCK_FILE}"
      fi
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
  local event_head_repo="$EVENT_HEAD_REPO"
  local event_head_repo_id="$EVENT_HEAD_REPO_ID"
  : >"$work/posts-$mode"
  : >"$work/lock-$mode"
  if [[ "$mode" == already-locked || "$mode" == already-locked-reopen-after-read ||
        "$mode" == already-locked-read-failure ||
        "$mode" == already-locked-reopen-after-final-read ]]; then
    printf 'true\n' >"$work/lock-$mode"
  fi
  if [[ "$mode" == deleted-fork || "$mode" == deleted-fork-metadata-mismatch ]]; then
    event_head_repo=""
    event_head_repo_id=""
  fi
  set +e
  output="$(
    FAKE_MODE="$mode" \
    FAKE_POST_FILE="$work/posts-$mode" \
    FAKE_LOCK_FILE="$work/lock-$mode" \
    EVENT_HEAD_REPO="$event_head_repo" \
    EVENT_HEAD_REPO_ID="$event_head_repo_id" \
    bash "$lock_script" 2>&1
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
    echo "FAIL: $mode made $posts lock calls, expected $expected_posts" >&2
    exit 1
  fi
  echo "PASS: $mode"
}

run_case valid 0 "Pull request 123 is locked" 1
run_case already-locked 0 "already locked" 0
run_case reopened 1 "live pull request no longer matches" 0
run_case retargeted 1 "live pull request no longer matches" 0
run_case changed-head 0 "Pull request 123 is locked" 1
run_case changed-head-repo 0 "Pull request 123 is locked" 1
run_case changed-opener 1 "live pull request no longer matches" 0
run_case malformed-head 1 "live pull request no longer matches" 0
run_case deleted-fork 0 "Pull request 123 is locked" 1
run_case deleted-fork-metadata-mismatch 0 "Pull request 123 is locked" 1
run_case api-failure 1 "Could not query the merged pull request" 0
run_case lock-failure 1 "Could not lock the merged pull request" 1
run_case reopen-after-lock 1 "changed after locking; the stale lock was removed" 2
run_case already-locked-reopen-after-read 1 "already-locked pull request changed; the stale lock was removed" 1
run_case already-locked-read-failure 1 "Could not verify the already-locked pull request" 0
run_case already-locked-reopen-after-final-read 1 "already-locked pull request changed; the stale lock was removed" 1
