#!/usr/bin/env bash
# E2E tests for SSH commands (cloud + local)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
# Use dmux from PATH (installed by reload.sh to ~/.local/bin/dmux)
# This ensures we use the same binary with auth tokens
DMUX="dmux"
SANDBOX_ID=""
CLOUD_SANDBOX_ID=""
TEST_START_TIME=""
STEP_START_TIME=""

# Set base URL for dmux - reload.sh starts dmux-sandbox-dev-run on port 46833
export CMUX_SANDBOX_URL="http://localhost:46833"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Timing functions
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
start_timer() { STEP_START_TIME=$(now_ms); }
elapsed_ms() { echo $(( $(now_ms) - STEP_START_TIME )); }
format_duration() {
    local ms=$1
    if [[ $ms -lt 1000 ]]; then
        echo "${ms}ms"
    else
        echo "$(( ms / 1000 )).$(( (ms % 1000) / 100 ))s"
    fi
}

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_test() { echo -e "${GREEN}[TEST]${NC} $*"; }
log_time() { echo -e "${BLUE}[TIME]${NC} $1: $(format_duration $2)"; }

cleanup() {
    log_info "Cleaning up..."

    # Delete local sandbox if created
    if [[ -n "${SANDBOX_ID}" ]]; then
        log_info "Deleting local sandbox ${SANDBOX_ID}..."
        curl -sf -X DELETE "http://localhost:46833/sandboxes/${SANDBOX_ID}" || true
    fi

    # Cloud sandbox auto-pauses after TTL
    if [[ -n "${CLOUD_SANDBOX_ID}" ]]; then
        log_info "Cloud sandbox ${CLOUD_SANDBOX_ID} will auto-pause after TTL"
    fi
}
trap cleanup EXIT

TEST_START_TIME=$(now_ms)

# Always rebuild and reload to ensure we're testing current branch code
log_info "Rebuilding and reloading dev environment..."
start_timer
"${SCRIPT_DIR}/../reload.sh"
log_time "reload.sh" $(elapsed_ms)

# Wait for health check after reload
log_info "Waiting for sandbox daemon to be ready..."
start_timer
for i in $(seq 1 30); do
    if curl -sf "http://localhost:46833/healthz" >/dev/null 2>&1; then
        log_time "sandbox daemon ready" $(elapsed_ms)
        break
    fi
    if [[ $i -eq 30 ]]; then
        log_error "Sandbox daemon failed to start after reload"
        exit 1
    fi
    sleep 1
done

# ============================================================================
# LOCAL SANDBOX TESTS
# ============================================================================

log_info "=========================================="
log_info "LOCAL SANDBOX TESTS"
log_info "=========================================="

# Create a local sandbox
log_test "Creating local sandbox..."
start_timer
CREATE_OUTPUT=$(curl -sf -X POST "http://localhost:46833/sandboxes" \
    -H "Content-Type: application/json" \
    -d '{"name": "e2e-ssh-test", "workspace": "/tmp/e2e-ssh-test"}')
SANDBOX_ID=$(echo "${CREATE_OUTPUT}" | jq -r '.id')
SANDBOX_INDEX=$(echo "${CREATE_OUTPUT}" | jq -r '.index')
log_time "create local sandbox" $(elapsed_ms)
log_info "Created sandbox: ${SANDBOX_ID} (index: ${SANDBOX_INDEX})"

# Test with both full UUID and short prefix
LOCAL_ID_FULL="l_${SANDBOX_ID}"
LOCAL_ID_SHORT="l_${SANDBOX_ID:0:8}"
log_info "Local ID (full): ${LOCAL_ID_FULL}"
log_info "Local ID (short): ${LOCAL_ID_SHORT}"

# Test ssh-exec with l_<full-uuid>
log_test "Testing ssh-exec with l_<full-uuid>..."
start_timer
EXEC_OUTPUT=$("${DMUX}" ssh-exec "${LOCAL_ID_FULL}" echo "hello full uuid")
log_time "ssh-exec l_<full-uuid>" $(elapsed_ms)
if [[ "${EXEC_OUTPUT}" == *"hello full uuid"* ]]; then
    log_info "PASS: ssh-exec l_<full-uuid>"
else
    log_error "FAIL: ssh-exec l_<full-uuid>"
    log_error "Output: ${EXEC_OUTPUT}"
    exit 1
fi

# Test ssh-exec with l_<short-prefix>
log_test "Testing ssh-exec with l_<short-prefix>..."
start_timer
EXEC_OUTPUT=$("${DMUX}" ssh-exec "${LOCAL_ID_SHORT}" echo "hello short prefix")
log_time "ssh-exec l_<short-prefix>" $(elapsed_ms)
if [[ "${EXEC_OUTPUT}" == *"hello short prefix"* ]]; then
    log_info "PASS: ssh-exec l_<short-prefix>"
else
    log_error "FAIL: ssh-exec l_<short-prefix>"
    log_error "Output: ${EXEC_OUTPUT}"
    exit 1
fi

# Test ssh-exec exit code propagation
log_test "Testing ssh-exec exit code propagation..."
start_timer
set +e
"${DMUX}" ssh-exec "${LOCAL_ID_FULL}" "exit 42"
EXIT_CODE=$?
set -e
log_time "ssh-exec exit code" $(elapsed_ms)
if [[ "${EXIT_CODE}" -eq 42 ]]; then
    log_info "PASS: ssh-exec exit code propagation (got ${EXIT_CODE})"
else
    log_error "FAIL: ssh-exec exit code propagation (expected 42, got ${EXIT_CODE})"
    exit 1
fi

# Test ssh-exec with command that has spaces
log_test "Testing ssh-exec with complex command..."
start_timer
EXEC_OUTPUT=$("${DMUX}" ssh-exec "${LOCAL_ID_FULL}" "echo 'hello world' && pwd")
log_time "ssh-exec complex command" $(elapsed_ms)
if [[ "${EXEC_OUTPUT}" == *"hello world"* ]] && [[ "${EXEC_OUTPUT}" == *"/workspace"* ]]; then
    log_info "PASS: ssh-exec complex command"
else
    log_error "FAIL: ssh-exec complex command"
    log_error "Output: ${EXEC_OUTPUT}"
    exit 1
fi

# Test interactive SSH with full UUID
log_test "Testing interactive SSH with l_<full-uuid>..."
start_timer
INTERACTIVE_OUTPUT=$(echo "echo 'interactive full' && exit" | timeout 10 "${DMUX}" ssh "${LOCAL_ID_FULL}" 2>&1 || true)
log_time "interactive SSH l_<full-uuid>" $(elapsed_ms)
if [[ "${INTERACTIVE_OUTPUT}" == *"interactive full"* ]] || [[ "${INTERACTIVE_OUTPUT}" == *"Connected"* ]]; then
    log_info "PASS: interactive SSH l_<full-uuid>"
else
    log_warn "WARN: interactive SSH l_<full-uuid> may have issues"
fi

# Test interactive SSH with short prefix
log_test "Testing interactive SSH with l_<short-prefix>..."
start_timer
INTERACTIVE_OUTPUT=$(echo "echo 'interactive short' && exit" | timeout 10 "${DMUX}" ssh "${LOCAL_ID_SHORT}" 2>&1 || true)
log_time "interactive SSH l_<short-prefix>" $(elapsed_ms)
if [[ "${INTERACTIVE_OUTPUT}" == *"interactive short"* ]] || [[ "${INTERACTIVE_OUTPUT}" == *"Connected"* ]]; then
    log_info "PASS: interactive SSH l_<short-prefix>"
else
    log_warn "WARN: interactive SSH l_<short-prefix> may have issues"
fi

# ============================================================================
# CLOUD SANDBOX TESTS (requires www server on localhost:9779)
# ============================================================================

log_info "=========================================="
log_info "CLOUD SANDBOX TESTS"
log_info "=========================================="

# Check if www server is running (required for cloud VM operations)
if ! curl -sf "http://localhost:9779/api" >/dev/null 2>&1; then
    log_error "FAIL: www server not running on localhost:9779"
    log_error "Start with: ./scripts/dev.sh"
    exit 1
fi
log_info "www server is running"

# Set API URL to local dev server
export CMUX_API_URL="http://localhost:9779"

# Create a cloud sandbox with short TTL (2 minutes)
# Note: --team is optional - CLI auto-detects from default team or single team
log_test "Creating cloud sandbox (TTL=120s)..."
start_timer
VM_OUTPUT=$("${DMUX}" vm create --ttl 120 --output json 2>&1) || {
    log_error "FAIL: Failed to create cloud sandbox"
    log_error "Output: ${VM_OUTPUT}"
    log_error "Check authentication with 'dmux auth status'"
    exit 1
}
log_time "create cloud sandbox" $(elapsed_ms)

# Extract JSON from output (skip "Creating cloud VM..." line and parse multi-line JSON)
VM_JSON=$(echo "${VM_OUTPUT}" | sed -n '/^{/,/^}/p')
if [[ -z "${VM_JSON}" ]]; then
    log_error "FAIL: Could not extract JSON from vm create output"
    log_error "Output: ${VM_OUTPUT}"
    exit 1
fi

if ! echo "${VM_JSON}" | jq -e '.instanceId' >/dev/null 2>&1; then
    log_error "FAIL: Invalid response from vm create"
    log_error "JSON: ${VM_JSON}"
    exit 1
fi

CLOUD_SANDBOX_ID=$(echo "${VM_JSON}" | jq -r '.instanceId')
# Strip morphvm_ prefix if present for display
CLOUD_DISPLAY_ID="${CLOUD_SANDBOX_ID#morphvm_}"
log_info "Created cloud sandbox: ${CLOUD_DISPLAY_ID}"

# Use c_ prefix for cloud sandboxes
CLOUD_ID="c_${CLOUD_DISPLAY_ID}"
log_info "Cloud ID: ${CLOUD_ID}"

# Wait a moment for the sandbox to be ready
log_info "Waiting for cloud sandbox to be ready..."
sleep 5

# Test ssh-exec with cloud sandbox
log_test "Testing ssh-exec with c_<id>..."
start_timer
EXEC_OUTPUT=$("${DMUX}" ssh-exec "${CLOUD_ID}" echo "hello cloud" 2>&1) || true
log_time "ssh-exec c_<id>" $(elapsed_ms)
if [[ "${EXEC_OUTPUT}" == *"hello cloud"* ]]; then
    log_info "PASS: ssh-exec c_<id>"
else
    log_error "FAIL: ssh-exec c_<id>"
    log_error "Output: ${EXEC_OUTPUT}"
    exit 1
fi

# Test ssh-exec exit code propagation
log_test "Testing cloud ssh-exec exit code propagation..."
start_timer
set +e
"${DMUX}" ssh-exec "${CLOUD_ID}" "exit 42"
CLOUD_EXIT_CODE=$?
set -e
log_time "cloud ssh-exec exit code" $(elapsed_ms)
if [[ "${CLOUD_EXIT_CODE}" -eq 42 ]]; then
    log_info "PASS: cloud ssh-exec exit code propagation (got ${CLOUD_EXIT_CODE})"
else
    log_error "FAIL: cloud ssh-exec exit code (expected 42, got ${CLOUD_EXIT_CODE})"
    exit 1
fi

# Test interactive SSH with cloud sandbox
log_test "Testing interactive SSH with c_<id>..."
start_timer
INTERACTIVE_OUTPUT=$(echo "echo 'interactive cloud' && exit" | timeout 15 "${DMUX}" ssh "${CLOUD_ID}" 2>&1 || true)
log_time "interactive SSH c_<id>" $(elapsed_ms)
if [[ "${INTERACTIVE_OUTPUT}" == *"interactive cloud"* ]] || [[ "${INTERACTIVE_OUTPUT}" == *"Connected"* ]]; then
    log_info "PASS: interactive SSH c_<id>"
else
    log_warn "WARN: interactive SSH c_<id> may have issues"
fi

log_info "Cloud sandbox will auto-pause in ~2 minutes"

# ============================================================================
# SUMMARY
# ============================================================================

TOTAL_TIME=$(( $(now_ms) - TEST_START_TIME ))
log_info "=========================================="
log_info "ALL TESTS PASSED"
log_time "total" ${TOTAL_TIME}
log_info "=========================================="
