#!/usr/bin/env bash
# Phase 1 Container Integration Tests — requires Docker/OrbStack
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/tests/helpers/assert.sh"

echo "=== Phase 1: Container Integration Tests ==="

# Check for devcontainer CLI
if ! command -v devcontainer &>/dev/null; then
  echo "SKIP: devcontainer CLI not installed (npm install -g @devcontainers/cli)"
  exit 0
fi

# Check for Docker
if ! docker info &>/dev/null 2>&1; then
  echo "SKIP: Docker not running"
  exit 0
fi

CONTAINER_ID=""

cleanup() {
  if [[ -n "${CONTAINER_ID}" ]]; then
    echo "Cleaning up container..."
    docker rm -f "${CONTAINER_ID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo ""
echo "--- Building devcontainer ---"
BUILD_OUTPUT=$(devcontainer build --workspace-folder "${REPO_ROOT}" 2>&1) || {
  fail "devcontainer build failed"
  echo "${BUILD_OUTPUT}"
  summary
  exit 1
}
pass "devcontainer build succeeded"

echo ""
echo "--- Starting devcontainer ---"
UP_STDERR=$(mktemp)
UP_OUTPUT=$(devcontainer up --workspace-folder "${REPO_ROOT}" 2>"${UP_STDERR}") || {
  fail "devcontainer up failed"
  cat "${UP_STDERR}"
  rm -f "${UP_STDERR}"
  summary
  exit 1
}
rm -f "${UP_STDERR}"
pass "devcontainer up succeeded"

# Extract container ID from JSON output (stdout only, no stderr mixing)
CONTAINER_ID=$(echo "${UP_OUTPUT}" | tail -1 | python3 -c "import sys,json; print(json.load(sys.stdin)['containerId'])" 2>/dev/null || echo "")
if [[ -z "${CONTAINER_ID}" ]]; then
  # Fallback: find container by label
  CONTAINER_ID=$(docker ps -q --filter "label=devcontainer.local_folder=${REPO_ROOT}" | head -1)
fi

if [[ -z "${CONTAINER_ID}" ]]; then
  fail "Could not determine container ID"
  summary
  exit 1
fi

exec_in_container() {
  devcontainer exec --workspace-folder "${REPO_ROOT}" "$@" 2>&1
}

# --- Tool availability ---
echo ""
echo "--- Tool availability ---"
exec_in_container claude --version &>/dev/null && pass "claude CLI available" || fail "claude CLI not available"
exec_in_container gh --version &>/dev/null && pass "gh CLI available" || fail "gh CLI not available"
exec_in_container git --version &>/dev/null && pass "git available" || fail "git not available"
exec_in_container node --version &>/dev/null && pass "node available" || fail "node not available"
exec_in_container iptables --version &>/dev/null && pass "iptables available" || fail "iptables not available"
exec_in_container python3 -c "import yaml" &>/dev/null && pass "python3-yaml available" || fail "python3-yaml not available"
exec_in_container dig -v &>/dev/null && pass "dig (dnsutils) available" || fail "dig not available"
exec_in_container bwrap --version &>/dev/null && pass "bubblewrap available (optional)" || pass "bubblewrap not installed (intentional — Docker seccomp incompatible)"
exec_in_container ralphex --help &>/dev/null && pass "ralphex available (optional)" || pass "ralphex not installed (optional)"
exec_in_container codex --version &>/dev/null && pass "codex available (optional)" || pass "codex not installed (optional)"

# --- Directory existence ---
echo ""
echo "--- Directory existence ---"
exec_in_container test -d /var/log/vibeshield && pass "/var/log/vibeshield exists" || fail "/var/log/vibeshield missing"
exec_in_container test -d /opt/vibeshield/defaults && pass "/opt/vibeshield/defaults exists" || fail "/opt/vibeshield/defaults missing"
exec_in_container test -d /opt/vibeshield/bin && pass "/opt/vibeshield/bin exists" || fail "/opt/vibeshield/bin missing"

# --- Default shell is zsh ---
echo ""
echo "--- Default shell ---"
SHELL_OUT=$(exec_in_container bash -c 'echo $SHELL') || true
if echo "${SHELL_OUT}" | grep -q "zsh"; then
  pass "Default shell is zsh"
else
  fail "Default shell is not zsh (got: ${SHELL_OUT})"
fi

# --- PID 1 is tini (init: true) ---
echo ""
echo "--- Init process ---"
PID1=$(exec_in_container cat /proc/1/comm 2>/dev/null) || true
if echo "${PID1}" | grep -qE "tini|docker-init"; then
  pass "PID 1 is init process (${PID1})"
else
  fail "PID 1 is not an init process (got: ${PID1})"
fi

# --- Firewall log directory exists (firewall runs at container start) ---
echo ""
echo "--- Firewall log directory ---"
if exec_in_container test -d /var/log/vibeshield 2>/dev/null; then
  pass "Firewall log directory exists"
else
  fail "Firewall log directory /var/log/vibeshield missing"
fi

# --- HISTFILE env var set ---
echo ""
echo "--- HISTFILE configuration ---"
HISTFILE_OUT=$(exec_in_container bash -c 'echo $HISTFILE') || true
if echo "${HISTFILE_OUT}" | grep -q "/home/vscode/.local/share/zsh/.zsh_history"; then
  pass "HISTFILE points to volume-backed path"
else
  fail "HISTFILE not set correctly (got: ${HISTFILE_OUT})"
fi

# --- Proxy networking (claw-wrap in-container daemon, ADR-012) ---
# The daemon runs inside the container (not on the host). /run/openclaw is
# created by the launcher at daemon start time, not by a bind mount.
# No host.docker.internal dependency. socat is still needed by the
# Claude Code sandbox runtime (not by vibeshield).
echo ""
echo "--- Proxy networking (container-side readiness) ---"

# /run/openclaw does NOT exist as a bind mount (ADR-012 removed it)
# It is created by claw_wrap_container_setup() at daemon start time.
# In CI (no daemon running), it should not exist.
if exec_in_container mountpoint -q /run/openclaw 2>/dev/null; then
  fail "/run/openclaw is a stale bind mount (container needs rebuild)"
else
  pass "/run/openclaw is not a bind mount (correct for ADR-012)"
fi

# socat is available in container (needed by Claude Code sandbox runtime)
exec_in_container socat -V &>/dev/null && pass "socat available in container" || fail "socat not available"

# claw-wrap system user exists (SA15 — least-privilege daemon)
if exec_in_container id claw-wrap &>/dev/null; then
  pass "claw-wrap system user exists (uid=$(exec_in_container id -u claw-wrap))"
else
  pass "claw-wrap user not found (expected in CI — created at launch time)"
fi

# Verify /usr/bin/gh and /usr/bin/git exist (devcontainer features installed them)
exec_in_container test -f /usr/bin/gh && pass "/usr/bin/gh exists" || fail "/usr/bin/gh missing"
exec_in_container test -f /usr/bin/git && pass "/usr/bin/git exists" || fail "/usr/bin/git missing"

summary
