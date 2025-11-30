#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="${SCRIPT_DIR}/e2e"

echo "Running all E2E tests..."

# Ensure we build the image once if possible to save time, 
# though individual scripts might trigger rebuilds if not careful.
# Assuming the scripts reuse the image if present or updated.

# Array of test scripts
TESTS=(
  "test-basic.sh"
  "test-interactive.sh"
  "test-network.sh"
)

FAILED_TESTS=()

for test_script in "${TESTS[@]}"; do
  echo "----------------------------------------------------------------"
  echo "Running ${test_script}..."
  echo "----------------------------------------------------------------"
  
  if "${E2E_DIR}/${test_script}"; then
    echo "✅ ${test_script} PASSED"
  else
    echo "❌ ${test_script} FAILED"
    FAILED_TESTS+=("${test_script}")
  fi
  echo ""
done

if [ ${#FAILED_TESTS[@]} -eq 0 ]; then
  echo "🎉 All E2E tests passed!"
  exit 0
else
  echo "💥 The following tests failed:"
  for test in "${FAILED_TESTS[@]}"; do
    echo "  - ${test}"
  done
  exit 1
fi
