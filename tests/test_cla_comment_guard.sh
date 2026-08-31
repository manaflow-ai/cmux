#!/usr/bin/env bash
# Exercise the historical CLA declaration guard against deterministic comment
# fixtures. This prevents the archived action's broad matcher from accepting a
# non-exact comment after a later pull_request_target event.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/cla.yml"
test -f "$WORKFLOW"
command -v jq >/dev/null

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
guard_script="$work/guard.sh"

# Extract and execute the workflow step itself. The fake API below supplies
# only the fields the step consumes, so this is a behavior test rather than a
# source-shape assertion.
awk '
  /^      - name: "Validate historical CLA declarations"/ { in_step=1; next }
  in_step && /^      - name:/ { exit }
  in_step && /^        run: \|$/ { in_run=1; next }
  in_run { sub(/^          /, ""); print }
' "$WORKFLOW" >"$guard_script"
bash -n "$guard_script"

export GH_REPO=manaflow-ai/cmux
export PR_NUMBER=123
export CLA_SIGN_PHRASE='I have read the CLA Document and I hereby sign the CLA'

gh() {
  local endpoint=""
  local arg
  for arg in "$@"; do
    if [[ "$arg" == repos/* ]]; then
      endpoint="$arg"
      break
    fi
  done
  [[ -n "$endpoint" ]] || return 1
  [[ "$endpoint" == repos/manaflow-ai/cmux/issues/123/comments\?per_page=100 ]] || return 1

  case "${FAKE_MODE}" in
    exact)
      jq -nc --arg phrase "$CLA_SIGN_PHRASE" '[[{id:1,body:$phrase,user:{login:"alice"}}]]'
      ;;
    padded)
      jq -nc --arg phrase "  $CLA_SIGN_PHRASE  " '[[{id:1,body:$phrase,user:{login:"alice"}}]]'
      ;;
    lowercase)
      jq -nc --arg phrase "$CLA_SIGN_PHRASE" '[[{id:1,body:($phrase|ascii_downcase),user:{login:"alice"}}]]'
      ;;
    wrapped)
      jq -nc --arg phrase "$CLA_SIGN_PHRASE" '[[{id:1,body:("prefix " + $phrase + " suffix"),user:{login:"alice"}}]]'
      ;;
    unrelated)
      jq -nc '[[{id:1,body:"Thanks for the review",user:{login:"alice"}}]]'
      ;;
    too-many)
      jq -nc --arg phrase "$CLA_SIGN_PHRASE" '[range(0;1001) | {id:.,body:$phrase,user:{login:"alice"}}] | [.]'
      ;;
    api-failure)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}
export -f gh

run_case() {
  local mode="$1"
  local expected_status="$2"
  local expected_text="$3"
  local output status
  set +e
  output="$(FAKE_MODE="$mode" bash "$guard_script" 2>&1)"
  status=$?
  set -e
  if [[ "$status" != "$expected_status" ]]; then
    echo "FAIL: $mode exited $status, expected $expected_status" >&2
    echo "$output" >&2
    exit 1
  fi
  if [[ -n "$expected_text" && "$output" != *"$expected_text"* ]]; then
    echo "FAIL: $mode did not report '$expected_text'" >&2
    echo "$output" >&2
    exit 1
  fi
  echo "PASS: $mode"
}

run_case exact 0 ""
run_case unrelated 0 ""
run_case padded 1 "historical pull request comment"
run_case lowercase 1 "historical pull request comment"
run_case wrapped 1 "historical pull request comment"
run_case too-many 1 "comment limit"
run_case api-failure 1 "Could not query pull request comments"
