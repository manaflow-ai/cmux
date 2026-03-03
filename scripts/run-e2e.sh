#!/usr/bin/env bash
# Trigger the test-e2e.yml workflow and optionally wait for results.
#
# Usage:
#   ./scripts/run-e2e.sh UpdatePillUITests
#   ./scripts/run-e2e.sh UpdatePillUITests --wait
#   ./scripts/run-e2e.sh UpdatePillUITests/testFoo --ref my-branch
#   ./scripts/run-e2e.sh UpdatePillUITests --no-video --timeout 300
set -euo pipefail

REPO="manaflow-ai/cmux"
WORKFLOW="test-e2e.yml"

# Defaults
REF=""
WAIT=false
RECORD_VIDEO=true
TIMEOUT=120

usage() {
  cat <<EOF
Usage: $(basename "$0") <test_filter> [options]

Arguments:
  test_filter    Test class or class/method (e.g. UpdatePillUITests)

Options:
  --ref <ref>      Branch or SHA to test (default: current branch)
  --wait           Wait for the run to complete and print result
  --no-video       Disable video recording
  --timeout <sec>  Per-test timeout in seconds (default: 120)
  -h, --help       Show this help
EOF
  exit 0
}

if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  usage
fi

TEST_FILTER="$1"
shift

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)
      REF="$2"
      shift 2
      ;;
    --wait)
      WAIT=true
      shift
      ;;
    --no-video)
      RECORD_VIDEO=false
      shift
      ;;
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

# Build workflow dispatch fields
FIELDS=(-f "test_filter=$TEST_FILTER" -f "record_video=$RECORD_VIDEO" -f "test_timeout=$TIMEOUT")
if [ -n "$REF" ]; then
  FIELDS+=(-f "ref=$REF")
fi

echo "Triggering $WORKFLOW with test_filter=$TEST_FILTER ref=${REF:-<default>} video=$RECORD_VIDEO timeout=$TIMEOUT"
gh workflow run "$WORKFLOW" --repo "$REPO" "${FIELDS[@]}"

# Wait a moment for the run to register
sleep 3

# Get the latest run ID
RUN_ID=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 1 --json databaseId --jq '.[0].databaseId')
RUN_URL="https://github.com/$REPO/actions/runs/$RUN_ID"

echo "Run: $RUN_URL"

if [ "$WAIT" = true ]; then
  echo "Waiting for run to complete..."
  gh run watch --repo "$REPO" "$RUN_ID" --exit-status || true

  STATUS=$(gh run view --repo "$REPO" "$RUN_ID" --json conclusion --jq '.conclusion')
  echo ""
  echo "Result: $STATUS"
  echo "Run: $RUN_URL"

  # Find the issue created for this run (search by run ID in body)
  ISSUE_URL=$(gh search issues "$RUN_ID" --repo manaflow-ai/cmux-dev-artifacts --limit 1 --json url --jq '.[0].url' 2>/dev/null || true)
  if [ -n "$ISSUE_URL" ]; then
    echo "Issue: $ISSUE_URL"
  fi
fi
