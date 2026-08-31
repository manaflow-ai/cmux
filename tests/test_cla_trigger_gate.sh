#!/usr/bin/env bash
# Exercise the unprivileged CLA trigger admission gate. The shell gate must
# reject case variants and wrapped comments. The job-level expression is a
# coarse prefilter; exact admission runs before the signer queue.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/cla.yml"
test -f "$WORKFLOW"

grep -Fq 'types: [opened,closed,edited,reopened,synchronize]' "$WORKFLOW"
if rg -n 'changes\.base' "$WORKFLOW" >/dev/null; then
  echo 'FAIL: edited pull-request events must not require a base-change payload' >&2
  exit 1
fi

# The protected ruleset must be migrated to the versioned check context before
# enforcement. The admission queue is bounded per pull request. Its known
# case-insensitive replacement behavior is an availability residual; the
# exact shell check still prevents an invalid comment from reaching signing.
grep -Fq 'name: "CLA Assistant v2"' "$WORKFLOW"
grep -Fq 'name: "CLA Assistant"' "$WORKFLOW"
grep -Fq 'github.event.comment.body == '\''recheck'\''' "$WORKFLOW"
grep -Fq 'github.event.comment.body == '\''I have read the CLA Document v2.2 and I hereby sign the CLA'\''' "$WORKFLOW"
grep -Fq 'github.event.comment.user.id == github.event.issue.user.id' "$WORKFLOW"
grep -Fq 'always() &&' "$WORKFLOW"
grep -Fq 'cancel-in-progress: false' "$WORKFLOW"
grep -Fq "group: cla-signatures-\${{ github.repository }}-\${{ github.event.pull_request.number || github.event.issue.number }}" "$WORKFLOW"
for job in CLACommentGate CLAAssistant CLACompatibility RerunFailedCLA LockMergedPullRequest; do
  job_block="$(awk -v job="$job" '$0 == "  " job ":" { in_job=1; next } in_job && /^  [A-Za-z0-9_]+:/ { exit } in_job { print }' "$WORKFLOW")"
  if [[ "$job_block" != *"    runs-on: \${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"* ]]; then
    echo "FAIL: $job must use the configured Linux runner" >&2
    exit 1
  fi
done
assistant_block="$(awk '/^  CLAAssistant:/ { in_job=1; next } in_job && /^  [A-Za-z0-9_]+:/ { exit } in_job { print }' "$WORKFLOW")"
if [[ "$assistant_block" != *$'    if: >-\n      always() &&'* ||
      "$assistant_block" != *'      - name: "Require CLA admission"'* ||
      "$assistant_block" != *'        if: always()'* ]]; then
  echo 'FAIL: CLA assistant must expose a failed check when admission fails' >&2
  exit 1
fi
success_guard_count="$(grep -Fc '        if: success()' <<<"$assistant_block")"
if [[ "$success_guard_count" -lt 4 ]]; then
  echo 'FAIL: privileged CLA steps must require successful admission' >&2
  exit 1
fi
echo "PASS: signer admission failure is visible and privileged steps are guarded"
gate_group_block="$(awk '/^  CLACommentGate:/ { in_job=1; next } in_job && /^  [A-Za-z0-9_]+:/ { exit } in_job { print }' "$WORKFLOW")"
if [[ "$gate_group_block" != *$'\n    concurrency:'* ||
      "$gate_group_block" != *"group: cla-admission-\${{ github.repository }}-\${{ github.event_name }}-\${{ github.event.issue.number || github.event.pull_request.number }}"* ||
      "$gate_group_block" != *$'cancel-in-progress: false'* ]]; then
  echo 'FAIL: CLA admission gate must use a bounded per-PR non-canceling queue' >&2
  exit 1
fi
if rg -n -- '--paginate|--slurp' "$WORKFLOW" >/dev/null; then
  echo 'FAIL: CLA rerun queries must use explicit bounded pages' >&2
  exit 1
fi
grep -Fq "path-to-signatures: 'signatures/version2/cla.json'" "$WORKFLOW"
grep -Fq "github.event.comment.body == 'recheck'" "$WORKFLOW"
grep -Fq "github.event.comment.body == 'I have read the CLA Document v2.2 and I hereby sign the CLA'" "$WORKFLOW"
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

admission_script="$work/admission.sh"
awk '
  /^      - name: "Require CLA admission"/ { found=1; next }
  found && /^        run: \|$/ { in_run=1; next }
  found && in_run && /^      - name:/ { exit }
  in_run { sub(/^          /, ""); print }
' "$WORKFLOW" >"$admission_script"
bash -n "$admission_script"
for gate_result in success failure skipped; do
  set +e
  output="$(GATE_RESULT="$gate_result" bash "$admission_script" 2>&1)"
  status=$?
  set -e
  if [[ "$gate_result" == success && "$status" -ne 0 ]]; then
    echo "FAIL: admission guard rejected successful gate result" >&2
    exit 1
  elif [[ "$gate_result" != success && "$status" -eq 0 ]]; then
    echo "FAIL: admission guard accepted gate result '$gate_result'" >&2
    exit 1
  fi
done
echo "PASS: admission result guard"

run_case() {
  local mode="$1"
  local expected_status="$2"
  local expected_text="$3"
  local event_name=issue_comment
  local event_action=created
  local comment_body=recheck
  local comment_author_id=300
  local comment_author_login=contributor
  local pr_author_id=300
  local comment_author_type=User
  local comment_author_association=NONE
  local output status
  case "$mode" in
    exact-sign) comment_body='I have read the CLA Document v2.2 and I hereby sign the CLA' ;;
    legacy-sign) comment_body='I have read the CLA Document and I hereby sign the CLA' ;;
    uppercase-recheck) comment_body=RECHECK ;;
    padded-sign) comment_body=' I have read the CLA Document v2.2 and I hereby sign the CLA ' ;;
    wrapped-sign) comment_body='Please sign: I have read the CLA Document v2.2 and I hereby sign the CLA' ;;
    untrusted-recheck) comment_author_id=301 ;;
    trusted-recheck) comment_author_id=301; comment_author_association=MEMBER ;;
    bot-comment) comment_author_login='github-actions[bot]'; comment_author_type=Bot ;;
    pull-opened) event_name=pull_request_target; event_action=opened; comment_body='' ;;
    pull-edited) event_name=pull_request_target; event_action=edited; comment_body='' ;;
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
    COMMENT_AUTHOR_ID="$comment_author_id" \
    COMMENT_AUTHOR_LOGIN="$comment_author_login" \
    PR_AUTHOR_ID="$pr_author_id" \
    COMMENT_AUTHOR_TYPE="$comment_author_type" \
    COMMENT_AUTHOR_ASSOCIATION="$comment_author_association" \
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
run_case untrusted-recheck 1 "Only the pull request author or a trusted repository participant"
run_case trusted-recheck 0 ""
run_case bot-comment 1 "Bot and malformed comments"
run_case padded-sign 1 "exact CLA declaration"
run_case wrapped-sign 1 "exact CLA declaration"
run_case pull-opened 0 ""
run_case pull-edited 0 ""
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

# Edited events must reach the signer and compatibility jobs as well as the
# admission shell. This prevents a skipped old required context after a title
# or body edit. Keep the assertion narrow to the event clauses, not comments.
for job in CLAAssistant CLACompatibility; do
  job_block="$(awk -v job="$job" '$0 == "  " job ":" { in_job=1; next } in_job && /^  [A-Za-z0-9_]+:/ { exit } in_job { print }' "$WORKFLOW")"
  if [[ "$job_block" != *"github.event.action == 'edited'"* ]]; then
    echo "FAIL: $job does not run for edited pull-request events" >&2
    exit 1
  fi
done
echo "PASS: edited event job routing"
