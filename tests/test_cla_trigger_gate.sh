#!/usr/bin/env bash
# Run the executable admission and result guards from the v3 workflow. These
# checks cover the event boundary and the failed-check path without granting a
# test process a GitHub token or pretending that YAML text alone proves it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/cla.yml"
test -f "$WORKFLOW"

grep -Fq 'name: "CLA Assistant v3"' "$WORKFLOW"
if grep -Fq 'name: "CLA Assistant v2"' "$WORKFLOW"; then
  echo 'FAIL: the retired v2 check name remains in the workflow' >&2
  exit 1
fi
generation="$(WORKFLOW="$WORKFLOW" ruby -ryaml -e 'puts YAML.safe_load(File.read(ENV.fetch("WORKFLOW")), aliases: false).fetch("env").fetch("CLA_GENERATION")')"
[[ "$generation" =~ ^v[0-9]+\.[0-9]+-action-[0-9a-f]{40}$ ]]
grep -Fq "name: \"CLA generation $generation\"" "$WORKFLOW"
grep -Fq "echo \"CLA generation \${CLA_GENERATION}\"" "$WORKFLOW"
grep -Fq 'name: "CLA ledger writer"' "$WORKFLOW"
grep -Fq '      issues: write' "$WORKFLOW"
grep -Fq 'allowlist-ids: "38676809,67667005"' "$WORKFLOW"
grep -Fq "cla_passed: \${{ steps.cla_action.outputs.cla_passed }}" "$WORKFLOW"
grep -Fq 'CLA_PASSED:' "$WORKFLOW"
# shellcheck disable=SC2016
WORKFLOW="$WORKFLOW" ruby -ryaml -e '
  document = YAML.safe_load(File.read(ENV.fetch("WORKFLOW")), aliases: false)
  expected = "ubuntu-24.04"
  jobs = %w[CLACommentGate CLALedgerWriter CLAAssistant CLACompatibility RerunFailedCLA LockMergedPullRequest]
  actual = jobs.to_h { |name| [name, document.fetch("jobs").fetch(name).fetch("runs-on")] }
  abort "CLA jobs do not use the fixed GitHub-hosted runner" unless actual.values.all? { |runner| runner == expected }
  gate_group = document.fetch("jobs").fetch("CLACommentGate").fetch("concurrency").fetch("group")
  expected_gate_group = "cla-admission-${{ github.repository }}-${{ github.event_name }}-${{ github.event.issue.number || github.event.pull_request.number }}-${{ github.event.comment.id || github.run_id }}"
  abort "CLA admission queue is not event-unique" unless gate_group == expected_gate_group
  recheck_guard_terms = [
    "github.event.comment.body == \x27recheck\x27",
    "github.event.comment.user.id == github.event.issue.user.id",
    "github.event.comment.author_association == \x27OWNER\x27",
    "github.event.comment.author_association == \x27MEMBER\x27",
    "github.event.comment.author_association == \x27COLLABORATOR\x27"
  ]
  %w[CLACommentGate CLAAssistant].each do |name|
    condition = document.fetch("jobs").fetch(name).fetch("if").gsub(/\s+/, " ")
    abort "#{name} admits untrusted recheck comments" unless
      recheck_guard_terms.all? { |term| condition.include?(term) }
  end
  action_ref = "manaflow-ai/cla-github-action@212a0f2dd659b24b48a30ba35966e06dc41736af"
  action_refs = []
  walk = lambda do |value|
    case value
    when Hash
      value.each { |key, child| action_refs << child if key == "uses" && child.is_a?(String) && child.start_with?("manaflow-ai/cla-github-action@"); walk.call(child) }
    when Array
      value.each { |child| walk.call(child) }
    end
  end
  walk.call(document)
  abort "CLA workflow uses an unexpected action reference" unless action_refs == [action_ref, action_ref, action_ref]
'
grep -Fq 'uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd' "$WORKFLOW"
grep -Fq "ref: \${{ github.workflow_sha }}" "$WORKFLOW"
if grep -Fq "ref: \${{ github.event.pull_request" "$WORKFLOW"; then
  echo 'FAIL: the rerun helper may not check out a pull-request revision' >&2
  exit 1
fi

workflow_types='types: [opened,closed,edited,reopened,synchronize,ready_for_review]'
grep -Fq "$workflow_types" "$WORKFLOW"
grep -Fq "github.event.comment.body == 'recheck'" "$WORKFLOW"
grep -Fq "github.event.comment.body == 'I have read the CLA Document v2.2 and I hereby sign the CLA'" "$WORKFLOW"
grep -Fq "group: cla-signatures-\${{ github.repository }}-\${{ github.event.pull_request.number || github.event.issue.number }}" "$WORKFLOW"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

extract_run() {
  local job="$1" marker="$2" output="$3"
  awk -v job="$job" -v marker="$marker" '
    $0 == "  " job ":" { in_job=1; next }
    in_job && /^  [A-Za-z0-9_]+:/ { exit }
    in_job && index($0, marker) { target_step=1; next }
    in_run && /^      - name:/ { exit }
    target_step && /^        run: \|$/ { in_run=1; next }
    in_run { sub(/^          /, ""); print }
  ' "$WORKFLOW" >"$output"
  test -s "$output"
  bash -n "$output"
}

extract_run CLACommentGate 'id: admission' "$work/admission.sh"

run_gate() {
  local name="$1" expected_status="$2" expected_output="$3"
  shift 3
  local output_file="$work/gate-$name.out" output status
  rm -f "$output_file"
  set +e
  output="$(
    GITHUB_OUTPUT="$output_file" \
    EVENT_NAME=issue_comment EVENT_ACTION=created \
    COMMENT_BODY='recheck' COMMENT_AUTHOR_ID=300 COMMENT_AUTHOR_LOGIN=contributor \
    COMMENT_AUTHOR_TYPE=User PR_AUTHOR_ID=300 COMMENT_AUTHOR_ASSOCIATION=NONE \
    "$@" bash "$work/admission.sh" 2>&1
  )"
  status=$?
  set -e
  if [[ "$status" != "$expected_status" ]]; then
    echo "FAIL: gate $name exited $status, expected $expected_status" >&2
    echo "$output" >&2
    exit 1
  fi
  if [[ "$expected_output" == none ]]; then
    [[ ! -s "$output_file" ]] || {
      echo "FAIL: gate $name emitted an admission result" >&2
      exit 1
    }
  else
    [[ "$(<"$output_file")" == "admitted=$expected_output" ]] || {
      echo "FAIL: gate $name emitted an unexpected admission result" >&2
      cat "$output_file" >&2
      exit 1
    }
  fi
  echo "PASS: gate $name"
}

# The gate admits a syntactically valid declaration before the maintained
# action authenticates the signer. This keeps the write-capable job from
# duplicating identity policy while still exposing unauthorized signers as a
# failed preflight result.
run_gate exact-recheck 0 true
run_gate unauthorized-recheck 0 false env COMMENT_AUTHOR_ID=301 COMMENT_AUTHOR_LOGIN=reviewer COMMENT_AUTHOR_ASSOCIATION=NONE
run_gate member-recheck 0 true env COMMENT_AUTHOR_ID=301 COMMENT_AUTHOR_LOGIN=maintainer COMMENT_AUTHOR_ASSOCIATION=MEMBER
run_gate exact-sign 0 true env COMMENT_BODY='I have read the CLA Document v2.2 and I hereby sign the CLA'
run_gate non-author-sign 0 true env COMMENT_BODY='I have read the CLA Document v2.2 and I hereby sign the CLA' COMMENT_AUTHOR_ID=301 COMMENT_AUTHOR_LOGIN=reviewer COMMENT_AUTHOR_ASSOCIATION=MEMBER
run_gate ordinary-comment 0 false env COMMENT_BODY='Thanks for the review!'
run_gate padded-comment 0 false env COMMENT_BODY=' recheck'
run_gate uppercase-comment 0 false env COMMENT_BODY=RECHECK
run_gate uppercase-signing-comment 0 false env COMMENT_BODY='I HAVE READ THE CLA DOCUMENT V2.2 AND I HEREBY SIGN THE CLA'
run_gate bot-comment 1 none env COMMENT_AUTHOR_TYPE=Bot COMMENT_AUTHOR_LOGIN='github-actions[bot]'

for action in opened edited reopened synchronize ready_for_review; do
  run_gate "pull-$action" 0 true env EVENT_NAME=pull_request_target EVENT_ACTION="$action" COMMENT_BODY=''
done
run_gate pull-closed 1 none env EVENT_NAME=pull_request_target EVENT_ACTION=closed COMMENT_BODY=''

extract_run CLAAssistant "CLA generation $generation" "$work/assistant.sh"
CLA_GENERATION="$generation"
export CLA_GENERATION
run_result() {
  local name="$1" expected_status="$2" event_name="$3" comment_body="$4" gate_result="$5" admitted="$6" signer="$7" writer="$8" cla_passed="$9"
  local output status
  set +e
  output="$(
    EVENT_NAME="$event_name" COMMENT_BODY="$comment_body" GATE_RESULT="$gate_result" \
    ADMITTED="$admitted" SIGNER_AUTHORIZED="$signer" WRITER_RESULT="$writer" \
    CLA_PASSED="$cla_passed" \
    CLA_GENERATION="$CLA_GENERATION" bash "$work/assistant.sh" 2>&1
  )"
  status=$?
  set -e
  if [[ "$status" != "$expected_status" ]]; then
    echo "FAIL: assistant $name exited $status, expected $expected_status" >&2
    echo "$output" >&2
    exit 1
  fi
  echo "PASS: assistant $name"
}
run_result lifecycle-success 0 pull_request_target '' success true false success true
run_result recheck-success 0 issue_comment recheck success true false success true
run_result signing-success 0 issue_comment 'I have read the CLA Document v2.2 and I hereby sign the CLA' success true true success true
run_result policy-failure 1 issue_comment recheck success true false success false
run_result missing-policy-result 1 issue_comment recheck success true false success ''
run_result unauthorized-sign 1 issue_comment 'I have read the CLA Document v2.2 and I hereby sign the CLA' success true false success false
run_result writer-failure 1 issue_comment recheck success true false failure false
run_result gate-failure 1 issue_comment recheck failure false false skipped false

extract_run CLACompatibility 'Mirror CLA Assistant compatibility result' "$work/compatibility.sh"
for result in success failure skipped; do
  set +e
  RESULT="$result" bash "$work/compatibility.sh" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$result" == success && "$status" -ne 0 ]] ||
     [[ "$result" != success && "$status" -eq 0 ]]; then
    echo "FAIL: compatibility mirror returned $status for $result" >&2
    exit 1
  fi
done
echo 'PASS: compatibility result mirror'

echo 'PASS: CLA v3 trigger and result guards'
