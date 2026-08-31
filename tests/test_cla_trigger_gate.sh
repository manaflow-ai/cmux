#!/usr/bin/env bash
# Exercise the unprivileged CLA trigger admission gate. The gate must reject
# case variants and wrapped comments before the privileged signature job's
# concurrency group can admit them.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/cla.yml"
test -f "$WORKFLOW"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
gate_script="$work/gate.sh"

awk '
  /^  CLACommentGate:/ { in_job=1; next }
  in_job && /^  [A-Za-z0-9_]+:/ { exit }
  in_job && /^        run: \|$/ { in_run=1; next }
  in_run { sub(/^          /, ""); print }
' "$WORKFLOW" >"$gate_script"
bash -n "$gate_script"

run_case() {
  local mode="$1"
  local expected_status="$2"
  local expected_text="$3"
  local event_name=issue_comment
  local event_action=created
  local comment_body=recheck
  local output status
  case "$mode" in
    exact-sign) comment_body='I have read the CLA Document and I hereby sign the CLA' ;;
    uppercase-recheck) comment_body=RECHECK ;;
    padded-sign) comment_body=' I have read the CLA Document and I hereby sign the CLA ' ;;
    wrapped-sign) comment_body='Please sign: I have read the CLA Document and I hereby sign the CLA' ;;
    pull-opened) event_name=pull_request_target; event_action=opened; comment_body='' ;;
    pull-reopened) event_name=pull_request_target; event_action=reopened; comment_body='' ;;
    pull-synchronize) event_name=pull_request_target; event_action=synchronize; comment_body='' ;;
    pull-closed) event_name=pull_request_target; event_action=closed; comment_body='' ;;
    wrong-event) event_name=push; event_action=; comment_body='' ;;
  esac
  set +e
  output="$(
    EVENT_NAME="$event_name" \
    EVENT_ACTION="$event_action" \
    COMMENT_BODY="$comment_body" \
    bash "$gate_script" 2>&1
  )"
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

run_case exact-recheck 0 ""
run_case exact-sign 0 ""
run_case uppercase-recheck 1 "exact CLA declaration"
run_case padded-sign 1 "exact CLA declaration"
run_case wrapped-sign 1 "exact CLA declaration"
run_case pull-opened 0 ""
run_case pull-reopened 0 ""
run_case pull-synchronize 0 ""
run_case pull-closed 1 "accepted CLA trigger"
run_case wrong-event 1 "accepted CLA trigger"
