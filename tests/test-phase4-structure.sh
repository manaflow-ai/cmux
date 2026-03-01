#!/usr/bin/env bash
# Phase 4 Structural Tests — no Docker required
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/tests/helpers/assert.sh"

DC_JSON="${REPO_ROOT}/.devcontainer/devcontainer.json"

echo "=== Phase 4: Structural Validation ==="

# --- File existence ---
echo ""
echo "--- File existence ---"
assert_file_exists "${REPO_ROOT}/.env.vibeshield.example"

# --- .env.vibeshield.example has all keys ---
echo ""
echo "--- .env.vibeshield.example keys ---"
assert_contains "${REPO_ROOT}/.env.vibeshield.example" "ANTHROPIC_API_KEY"
assert_contains "${REPO_ROOT}/.env.vibeshield.example" "GITHUB_TOKEN"
assert_contains "${REPO_ROOT}/.env.vibeshield.example" "OP_VIBESHIELD_SERVICE_ACCOUNT_TOKEN"
# NETWORK_MODE removed from remoteEnv — mode is read from state file only

# --- .env.vibeshield.example has security guidance ---
echo ""
echo "--- Credential security guidance ---"
assert_contains "${REPO_ROOT}/.env.vibeshield.example" "fine-grained\|Fine-grained"
assert_contains "${REPO_ROOT}/.env.vibeshield.example" "NEVER commit"
assert_contains "${REPO_ROOT}/.env.vibeshield.example" "op://"

# --- devcontainer.json has 1Password CLI install ---
echo ""
echo "--- 1Password CLI install ---"
assert_json_valid "${DC_JSON}"
python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
cmd = data['onCreateCommand']['firewall-deps']
assert '1password-cli' in cmd, 'Should install 1password-cli'
assert 'dpkg --print-architecture' in cmd, 'Should detect architecture'
" "${DC_JSON}" && pass "1Password CLI install correct" || fail "1Password install misconfigured"

# --- remoteEnv still has all required env vars ---
echo ""
echo "--- remoteEnv completeness ---"
python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
env = data['remoteEnv']
required = ['ANTHROPIC_API_KEY', 'GITHUB_TOKEN', 'HISTFILE']
for key in required:
    assert key in env, f'{key} missing from remoteEnv'
" "${DC_JSON}" && pass "All remoteEnv vars present" || fail "Missing remoteEnv vars"

# --- .gitignore still protects .env files ---
echo ""
echo "--- .gitignore .env protection ---"
assert_contains "${REPO_ROOT}/.gitignore" ".env"
assert_contains "${REPO_ROOT}/.gitignore" "!.env.vibeshield.example"

summary
