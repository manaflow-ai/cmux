#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/approved-fork-artifact.yml"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"
DOC_FILE="$ROOT_DIR/docs/ci-runners.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -s "$WORKFLOW_FILE" ]] || fail "approved fork artifact workflow is missing"

for needle in \
  "workflow_dispatch:" \
  "pr_number:" \
  "approved_head_sha:" \
  "contents: read" \
  "pull-requests: read" \
  "github.rest.pulls.get" \
  "approved_head_sha must be the full 40-character hexadecimal pull_request.head.sha" \
  "actualHeadSha !== approvedHeadSha" \
  "pull.state !== 'open'" \
  "repository: \${{ needs.resolve-pr.outputs.head_repo }}" \
  "ref: \${{ needs.resolve-pr.outputs.head_sha }}" \
  "persist-credentials: false" \
  "./scripts/reload.sh --tag \"\$BUILD_TAG\" --swift-frontend-workaround" \
  "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1" \
  "artifact/provenance.json" \
  "retention-days: 14"; do
  if ! grep -Fq "$needle" "$WORKFLOW_FILE"; then
    fail "approved fork artifact workflow must contain: $needle"
  fi
done

if grep -Eq 'secrets\.|id-token:[[:space:]]*write|contents:[[:space:]]*write|pull-requests:[[:space:]]*write' "$WORKFLOW_FILE"; then
  fail "approved fork artifact workflow must not request write permissions or repository secrets"
fi

if ! awk '
  /- name: Validate approved fork artifact workflow/ { in_step=1; next }
  in_step && /^[[:space:]]*- name:/ { in_step=0 }
  in_step && /\.\/tests\/test_ci_approved_fork_artifact_workflow\.sh/ { saw=1 }
  END { exit !saw }
' "$CI_FILE"; then
  fail "ci.yml workflow-guard-tests must run test_ci_approved_fork_artifact_workflow.sh"
fi

for needle in \
  "approved-fork-artifact.yml" \
  "approved_head_sha" \
  "pull_request.head.sha" \
  "persist-credentials: false" \
  "gh workflow run approved-fork-artifact.yml"; do
  if ! grep -Fq "$needle" "$DOC_FILE"; then
    fail "docs/ci-runners.md must document: $needle"
  fi
done

echo "PASS: approved fork artifact workflow keeps the maintainer-approved SHA and read-only checkout contract"
