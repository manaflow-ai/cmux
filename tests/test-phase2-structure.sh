#!/usr/bin/env bash
# Phase 2 Structural Tests — no Docker required
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/tests/helpers/assert.sh"

echo "=== Phase 2: Structural Validation ==="

# --- File existence ---
echo ""
echo "--- File existence ---"
assert_file_exists "${REPO_ROOT}/.devcontainer/network/config.defaults.yaml"
assert_file_exists "${REPO_ROOT}/.devcontainer/network/config.local.yaml.example"
assert_file_exists "${REPO_ROOT}/.devcontainer/network/firewall.py"
assert_file_exists "${REPO_ROOT}/.devcontainer/network/refresh-dns.sh"
assert_file_exists "${REPO_ROOT}/.devcontainer/network/apply-firewall.sh"
assert_file_exists "${REPO_ROOT}/.devcontainer/network/reload-firewall.sh"
assert_file_exists "${REPO_ROOT}/.devcontainer/network/health-check.sh"
assert_file_exists "${REPO_ROOT}/.devcontainer/sync-permissions.py"
assert_file_exists "${REPO_ROOT}/.devcontainer/emergency-open.sh"
assert_file_exists "${REPO_ROOT}/.devcontainer/vibeshield-sudoers"
assert_dir_exists "${REPO_ROOT}/.devcontainer/network/profiles"

# --- YAML validity ---
echo ""
echo "--- YAML validity ---"
python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
assert isinstance(data, dict), 'YAML did not produce a dict'
" "${REPO_ROOT}/.devcontainer/network/config.defaults.yaml" && pass "config.defaults.yaml is valid YAML" || fail "config.defaults.yaml is invalid YAML"

# --- Config structure ---
echo ""
echo "--- Config structure ---"
python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
assert 'version' in cfg, 'Missing version key'
assert cfg['version'] == 1, f'Unexpected version: {cfg[\"version\"]}'
assert 'dns' in cfg, 'Missing dns section'
assert 'modes' in cfg, 'Missing modes section'
assert 'global_allow' in cfg, 'Missing global_allow'
assert 'global_deny' in cfg, 'Missing global_deny'
modes = cfg['modes']
assert 'lockdown' in modes, 'Missing lockdown mode'
assert 'standard' in modes, 'Missing standard mode'
assert 'open' in modes, 'Missing open mode'
assert modes['standard'].get('inherit') == 'lockdown', 'Standard should inherit lockdown'
assert modes['open'].get('unrestricted') is True, 'Open mode should be unrestricted'
" "${REPO_ROOT}/.devcontainer/network/config.defaults.yaml" && pass "Config structure valid" || fail "Config structure invalid"

# --- DNS restricted to system resolver only ---
echo ""
echo "--- DNS anti-tunneling ---"
python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
assert cfg['dns']['resolver'] in ('auto', '127.0.0.11'), 'DNS resolver should be auto or Docker DNS'
# Check global_allow has DNS resolver entries
dns_allows = [r for r in cfg['global_allow'] if r.get('port') == 53]
assert len(dns_allows) >= 2, 'Should have UDP+TCP DNS allow rules'
# Check global_deny blocks other DNS
dns_denies = [r for r in cfg['global_deny'] if r.get('port') == 53]
assert len(dns_denies) >= 1, 'Should deny non-system DNS'
" "${REPO_ROOT}/.devcontainer/network/config.defaults.yaml" && pass "DNS restricted to system resolver" || fail "DNS restriction misconfigured"

# --- No wildcard domains ---
echo ""
echo "--- No wildcard domains ---"
python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
for mode_name, mode_def in cfg['modes'].items():
    for domain in mode_def.get('domains', []):
        assert not domain.startswith('*'), f'Wildcard domain in {mode_name}: {domain}'
" "${REPO_ROOT}/.devcontainer/network/config.defaults.yaml" && pass "No wildcard domains in any mode" || fail "Wildcard domain found"

# --- No duplicate domains ---
echo ""
echo "--- No duplicate domains ---"
python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
for mode_name, mode_def in cfg['modes'].items():
    domains = mode_def.get('domains', [])
    if len(domains) != len(set(domains)):
        dupes = [d for d in domains if domains.count(d) > 1]
        assert False, f'Duplicate domains in {mode_name}: {set(dupes)}'
" "${REPO_ROOT}/.devcontainer/network/config.defaults.yaml" && pass "No duplicate domains per mode" || fail "Duplicate domains found"

# --- Python syntax valid ---
echo ""
echo "--- Python syntax ---"
python3 -c "import ast; ast.parse(open('${REPO_ROOT}/.devcontainer/network/firewall.py').read())" && pass "firewall.py valid Python" || fail "firewall.py invalid Python"
python3 -c "import ast; ast.parse(open('${REPO_ROOT}/.devcontainer/sync-permissions.py').read())" && pass "sync-permissions.py valid Python" || fail "sync-permissions.py invalid Python"

# --- Shell script conventions ---
echo ""
echo "--- Shell script conventions ---"
for script in \
  ".devcontainer/network/apply-firewall.sh" \
  ".devcontainer/network/reload-firewall.sh" \
  ".devcontainer/network/refresh-dns.sh" \
  ".devcontainer/network/health-check.sh" \
  ".devcontainer/emergency-open.sh"; do
  assert_executable "${REPO_ROOT}/${script}"
  assert_contains "${REPO_ROOT}/${script}" "#!/usr/bin/env bash"
  assert_contains "${REPO_ROOT}/${script}" "set -euo pipefail"
done

# --- Structured logging in apply-firewall.sh ---
echo ""
echo "--- Structured logging ---"
assert_contains "${REPO_ROOT}/.devcontainer/network/apply-firewall.sh" "\[.*\] \[.*\] \[.*\]"

# --- Firewall.py has required classes ---
echo ""
echo "--- firewall.py classes ---"
assert_contains "${REPO_ROOT}/.devcontainer/network/firewall.py" "class ConfigLoader"
assert_contains "${REPO_ROOT}/.devcontainer/network/firewall.py" "class DNSResolver"
assert_contains "${REPO_ROOT}/.devcontainer/network/firewall.py" "class RuleBuilder"
assert_contains "${REPO_ROOT}/.devcontainer/network/firewall.py" "class FirewallEngine"

# --- Firewall.py uses iptables-restore (atomic) ---
echo ""
echo "--- Atomic iptables ---"
assert_contains "${REPO_ROOT}/.devcontainer/network/firewall.py" "iptables-restore"

# --- Firewall.py blocks non-Docker DNS ---
echo ""
echo "--- firewall.py DNS blocking ---"
assert_contains "${REPO_ROOT}/.devcontainer/network/firewall.py" "Block external DNS"

# --- reload-firewall.sh has all subcommands ---
echo ""
echo "--- reload-firewall.sh subcommands ---"
assert_contains "${REPO_ROOT}/.devcontainer/network/reload-firewall.sh" "\-\-mode"
assert_contains "${REPO_ROOT}/.devcontainer/network/reload-firewall.sh" "\-\-status"
assert_contains "${REPO_ROOT}/.devcontainer/network/reload-firewall.sh" "\-\-rollback"
assert_contains "${REPO_ROOT}/.devcontainer/network/reload-firewall.sh" "\-\-verify"
assert_contains "${REPO_ROOT}/.devcontainer/network/reload-firewall.sh" "\-\-confirm"

# --- Open mode requires --confirm ---
echo ""
echo "--- Open mode confirmation ---"
assert_contains "${REPO_ROOT}/.devcontainer/network/reload-firewall.sh" "open.*confirm"

# --- sync-permissions.py manages nested permissions ---
echo ""
echo "--- sync-permissions.py structure ---"
assert_contains "${REPO_ROOT}/.devcontainer/sync-permissions.py" "permissions"
assert_contains "${REPO_ROOT}/.devcontainer/sync-permissions.py" "vibeshield_managed"
assert_contains "${REPO_ROOT}/.devcontainer/sync-permissions.py" "atomic_write"
assert_contains "${REPO_ROOT}/.devcontainer/sync-permissions.py" "\-\-dry-run"

# --- emergency-open.sh flushes all rules ---
echo ""
echo "--- emergency-open.sh ---"
assert_contains "${REPO_ROOT}/.devcontainer/emergency-open.sh" "iptables -F"
assert_contains "${REPO_ROOT}/.devcontainer/emergency-open.sh" "iptables -P OUTPUT ACCEPT"

# --- Sudoers file ---
echo ""
echo "--- sudoers file ---"
assert_contains "${REPO_ROOT}/.devcontainer/vibeshield-sudoers" "vscode"
assert_contains "${REPO_ROOT}/.devcontainer/vibeshield-sudoers" "NOPASSWD"
assert_contains "${REPO_ROOT}/.devcontainer/vibeshield-sudoers" 'apply-firewall ""'
# Only apply-firewall should be in sudoers — no wildcards, no other scripts
assert_not_contains "${REPO_ROOT}/.devcontainer/vibeshield-sudoers" "reload-firewall"
assert_not_contains "${REPO_ROOT}/.devcontainer/vibeshield-sudoers" "emergency-open"
assert_not_contains "${REPO_ROOT}/.devcontainer/vibeshield-sudoers" "sync-permissions"
# Package manager sudo entries intentionally removed (security fix — install
# scripts run as root and could flush iptables or modify sudoers)
assert_not_contains "${REPO_ROOT}/.devcontainer/vibeshield-sudoers" "apt-get"

# --- Sudoers security: no raw iptables sudo access ---
echo ""
echo "--- sudoers no raw iptables ---"
if grep -E "NOPASSWD:.*/iptables$|NOPASSWD:.*/iptables-restore$|NOPASSWD:.*/ipset$" "${REPO_ROOT}/.devcontainer/vibeshield-sudoers" >/dev/null 2>&1; then
  fail "Direct iptables/ipset sudo access found in sudoers"
else
  pass "No direct iptables/ipset sudo access in sudoers"
fi

# --- Domain ipset support ---
echo ""
echo "--- Domain ipset support ---"
assert_contains "${REPO_ROOT}/.devcontainer/network/firewall.py" "vibeshield_domains"
assert_contains "${REPO_ROOT}/.devcontainer/network/firewall.py" "_setup_domain_ipset"
assert_contains "${REPO_ROOT}/.devcontainer/network/firewall.py" "ipset.*swap"
assert_contains "${REPO_ROOT}/.devcontainer/network/firewall.py" "AUDIT domain="
assert_contains "${REPO_ROOT}/.devcontainer/network/firewall.py" "is_private.*is_loopback"

# --- dnsmasq DNS allowlist proxy ---
echo ""
echo "--- dnsmasq DNS allowlist proxy ---"
assert_contains "${REPO_ROOT}/.devcontainer/network/firewall.py" "_generate_dnsmasq_config"
assert_contains "${REPO_ROOT}/.devcontainer/network/firewall.py" "no-resolv"
assert_contains "${REPO_ROOT}/.devcontainer/network/firewall.py" "uid-owner"
assert_contains "${REPO_ROOT}/.devcontainer/network/firewall.py" 'address=/#/'

# --- dnsmasq in devcontainer deps ---
echo ""
echo "--- dnsmasq in devcontainer deps ---"
assert_contains "${REPO_ROOT}/.devcontainer/devcontainer.json" "dnsmasq"

# --- DNS refresh interval ≤ 300 ---
echo ""
echo "--- DNS refresh interval ---"
python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
interval = cfg['dns']['refresh_interval']
assert interval <= 300, f'DNS refresh interval {interval}s > 300s (5 min)'
" "${REPO_ROOT}/.devcontainer/network/config.defaults.yaml" && pass "DNS refresh interval ≤ 300s" || fail "DNS refresh interval too high"

# --- devcontainer.json has new entries ---
echo ""
echo "--- devcontainer.json Phase 2 entries ---"
DC_JSON="${REPO_ROOT}/.devcontainer/devcontainer.json"
assert_json_valid "${DC_JSON}"
assert_json_has_key "${DC_JSON}" "onCreateCommand.setup"

# --- Setuid bit stripping ---
echo ""
echo "--- Setuid bit stripping ---"
assert_contains "${REPO_ROOT}/.devcontainer/devcontainer.json" "chmod u-s"
assert_contains "${REPO_ROOT}/.devcontainer/devcontainer.json" "! -path /usr/bin/sudo"

# --- Shared health check script ---
echo ""
echo "--- Shared health check ---"
HEALTH_CHECK="${REPO_ROOT}/.devcontainer/network/health-check.sh"
assert_contains "${HEALTH_CHECK}" "Layer 2"
assert_contains "${HEALTH_CHECK}" "bwrap intentionally omitted"
assert_contains "${HEALTH_CHECK}" "sudoers.*self-heal"
assert_contains "${HEALTH_CHECK}" "sudoers lockdown compromised"
assert_contains "${HEALTH_CHECK}" "CapAmb"

# --- Open-mode safety guards ---
echo ""
echo "--- Open-mode safety guards ---"
assert_contains "${REPO_ROOT}/.devcontainer/network/apply-firewall.sh" "Open mode blocked by safety"
assert_contains "${REPO_ROOT}/.devcontainer/network/refresh-dns.sh" "Self-heal refusing mode"

# --- Health check integration ---
echo ""
echo "--- Health check integration ---"
assert_contains "${REPO_ROOT}/.devcontainer/network/apply-firewall.sh" "health-check.sh"
assert_contains "${REPO_ROOT}/.devcontainer/network/reload-firewall.sh" "health-check.sh"

summary
