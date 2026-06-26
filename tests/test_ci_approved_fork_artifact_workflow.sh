#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/approved-fork-artifact.yml"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"
DOC_FILE="$ROOT_DIR/docs/ci-runners.md"
RELOAD_FILE="$ROOT_DIR/scripts/reload.sh"

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
  "actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3 # v9.0.0" \
  "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2" \
  "github.rest.pulls.get" \
  "approved_head_sha must be the full 40-character hexadecimal pull_request.head.sha" \
  "actualHeadSha !== approvedHeadSha" \
  "pull.state !== 'open'" \
  "is not from an external fork" \
  "repository: \${{ needs.resolve-pr.outputs.head_repo }}" \
  "ref: \${{ needs.resolve-pr.outputs.head_sha }}" \
  "pr_number: \${{ steps.pr.outputs.pr_number }}" \
  "APPROVED_PR_NUMBER: \${{ needs.resolve-pr.outputs.pr_number }}" \
  "BUILD_TAG: pr-\${{ needs.resolve-pr.outputs.pr_number }}-\${{ needs.resolve-pr.outputs.short_sha }}" \
  "persist-credentials: false" \
  "CMUX_RELOAD_APP_PATH_OUTPUT=\"\$app_path_file\"" \
  "./scripts/reload.sh --tag \"\$BUILD_TAG\" --swift-frontend-workaround" \
  "reload.sh did not write app path" \
  "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1" \
  "artifact/provenance.json" \
  "retention-days: 14"; do
  if ! grep -Fq "$needle" "$WORKFLOW_FILE"; then
    fail "approved fork artifact workflow must contain: $needle"
  fi
done

if grep -Eq 'secrets\.|secrets:[[:space:]]*inherit|id-token:[[:space:]]*write|contents:[[:space:]]*write|pull-requests:[[:space:]]*write' "$WORKFLOW_FILE"; then
  fail "approved fork artifact workflow must not request write permissions or repository secrets"
fi

if ! grep -Fq 'CMUX_RELOAD_APP_PATH_OUTPUT' "$RELOAD_FILE"; then
  fail "reload.sh must support CMUX_RELOAD_APP_PATH_OUTPUT for machine-readable app path handoff"
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
