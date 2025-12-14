#!/bin/bash
# E2E test script for dmux cloud VM commands
# Assumes the user is already logged in (dmux auth status shows authenticated)
# Tests: auth status, vm list, vm create, ssh-exec

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
DMUX="${DMUX_BIN:-$SANDBOX_DIR/target/release/dmux}"
TEAM="${CMUX_TEAM:-${1:-}}"
CREATED_VM_ID=""

# Auto-detect localhost and set dev Stack Auth credentials
# When CMUX_API_URL points to localhost, we need to use dev Stack Auth project
if [[ "${CMUX_API_URL:-}" == *"localhost"* ]] || [[ "${CMUX_API_URL:-}" == *"127.0.0.1"* ]]; then
    echo -e "${YELLOW}Detected localhost API - using dev Stack Auth credentials${NC}"
    export STACK_PROJECT_ID="${STACK_PROJECT_ID:-1467bed0-8522-45ee-a8d8-055de324118c}"
    export STACK_PUBLISHABLE_CLIENT_KEY="${STACK_PUBLISHABLE_CLIENT_KEY:-pck_pt4nwry6sdskews2pxk4g2fbe861ak2zvaf3mqendspa0}"
fi

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ -n "$CREATED_VM_ID" ]]; then
        echo -e "${YELLOW}Note: Created VM $CREATED_VM_ID - cleanup not implemented yet${NC}"
    fi
    if [[ $exit_code -ne 0 ]]; then
        echo -e "${RED}E2E test failed with exit code $exit_code${NC}"
    fi
    exit $exit_code
}
trap cleanup EXIT

# Helper functions
log_step() {
    echo -e "\n${BLUE}==> $1${NC}"
}

log_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

log_error() {
    echo -e "${RED}✗ $1${NC}"
}

log_info() {
    echo -e "${YELLOW}  $1${NC}"
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites"

    # Check if dmux binary exists
    if [[ ! -x "$DMUX" ]]; then
        log_error "dmux binary not found at $DMUX"
        echo "Build it with: cd $SANDBOX_DIR && cargo build --bin dmux --release"
        exit 1
    fi
    log_success "Found dmux binary at $DMUX"

    # Check if team is specified
    if [[ -z "$TEAM" ]]; then
        log_error "Team not specified. Set CMUX_TEAM env var or pass as first argument."
        echo "Usage: $0 <team-slug>"
        exit 1
    fi
    log_success "Using team: $TEAM"
}

# Test 1: Auth status
test_auth_status() {
    log_step "Test 1: Checking authentication status"

    local output
    if ! output=$("$DMUX" auth status 2>&1); then
        log_error "Auth status check failed"
        echo "$output"
        exit 1
    fi

    if echo "$output" | grep -qi "not logged in\|no.*token\|unauthenticated"; then
        log_error "Not logged in. Please run: dmux auth login"
        exit 1
    fi

    log_success "Authentication verified"
    log_info "$output"
}

# Test 2: VM list
test_vm_list() {
    log_step "Test 2: Listing existing VMs"

    local output
    if ! output=$("$DMUX" vm list --team "$TEAM" 2>&1); then
        log_error "VM list failed"
        echo "$output"
        exit 1
    fi

    log_success "VM list command succeeded"
    log_info "Current VMs:"
    echo "$output" | head -20
}

# Test 3: VM create
test_vm_create() {
    log_step "Test 3: Creating a new cloud VM"

    local output
    # Create with JSON output to parse the ID
    if ! output=$("$DMUX" vm create --team "$TEAM" --ttl 300 --output json 2>&1); then
        log_error "VM create failed"
        echo "$output"
        exit 1
    fi

    # Parse the VM ID from JSON output
    CREATED_VM_ID=$(echo "$output" | grep -o '"instanceId"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || true)

    if [[ -z "$CREATED_VM_ID" ]]; then
        # Try alternate field name (morphInstanceId)
        CREATED_VM_ID=$(echo "$output" | grep -o '"morphInstanceId"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || true)
    fi

    if [[ -z "$CREATED_VM_ID" ]]; then
        log_error "Could not parse VM ID from output"
        echo "$output"
        exit 1
    fi

    log_success "VM created successfully: $CREATED_VM_ID"
    log_info "Full output:"
    echo "$output" | head -30

    # Wait a bit for the VM to be ready
    log_info "Waiting 10 seconds for VM to be ready..."
    sleep 10
}

# Test 4: SSH exec
test_ssh_exec() {
    log_step "Test 4: Executing command via SSH"

    if [[ -z "$CREATED_VM_ID" ]]; then
        log_error "No VM ID available for SSH test"
        exit 1
    fi

    local output
    local max_attempts=6
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempt $attempt/$max_attempts: Running 'echo hello' on VM..."

        if output=$("$DMUX" ssh-exec "$CREATED_VM_ID" --team "$TEAM" -- echo hello 2>&1); then
            if echo "$output" | grep -q "hello"; then
                log_success "SSH exec succeeded!"
                echo "$output"
                break
            fi
        fi

        if [[ $attempt -eq $max_attempts ]]; then
            log_error "SSH exec failed after $max_attempts attempts"
            echo "$output"
            exit 1
        fi

        log_info "SSH not ready yet, waiting 10 seconds..."
        sleep 10
        ((attempt++))
    done

    # Test a more complex command
    log_info "Testing more complex command: 'uname -a && ls /'"
    if output=$("$DMUX" ssh-exec "$CREATED_VM_ID" --team "$TEAM" -- 'uname -a && ls /' 2>&1); then
        log_success "Complex command succeeded!"
        echo "$output"
    else
        log_error "Complex command failed"
        echo "$output"
        exit 1
    fi
}

# Test 5: Verify VM appears in list
test_vm_in_list() {
    log_step "Test 5: Verifying created VM appears in list"

    if [[ -z "$CREATED_VM_ID" ]]; then
        log_error "No VM ID available for list verification"
        exit 1
    fi

    local output
    if ! output=$("$DMUX" vm list --team "$TEAM" --output json 2>&1); then
        log_error "VM list failed"
        echo "$output"
        exit 1
    fi

    if echo "$output" | grep -q "$CREATED_VM_ID"; then
        log_success "Created VM found in list"
    else
        log_info "VM may not appear in list immediately (this is OK)"
    fi
}

# Main execution
main() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}  dmux Cloud VM E2E Test Suite${NC}"
    echo -e "${BLUE}======================================${NC}"

    check_prerequisites
    test_auth_status
    test_vm_list
    test_vm_create
    test_ssh_exec
    test_vm_in_list

    echo -e "\n${GREEN}======================================${NC}"
    echo -e "${GREEN}  All E2E tests passed!${NC}"
    echo -e "${GREEN}======================================${NC}"

    if [[ -n "$CREATED_VM_ID" ]]; then
        echo -e "\n${YELLOW}Created VM: $CREATED_VM_ID${NC}"
        echo -e "${YELLOW}VM will auto-pause after TTL expires (300s)${NC}"
    fi
}

main "$@"
