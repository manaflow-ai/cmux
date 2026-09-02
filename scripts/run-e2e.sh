#!/usr/bin/env bash
# Trigger the test-e2e.yml workflow and optionally wait for results.
#
# Usage:
#   ./scripts/run-e2e.sh UpdatePillUITests
#   ./scripts/run-e2e.sh UpdatePillUITests --wait
#   ./scripts/run-e2e.sh UpdatePillUITests/testFoo --ref my-branch
#   ./scripts/run-e2e.sh cmuxTests/ForkParentFallbackGeneralizationTests
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
  test_filter    Test class or class/method. Bare filters target cmuxUITests;
                 use cmuxUITests/Class or cmuxTests/Class for explicit targets.

Options:
  --ref <ref>      Branch or full SHA to test; branches are resolved to a SHA
                   before dispatch (default: protected main)
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
  # The workflow accepts only immutable commit IDs. Resolve a branch through
  # the commits API at dispatch time so the selected revision cannot move
  # between this command and the hosted job's checkout.
  if [[ "$REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
    RESOLVED_REF="$(printf '%s' "$REF" | tr '[:upper:]' '[:lower:]')"
  else
    case "$REF" in
      *$'\n'*|*$'\r'*)
        echo "Invalid --ref: branch names must not contain control characters" >&2
        exit 1
        ;;
    esac
    RESOLVED_REF="$(gh api --method GET "$REPO/commits" -f "sha=$REF" --jq '.[0].sha')"
    if ! [[ "$RESOLVED_REF" =~ ^[0-9a-f]{40}$ ]]; then
      echo "Could not resolve --ref '$REF' to a commit SHA" >&2
      exit 1
    fi
  fi
  FIELDS+=(-f "ref=$RESOLVED_REF")
fi

echo "Triggering $WORKFLOW with test_filter=$TEST_FILTER ref=${RESOLVED_REF:-<protected-main>} video=$RECORD_VIDEO timeout=$TIMEOUT"
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
fi
