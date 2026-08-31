#!/usr/bin/env bash
# Exercise the unprivileged CLA trigger admission gate. The shell gate must
# reject case variants and wrapped comments. The job-level expression is a
# coarse prefilter, and its shared concurrency group bounds candidate floods.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/cla.yml"
test -f "$WORKFLOW"

# The protected ruleset must be migrated to the versioned check context before
# enforcement. Keep admission non-canceling and bounded by event type so a
# public comment cannot consume an unbounded number of runners.
grep -Fq 'name: "CLA Assistant v2"' "$WORKFLOW"
grep -Fq 'name: "CLA Assistant"' "$WORKFLOW"
grep -Fq 'group: >-' "$WORKFLOW"
grep -Fq "cla-admission-\${{ github.event_name }}-\${{ github.event_name == 'issue_comment' && 'comments' || github.event.pull_request.number }}" "$WORKFLOW"
grep -Fq 'github.event.comment.body == '\''recheck'\''' "$WORKFLOW"
grep -Fq 'github.event.comment.body == '\''I have read the CLA Document v2.2 and I hereby sign the CLA'\''' "$WORKFLOW"
grep -Fq 'always() &&' "$WORKFLOW"
grep -Fq 'cancel-in-progress: false' "$WORKFLOW"
grep -Fq "group: cla-signatures-\${{ github.repository }}-\${{ github.event.pull_request.number || github.event.issue.number }}" "$WORKFLOW"
if rg -n -- '--paginate|--slurp' "$WORKFLOW" >/dev/null; then
  echo 'FAIL: CLA rerun queries must use explicit bounded pages' >&2
  exit 1
fi
grep -Fq "path-to-signatures: 'signatures/version2/cla.json'" "$WORKFLOW"
grep -Fq "github.event.comment.body == 'recheck'" "$WORKFLOW"
grep -Fq "github.event.comment.body == 'I have read the CLA Document v2.2 and I hereby sign the CLA'" "$WORKFLOW"
if grep -Fq 'cla-trigger-${{ github.run_id }}' "$WORKFLOW"; then
  echo 'FAIL: CLA trigger gate admits an unbounded per-event runner group' >&2
  exit 1
fi
gate_group_block="$(awk '/^  CLACommentGate:/ { in_job=1; next } in_job && /^  [A-Za-z0-9_]+:/ { exit } in_job && /^    concurrency:$/ { in_group=1; next } in_group && /^    [A-Za-z0-9_]+:/ { exit } in_group { print }' "$WORKFLOW")"
if [[ "$gate_group_block" == *'github.run_'* ||
      "$gate_group_block" == *'github.event.issue.number'* ||
      "$gate_group_block" == *'github.event.comment.body }}'* ||
      "$gate_group_block" == *'github.event.pull_request.head.sha'* ]]; then
  echo 'FAIL: CLA admission group contains an unbounded or raw event value' >&2
  exit 1
fi

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
    exact-sign) comment_body='I have read the CLA Document v2.2 and I hereby sign the CLA' ;;
    legacy-sign) comment_body='I have read the CLA Document and I hereby sign the CLA' ;;
    uppercase-recheck) comment_body=RECHECK ;;
    padded-sign) comment_body=' I have read the CLA Document v2.2 and I hereby sign the CLA ' ;;
    wrapped-sign) comment_body='Please sign: I have read the CLA Document v2.2 and I hereby sign the CLA' ;;
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
run_case legacy-sign 1 "exact CLA declaration"
run_case uppercase-recheck 1 "exact CLA declaration"
run_case padded-sign 1 "exact CLA declaration"
run_case wrapped-sign 1 "exact CLA declaration"
run_case pull-opened 0 ""
run_case pull-reopened 0 ""
run_case pull-synchronize 0 ""
run_case pull-closed 1 "accepted CLA trigger"
run_case wrong-event 1 "accepted CLA trigger"

# The compatibility check must fail closed when the v2 action fails or is
# skipped. A skipped dependency must never become a successful old required
# context during migration.
compat_script="$work/compatibility.sh"
awk '
  /^  CLACompatibility:/ { in_job=1; next }
  in_job && /^  [A-Za-z0-9_]+:/ { exit }
  in_job && /^        run: \|$/ { in_run=1; next }
  in_run { sub(/^          /, ""); print }
' "$WORKFLOW" >"$compat_script"
bash -n "$compat_script"
for gate_result in success failure skipped; do
  for result in success failure skipped; do
  set +e
  GATE_RESULT="$gate_result" V2_RESULT="$result" bash "$compat_script" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$gate_result" == success && "$result" == success && "$status" -ne 0 ]]; then
    echo "FAIL: compatibility check rejected successful gate and v2 result" >&2
    exit 1
  elif [[ ( "$gate_result" != success || "$result" != success ) && "$status" -eq 0 ]]; then
    echo "FAIL: compatibility check accepted gate '$gate_result' and v2 result '$result'" >&2
    exit 1
  fi
  done
done
echo "PASS: compatibility result mirror"

compat_block="$(awk '/^  CLACompatibility:/ { in_job=1; next } in_job && /^  [A-Za-z0-9_]+:/ { exit } in_job { print }' "$WORKFLOW")"
if [[ "$compat_block" == *"github.event_name == 'issue_comment'"* ]]; then
  echo 'FAIL: compatibility context must not pretend issue-comment checks are PR-head checks' >&2
  exit 1
fi
echo "PASS: compatibility event scope"
