#!/bin/bash
# ============================================================================
# SCRIPT: ci-local.sh
# PURPOSE: Run the same checks that CI runs, locally
#
# This simulates what runs in GitHub Actions (checks.yml + tests.yml)
# Use this before pushing to ensure CI will pass.
#
# USAGE:
#   ./scripts/ci-local.sh           # Run all checks
#   ./scripts/ci-local.sh --quick   # Skip full test suite, only run bun check
#   ./scripts/ci-local.sh --async   # Run tests in background, return immediately
#
# EXIT CODES:
#   0 - All checks passed
#   1 - Checks failed
#   2 - Async mode: tests started in background
# ============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."

QUICK_MODE=false
ASYNC_MODE=false
ASYNC_STATUS_FILE="/tmp/ci-local-async.status"
ASYNC_LOG_FILE="/tmp/ci-local-async.log"
ASYNC_PID_FILE="/tmp/ci-local-async.pid"

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK_MODE=true ;;
    --async) ASYNC_MODE=true ;;
    --check-async)
      # Check status of async run
      if [ -f "$ASYNC_STATUS_FILE" ]; then
        status=$(cat "$ASYNC_STATUS_FILE")
        case "$status" in
          "running")
            if [ -f "$ASYNC_PID_FILE" ]; then
              pid=$(cat "$ASYNC_PID_FILE")
              if kill -0 "$pid" 2>/dev/null; then
                echo "CI checks still running (PID: $pid)"
                echo "Log: $ASYNC_LOG_FILE"
                exit 2
              fi
            fi
            # Process finished, check log
            if grep -q "All CI checks passed" "$ASYNC_LOG_FILE" 2>/dev/null; then
              echo "passed" > "$ASYNC_STATUS_FILE"
              echo "CI checks PASSED (async)"
              exit 0
            else
              echo "failed" > "$ASYNC_STATUS_FILE"
              echo "CI checks FAILED (async)"
              tail -50 "$ASYNC_LOG_FILE"
              exit 1
            fi
            ;;
          "passed")
            echo "CI checks PASSED (async)"
            rm -f "$ASYNC_STATUS_FILE" "$ASYNC_LOG_FILE" "$ASYNC_PID_FILE"
            exit 0
            ;;
          "failed")
            echo "CI checks FAILED (async)"
            if [ -f "$ASYNC_LOG_FILE" ]; then
              tail -50 "$ASYNC_LOG_FILE"
            fi
            rm -f "$ASYNC_STATUS_FILE" "$ASYNC_LOG_FILE" "$ASYNC_PID_FILE"
            exit 1
            ;;
        esac
      else
        echo "No async CI run in progress"
        exit 0
      fi
      ;;
    --help)
      echo "Usage: ./scripts/ci-local.sh [--quick|--async|--check-async]"
      echo ""
      echo "Options:"
      echo "  --quick       Skip full test suite, only run bun check"
      echo "  --async       Run tests in background, return immediately"
      echo "  --check-async Check status of async run"
      echo ""
      echo "Exit codes:"
      echo "  0 - All checks passed"
      echo "  1 - Checks failed"
      echo "  2 - Async mode: tests started in background"
      exit 0
      ;;
  esac
done

run_checks() {
  local log_file="${1:-/dev/stdout}"
  local redirect=""
  if [ "$log_file" != "/dev/stdout" ]; then
    redirect=">> $log_file 2>&1"
  fi

  echo "============================================" | tee -a "$log_file" 2>/dev/null || echo "============================================"
  echo "🔍 CI-Local: Running checks..." | tee -a "$log_file" 2>/dev/null || echo "🔍 CI-Local: Running checks..."
  echo "============================================" | tee -a "$log_file" 2>/dev/null || echo "============================================"

  # Step 1: bun check (type checking + linting) - mirrors checks.yml
  echo "" | tee -a "$log_file" 2>/dev/null || echo ""
  echo "📋 Step 1/3: Running bun check..." | tee -a "$log_file" 2>/dev/null || echo "📋 Step 1/3: Running bun check..."

  if [ "$log_file" != "/dev/stdout" ]; then
    if ! bun check >> "$log_file" 2>&1; then
      echo "❌ bun check failed" >> "$log_file"
      echo "failed" > "$ASYNC_STATUS_FILE"
      return 1
    fi
  else
    if ! bun check; then
      echo "❌ bun check failed"
      return 1
    fi
  fi
  echo "✅ bun check passed" | tee -a "$log_file" 2>/dev/null || echo "✅ bun check passed"

  if [ "$QUICK_MODE" = true ]; then
    echo "" | tee -a "$log_file" 2>/dev/null || echo ""
    echo "⏩ Quick mode: Skipping full test suite" | tee -a "$log_file" 2>/dev/null || echo "⏩ Quick mode: Skipping full test suite"
    echo "✅ Quick CI checks passed!" | tee -a "$log_file" 2>/dev/null || echo "✅ Quick CI checks passed!"
    return 0
  fi

  # Step 2: Build native addons (required for tests) - mirrors tests.yml
  echo "" | tee -a "$log_file" 2>/dev/null || echo ""
  echo "📋 Step 2/3: Building native addons..." | tee -a "$log_file" 2>/dev/null || echo "📋 Step 2/3: Building native addons..."

  if [ -d "apps/server/native/core" ]; then
    if [ "$log_file" != "/dev/stdout" ]; then
      if ! (cd apps/server/native/core && bun run build) >> "$log_file" 2>&1; then
        echo "❌ Native addon build failed" >> "$log_file"
        echo "failed" > "$ASYNC_STATUS_FILE"
        return 1
      fi
    else
      if ! (cd apps/server/native/core && bun run build); then
        echo "❌ Native addon build failed"
        return 1
      fi
    fi
  fi
  echo "✅ Native addons built" | tee -a "$log_file" 2>/dev/null || echo "✅ Native addons built"

  # Step 3: Run full test suite - mirrors tests.yml
  echo "" | tee -a "$log_file" 2>/dev/null || echo ""
  echo "📋 Step 3/3: Running full test suite..." | tee -a "$log_file" 2>/dev/null || echo "📋 Step 3/3: Running full test suite..."
  echo "(This may take several minutes)" | tee -a "$log_file" 2>/dev/null || echo "(This may take several minutes)"

  # Set CI env vars to match GitHub Actions
  export CI=true
  export CMUX_SKIP_DOCKER_TESTS=1
  export CMUX_SKIP_CARGO_CRATES="sandbox,cmux-env,cmux-pty,cmux-proxy,global-proxy,server/native/core"

  if [ "$log_file" != "/dev/stdout" ]; then
    if ! bun run test >> "$log_file" 2>&1; then
      echo "❌ Tests failed" >> "$log_file"
      echo "failed" > "$ASYNC_STATUS_FILE"
      return 1
    fi
  else
    if ! bun run test; then
      echo "❌ Tests failed"
      return 1
    fi
  fi
  echo "✅ All tests passed" | tee -a "$log_file" 2>/dev/null || echo "✅ All tests passed"

  echo "" | tee -a "$log_file" 2>/dev/null || echo ""
  echo "============================================" | tee -a "$log_file" 2>/dev/null || echo "============================================"
  echo "✅ All CI checks passed!" | tee -a "$log_file" 2>/dev/null || echo "✅ All CI checks passed!"
  echo "============================================" | tee -a "$log_file" 2>/dev/null || echo "============================================"

  return 0
}

if [ "$ASYNC_MODE" = true ]; then
  echo "Starting CI checks in background..."
  echo "running" > "$ASYNC_STATUS_FILE"
  : > "$ASYNC_LOG_FILE"

  (
    cd "$(dirname "$0")/.."
    if run_checks "$ASYNC_LOG_FILE"; then
      echo "passed" > "$ASYNC_STATUS_FILE"
    else
      echo "failed" > "$ASYNC_STATUS_FILE"
    fi
  ) &

  ASYNC_PID=$!
  echo "$ASYNC_PID" > "$ASYNC_PID_FILE"
  disown "$ASYNC_PID" 2>/dev/null || true

  echo "Background PID: $ASYNC_PID"
  echo "Log file: $ASYNC_LOG_FILE"
  echo ""
  echo "Check status with: ./scripts/ci-local.sh --check-async"
  echo "Or: tail -f $ASYNC_LOG_FILE"
  exit 2
else
  if run_checks; then
    exit 0
  else
    exit 1
  fi
fi
