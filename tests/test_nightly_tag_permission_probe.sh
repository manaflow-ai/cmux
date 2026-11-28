#!/usr/bin/env bash
# Guard the scratch-tag permission probe against real channel mutation.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/nightly-tag-permission-probe.yml"

for expected in \
  'workflow_dispatch:' \
  'permission-contents: write' \
  'permission-workflows: write' \
  'GH_TOKEN: ${{ github.token }}' \
  'HTTP 403|Resource not accessible by integration' \
  'nightly-probe-${GITHUB_RUN_ID}' \
  'gh api --method DELETE "repos/$REPO/git/refs/tags/$TAG"'; do
  if ! grep -Fq "$expected" "$WORKFLOW_FILE"; then
    echo "FAIL: nightly tag permission probe is missing: $expected"
    exit 1
  fi
done

if grep -Eq 'refs/tags/(nightly|rc)|--tag (nightly|rc)' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly tag permission probe must never mutate the real nightly or rc tags"
  exit 1
fi

echo "PASS: nightly tag permission probe is scratch-tag-only"
