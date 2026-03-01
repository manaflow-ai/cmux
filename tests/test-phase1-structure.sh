#!/usr/bin/env bash
# Phase 1 Structural Tests — no Docker required
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/tests/helpers/assert.sh"

DC_JSON="${REPO_ROOT}/.devcontainer/devcontainer.json"

echo "=== Phase 1: Structural Validation ==="

# --- File existence ---
echo ""
echo "--- File existence ---"
assert_file_exists "${DC_JSON}"
assert_file_exists "${REPO_ROOT}/.devcontainer/network/apply-firewall.sh"
assert_file_exists "${REPO_ROOT}/.gitignore"
assert_file_exists "${REPO_ROOT}/tests/helpers/assert.sh"

# --- JSON validity ---
echo ""
echo "--- JSON validity ---"
assert_json_valid "${DC_JSON}"

# --- devcontainer.json required keys ---
echo ""
echo "--- devcontainer.json required keys ---"
assert_json_has_key "${DC_JSON}" "name"
assert_json_has_key "${DC_JSON}" "image"
assert_json_has_key "${DC_JSON}" "features"
assert_json_has_key "${DC_JSON}" "init"
assert_json_has_key "${DC_JSON}" "capAdd"
assert_json_has_key "${DC_JSON}" "onCreateCommand"
assert_json_has_key "${DC_JSON}" "postStartCommand"
assert_json_has_key "${DC_JSON}" "mounts"
assert_json_has_key "${DC_JSON}" "remoteEnv"

# --- Capabilities ---
echo ""
echo "--- Capabilities ---"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
caps = d['capAdd']
assert 'NET_ADMIN' in caps, 'NET_ADMIN missing'
assert 'NET_RAW' in caps, 'NET_RAW missing'
" "${DC_JSON}" && pass "NET_ADMIN and NET_RAW capabilities present" || fail "Missing required capabilities"

# --- init: true ---
echo ""
echo "--- Init process ---"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
assert d['init'] is True
" "${DC_JSON}" && pass "init: true is set" || fail "init: true not set"

# --- Features include node 24 ---
echo ""
echo "--- Features ---"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
features = d['features']
node_key = [k for k in features if 'node' in k]
assert len(node_key) == 1, 'Node feature not found'
assert features[node_key[0]].get('version') == '24', 'Node version not 24'
" "${DC_JSON}" && pass "Node 24 feature configured" || fail "Node 24 feature missing or misconfigured"

# --- onCreateCommand has all three parallel tasks ---
echo ""
echo "--- onCreateCommand parallel tasks ---"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
cmds = d['onCreateCommand']
assert 'claude-code' in cmds, 'claude-code task missing'
assert 'firewall-deps' in cmds, 'firewall-deps task missing'
assert 'setup' in cmds, 'setup task missing'
" "${DC_JSON}" && pass "All three onCreateCommand tasks present" || fail "Missing onCreateCommand tasks"

# --- DEBIAN_FRONTEND=noninteractive in firewall-deps ---
echo ""
echo "--- Non-interactive apt ---"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
cmd = d['onCreateCommand']['firewall-deps']
assert 'DEBIAN_FRONTEND=noninteractive' in cmd, 'DEBIAN_FRONTEND not set'
" "${DC_JSON}" && pass "DEBIAN_FRONTEND=noninteractive set for apt" || fail "Missing DEBIAN_FRONTEND=noninteractive"

# --- HISTFILE in remoteEnv ---
echo ""
echo "--- HISTFILE ---"
assert_json_has_key "${DC_JSON}" "remoteEnv.HISTFILE"

# --- Volume mount targets directories (not files) ---
echo ""
echo "--- Volume mount targets ---"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
mounts = d['mounts']
zsh_mount = [m for m in mounts if 'zsh' in m['source']][0]
# Target should be a directory path, not a file path
assert not zsh_mount['target'].endswith('.zsh_history'), \
    f'zsh_history volume targets a file path: {zsh_mount[\"target\"]}'
" "${DC_JSON}" && pass "zsh_history volume targets a directory" || fail "zsh_history volume targets a file (will mount as directory)"

# --- Shell script conventions ---
echo ""
echo "--- Shell script conventions ---"
assert_executable "${REPO_ROOT}/.devcontainer/network/apply-firewall.sh"
assert_contains "${REPO_ROOT}/.devcontainer/network/apply-firewall.sh" "#!/usr/bin/env bash"
assert_contains "${REPO_ROOT}/.devcontainer/network/apply-firewall.sh" "set -euo pipefail"

# --- .gitignore entries ---
echo ""
echo "--- .gitignore entries ---"
assert_contains "${REPO_ROOT}/.gitignore" "workspace/"
assert_contains "${REPO_ROOT}/.gitignore" ".env.vibeshield"
assert_contains "${REPO_ROOT}/.gitignore" ".vibeshield-safety-profile"
assert_contains "${REPO_ROOT}/.gitignore" ".vibeshield-state/"
assert_contains "${REPO_ROOT}/.gitignore" "node_modules/"
assert_contains "${REPO_ROOT}/.gitignore" "config.local.yaml"

# --- Structured log format in apply-firewall.sh ---
echo ""
echo "--- Structured logging ---"
assert_contains "${REPO_ROOT}/.devcontainer/network/apply-firewall.sh" "\[.*\] \[.*\] \[.*\]"

summary
