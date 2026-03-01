#!/usr/bin/env bash
# Phase 3 Structural Tests — no Docker required
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/tests/helpers/assert.sh"

echo "=== Phase 3: Structural Validation ==="

CONTAINER_SETTINGS="${REPO_ROOT}/.claude/settings.container.json"
CLAUDE_MD="${REPO_ROOT}/.claude/CLAUDE.md"

# --- File existence ---
echo ""
echo "--- File existence ---"
assert_file_exists "${CONTAINER_SETTINGS}"
assert_file_exists "${CLAUDE_MD}"
assert_dir_exists "${REPO_ROOT}/.claude"

# --- settings.container.json validity ---
echo ""
echo "--- settings.container.json validity ---"
assert_json_valid "${CONTAINER_SETTINGS}"

# --- Container settings.container.json required structure ---
echo ""
echo "--- Container settings.container.json structure ---"
assert_json_has_key "${CONTAINER_SETTINGS}" "permissions"
assert_json_has_key "${CONTAINER_SETTINGS}" "permissions.allow"
assert_json_has_key "${CONTAINER_SETTINGS}" "permissions.deny"
assert_json_has_key "${CONTAINER_SETTINGS}" "permissions.ask"
assert_json_has_key "${CONTAINER_SETTINGS}" "sandbox"
assert_json_has_key "${CONTAINER_SETTINGS}" "vibeshield_managed"

# --- Sandbox configuration (container template) ---
echo ""
echo "--- Sandbox configuration (container template) ---"
python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
sandbox = data['sandbox']
assert sandbox.get('enabled') is True, 'sandbox.enabled should be true in container template'
assert sandbox.get('enableWeakerNestedSandbox') is True, 'enableWeakerNestedSandbox should be true'
assert sandbox.get('allowUnsandboxedCommands') is True, 'allowUnsandboxedCommands should be true (bwrap unavailable in Docker)'
assert \"network\" in sandbox, 'sandbox.network missing'
assert \"allowedDomains\" in sandbox['network'], 'sandbox.network.allowedDomains missing'
" "${CONTAINER_SETTINGS}" && pass "Container sandbox config correct" || fail "Container sandbox config invalid"

# --- Allow list has core tools (container template) ---
echo ""
echo "--- Allow list core tools ---"
python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
allow = data['permissions']['allow']
for tool in ['Read', 'Glob', 'Grep', 'Edit', 'Write']:
    assert tool in allow, f'{tool} missing from allow list'
" "${CONTAINER_SETTINGS}" && pass "Core tools in allow list (container)" || fail "Core tools missing from allow list (container)"

# --- Container has WebFetch/WebSearch in allow ---
echo ""
echo "--- Container WebFetch/WebSearch in allow ---"
python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
allow = data['permissions']['allow']
assert 'WebFetch' in allow, 'WebFetch missing from container allow'
assert 'WebSearch' in allow, 'WebSearch missing from container allow'
" "${CONTAINER_SETTINGS}" && pass "Container WebFetch/WebSearch in allow" || fail "Container WebFetch/WebSearch not in allow"

# --- vibeshield_managed metadata (container template) ---
echo ""
echo "--- vibeshield_managed metadata (container template) ---"
python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
managed = data['vibeshield_managed']
assert 'mode' in managed, 'mode missing from vibeshield_managed'
assert 'managed_patterns' in managed, 'managed_patterns missing'
assert isinstance(managed['managed_patterns'], list), 'managed_patterns should be a list'
assert len(managed['managed_patterns']) > 0, 'managed_patterns should not be empty'
" "${CONTAINER_SETTINGS}" && pass "vibeshield_managed metadata correct" || fail "vibeshield_managed metadata invalid"

# --- CLAUDE.md required sections ---
echo ""
echo "--- CLAUDE.md sections ---"
assert_contains "${CLAUDE_MD}" "Security Model"
assert_contains "${CLAUDE_MD}" "Network Modes"
assert_contains "${CLAUDE_MD}" "Git Rules"
assert_contains "${CLAUDE_MD}" "Secrets"
assert_contains "${CLAUDE_MD}" "skip-permissions"
assert_contains "${CLAUDE_MD}" "defense-in-depth"
assert_contains "${CLAUDE_MD}" "config.local.yaml"

# --- CLAUDE.md warns about open mode ---
echo ""
echo "--- CLAUDE.md open mode warning ---"
assert_contains "${CLAUDE_MD}" "open.*exfil\|Zero exfil\|no exfiltration\|zero exfil"

# --- CLAUDE.md mentions soft guardrail ---
echo ""
echo "--- CLAUDE.md soft guardrail framing ---"
assert_contains "${CLAUDE_MD}" "soft guardrail\|NOT a security boundary"

summary
