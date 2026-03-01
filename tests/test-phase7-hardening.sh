#!/usr/bin/env bash
set -euo pipefail

# Phase 7: Red Team Round 2 hardening structural tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers/assert.sh"

# Fixed-string variant for patterns containing regex metacharacters (*, +, etc.)
assert_contains_literal() {
  local file="$1"
  local pattern="$2"
  if grep -F -q "$pattern" "$file" 2>/dev/null; then
    pass "File contains literal: $pattern"
  else
    fail "File missing literal: $pattern in $file"
  fi
}

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Phase 7 Structural Tests (Hardening) ==="

CONTAINER_SETTINGS="$REPO_ROOT/.claude/settings.container.json"
FIREWALL_PY="$REPO_ROOT/.devcontainer/network/firewall.py"
SYNC_PERMS="$REPO_ROOT/.devcontainer/sync-permissions.py"
HEALTH_CHECK="$REPO_ROOT/.devcontainer/network/health-check.sh"
DEVCONTAINER="$REPO_ROOT/.devcontainer/devcontainer.json"
APPLY_FW="$REPO_ROOT/.devcontainer/network/apply-firewall.sh"
RELOAD_FW="$REPO_ROOT/.devcontainer/network/reload-firewall.sh"
REFRESH_DNS="$REPO_ROOT/.devcontainer/network/refresh-dns.sh"

# --- P0-1: /proc/self/environ deny rules (container template) ---
echo ""
echo "--- P0-1: /proc/self/environ deny rules (container template) ---"

assert_contains "$CONTAINER_SETTINGS" '"Read(//proc/self/environ)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Read(//proc/self/environ*)"'
assert_contains "$CONTAINER_SETTINGS" '"Read(//proc/thread-self/environ)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Read(//proc/thread-self/environ*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Bash(cat /proc/self/environ*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Bash(cat /proc/thread-self/environ*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Bash(strings /proc/self/*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Bash(strings /proc/thread-self/*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Bash(python3 -c*environ*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Bash(python -c*environ*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Bash(printenv)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Bash(node -e*process.env*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Read(//etc/sudoers*)"'

# --- P0-2: Restricted test runner (container template) ---
echo ""
echo "--- P0-2: Vibeshield infrastructure protection (container template) ---"

assert_contains_literal "$CONTAINER_SETTINGS" '"Write(.devcontainer/network/health-check.sh*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Edit(.devcontainer/network/health-check.sh*)"'

# --- P1-7: Git hooks protection (container template) ---
echo ""
echo "--- P1-7: Git hooks protection (container template) ---"

assert_contains_literal "$CONTAINER_SETTINGS" '"Write(.git/hooks/*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Edit(.git/hooks/*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Write(.git/config*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Edit(.git/config*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Bash(git config*core.hooksPath*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Bash(git*-c*hooksPath*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Bash(sed*.git/config*)"'

# --- P2-8: Shell dotfile protection (container template) ---
echo ""
echo "--- P2-8: Shell dotfile protection (container template) ---"

assert_contains_literal "$CONTAINER_SETTINGS" '"Write(//home/vscode/.bashrc*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Write(//home/vscode/.zshrc*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Write(//home/vscode/.zshenv*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Write(//home/vscode/.profile*)"'
assert_contains_literal "$CONTAINER_SETTINGS" '"Edit(//home/vscode/.bashrc*)"'

# --- python3 -I (isolated mode) ---
echo ""
echo "--- python3 -I hardening ---"

assert_contains "$APPLY_FW" 'python3 -I'
assert_contains "$RELOAD_FW" 'python3 -I'
assert_contains "$REFRESH_DNS" 'python3 -I'

# --- config.local.yaml validation ---
echo ""
echo "--- config.local.yaml validation ---"

assert_contains "$FIREWALL_PY" '_validate_local_config'
assert_contains "$SYNC_PERMS" '_validate_local_config'
assert_contains "$FIREWALL_PY" 'LOCAL_CONFIG_ALLOWED_KEYS'
assert_contains "$FIREWALL_PY" 'additional_domains'
assert_contains "$FIREWALL_PY" 'is_loopback'

# --- Authoritative settings.json + file hashing ---
echo ""
echo "--- Authoritative settings.json + hashing ---"

assert_contains "$SYNC_PERMS" 'write_authoritative_copy'
assert_contains "$SYNC_PERMS" 'write_file_hashes'
assert_contains "$SYNC_PERMS" 'sha256'
assert_contains "$HEALTH_CHECK" 'SEC-4'
assert_contains "$HEALTH_CHECK" 'SEC-5'
assert_contains "$HEALTH_CHECK" 'authoritative'

# --- Git hooks protection (devcontainer + health-check) ---
echo ""
echo "--- Git hooks system config ---"

assert_contains "$DEVCONTAINER" 'core.hooksPath'
assert_contains "$DEVCONTAINER" '/opt/vibeshield/hooks'
assert_contains "$HEALTH_CHECK" 'SEC-6'
assert_contains "$HEALTH_CHECK" 'core.hooksPath'

# --- hidepid=2 ---
echo ""
echo "--- /proc hidepid=2 ---"

assert_contains "$DEVCONTAINER" 'hidepid=2'
assert_contains "$HEALTH_CHECK" 'SEC-7'
assert_contains "$HEALTH_CHECK" 'hidepid'

# --- socat present (needed by Claude Code sandbox proxy) ---
echo ""
echo "--- socat present ---"

assert_contains "$DEVCONTAINER" "socat"

# --- Sandbox configuration (container template) ---
echo ""
echo "--- Sandbox configuration (container template) ---"

SANDBOX_ENABLED=$(python3 -I -c "import json; d=json.load(open('$CONTAINER_SETTINGS')); print(d.get('sandbox',{}).get('enabled', False))" 2>/dev/null)
if [[ "$SANDBOX_ENABLED" == "True" ]]; then
  pass "Container template sandbox enabled=true"
else
  fail "Container template sandbox enabled: expected True, got $SANDBOX_ENABLED"
fi

SANDBOX_UNSANDBOXED=$(python3 -I -c "import json; d=json.load(open('$CONTAINER_SETTINGS')); print(d.get('sandbox',{}).get('allowUnsandboxedCommands', True))" 2>/dev/null)
if [[ "$SANDBOX_UNSANDBOXED" == "True" ]]; then
  pass "allowUnsandboxedCommands: $SANDBOX_UNSANDBOXED (bwrap unavailable — fallback enabled)"
else
  fail "allowUnsandboxedCommands: expected True, got $SANDBOX_UNSANDBOXED"
fi

SANDBOX_EXCLUDED=$(python3 -I -c "import json; d=json.load(open('$CONTAINER_SETTINGS')); print('docker' in d.get('sandbox',{}).get('excludedCommands',[]))" 2>/dev/null)
if [[ "$SANDBOX_EXCLUDED" == "True" ]]; then
  pass "excludedCommands contains docker"
else
  fail "excludedCommands missing docker"
fi

SANDBOX_AUTO=$(python3 -I -c "import json; d=json.load(open('$CONTAINER_SETTINGS')); print(d.get('sandbox',{}).get('autoAllowBashIfSandboxed', 'MISSING'))" 2>/dev/null)
if [[ "$SANDBOX_AUTO" == "False" ]]; then
  pass "autoAllowBashIfSandboxed: $SANDBOX_AUTO (secure default)"
else
  fail "autoAllowBashIfSandboxed: expected False, got $SANDBOX_AUTO"
fi

# --- Double-slash prefix regression check (container template) ---
echo ""
echo "--- Double-slash prefix check (container template) ---"

DOUBLE_SLASH_COUNT=$(python3 -I -c "import json; d=json.load(open('$CONTAINER_SETTINGS')); print(sum(1 for r in d['permissions']['deny'] if any(r.startswith(t + '(//') for t in ['Read','Write','Edit'])))" 2>/dev/null)
if [[ "$DOUBLE_SLASH_COUNT" -eq 44 ]]; then
  pass "Double-slash absolute path deny rules: $DOUBLE_SLASH_COUNT"
else
  fail "Double-slash absolute path deny rules: expected 44, got $DOUBLE_SLASH_COUNT"
fi

# --- Container template permission counts ---
echo ""
echo "--- Container template permission counts ---"

read ALLOW_COUNT DENY_COUNT ASK_COUNT < <(python3 -I -c "import json; d=json.load(open('$CONTAINER_SETTINGS')); p=d['permissions']; print(len(p['allow']), len(p['deny']), len(p['ask']))" 2>/dev/null)

if [[ "$ALLOW_COUNT" -eq 64 ]]; then
  pass "Container allow rules count: $ALLOW_COUNT"
else
  fail "Container allow rules count: expected 64, got $ALLOW_COUNT"
fi

if [[ "$DENY_COUNT" -eq 176 ]]; then
  pass "Container deny rules count: $DENY_COUNT"
else
  fail "Container deny rules count: expected 176, got $DENY_COUNT"
fi

if [[ "$ASK_COUNT" -eq 7 ]]; then
  pass "Container ask rules count: $ASK_COUNT"
else
  fail "Container ask rules count: expected 7, got $ASK_COUNT"
fi

# --- Container template self-protection ---
echo ""
echo "--- Container template self-protection ---"

python3 -I -c "
import json, sys
for path in sys.argv[1:]:
    with open(path) as f:
        d = json.load(f)
    deny = set(d['permissions']['deny'])
    assert 'Write(.claude/settings.container.json*)' in deny, f'Write protection missing in {path}'
    assert 'Edit(.claude/settings.container.json*)' in deny, f'Edit protection missing in {path}'
" "$CONTAINER_SETTINGS" && pass "Container template self-protection present" || fail "Container template self-protection missing"

# --- Summary ---
echo ""
summary
