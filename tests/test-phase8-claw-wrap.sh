#!/usr/bin/env bash
# Phase 8: claw-wrap Secrets Proxy — structural tests (no Docker required)
#
# These tests verify that the vibeshield launcher contains the expected
# claw-wrap constants, function definitions, config generation patterns,
# and in-container daemon management code. They use grep/pattern matching
# against the source files — no claw-wrap binary or Docker container needed.
#
# Architecture: In-container daemon model (ADR-012). Daemon runs inside the
# container. Credentials resolved on host (Mitigation B). No socat relay,
# no host.docker.internal, no host-side PID management.
#
# --- Manual Integration Tests (not automatable in structural tests) ---
# 1. Fresh ./vibeshield with claw-wrap installed + 1Password → mode op-proxy activates
# 2. gh repo list works through symlink chain
# 3. git push works through symlink chain
# 4. Claude Code starts with dummy API key, API calls proxied
# 5. printenv ANTHROPIC_API_KEY shows dummy value
# 6. printenv GITHUB_TOKEN shows empty/unset
# 7. vibeshield --status shows proxy health (in-container checks)
# 8. Kill container and relaunch → daemon re-created by launcher
# 9. Remove claw-wrap from PATH → mode env-direct fallback works
# 10. Verify: no host.docker.internal references in launched env
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/tests/helpers/assert.sh"

VIBESHIELD="${REPO_ROOT}/vibeshield"
CONTAINER_SETTINGS="${REPO_ROOT}/.claude/settings.container.json"
DC_JSON="${REPO_ROOT}/.devcontainer/devcontainer.json"
CLAUDE_MD="${REPO_ROOT}/.claude/CLAUDE.md"
SKILL_MD="${REPO_ROOT}/.claude/skills/vibeshield-init/SKILL.md"

echo "=== Phase 8: claw-wrap Secrets Proxy ==="

# --- Checksum file ---
echo ""
echo "--- Checksum file ---"
assert_file_exists "${REPO_ROOT}/.devcontainer/claw-wrap-checksums.sha256"
# 4 platform entries
CHECKSUM_LINES=$(grep -c '^[A-Za-z0-9]' "${REPO_ROOT}/.devcontainer/claw-wrap-checksums.sha256")
[[ "$CHECKSUM_LINES" -eq 4 ]] && pass "Checksum entries: $CHECKSUM_LINES" || fail "Expected 4 checksum entries, got $CHECKSUM_LINES"

# --- Launcher constants ---
echo ""
echo "--- Launcher constants ---"
assert_contains "$VIBESHIELD" 'CLAW_WRAP_VERSION='
assert_contains "$VIBESHIELD" 'PROXY_DUMMY_KEY='
assert_contains "$VIBESHIELD" 'proxy-managed-credential'

# Verify dummy key is exactly 107 chars
DUMMY_KEY=$(grep 'PROXY_DUMMY_KEY=' "$VIBESHIELD" | head -1 | sed 's/.*PROXY_DUMMY_KEY="//' | sed 's/"//')
KEY_LEN=${#DUMMY_KEY}
[[ "$KEY_LEN" -eq 107 ]] && pass "Dummy API key length: $KEY_LEN" || fail "Expected dummy key length 107, got $KEY_LEN"
[[ "$DUMMY_KEY" == sk-ant-api03-* ]] && pass "Dummy key has sk-ant-api03- prefix" || fail "Dummy key missing sk-ant-api03- prefix"

# --- Launcher functions ---
echo ""
echo "--- Launcher functions ---"
assert_contains "$VIBESHIELD" 'detect_secrets_mode'
assert_contains "$VIBESHIELD" 'ensure_claw_wrap'
assert_contains "$VIBESHIELD" 'SECRETS_MODE'
assert_contains "$VIBESHIELD" 'claw_wrap_resolve_credentials'
assert_contains "$VIBESHIELD" 'claw_wrap_config_generate_in_container'

# --- Config generation (in-container) ---
echo ""
echo "--- Config generation (in-container) ---"
assert_contains "$VIBESHIELD" 'claw_wrap_config_generate_in_container'
assert_contains "$VIBESHIELD" 'credential_cache_ttl'
assert_contains "$VIBESHIELD" 'replay_cache_ttl'
assert_contains "$VIBESHIELD" 'repo.*delete'
assert_contains "$VIBESHIELD" 'Direct API calls are blocked'

# --- In-container daemon ---
echo ""
echo "--- In-container daemon ---"
assert_contains "$VIBESHIELD" 'docker exec -u.*DAEMON_USER.*-d'
assert_contains "$VIBESHIELD" 'exec claw-wrap daemon'
assert_contains "$VIBESHIELD" '/run/openclaw/config.yaml'
assert_contains "$VIBESHIELD" 'mkdir -p /run/openclaw'
assert_contains "$VIBESHIELD" '/var/log/vibeshield/claw-wrap.log'

# --- Non-root daemon user (SA15) ---
echo ""
echo "--- Non-root daemon user ---"
assert_contains "$VIBESHIELD" 'useradd.*claw-wrap'
assert_contains "$VIBESHIELD" 'usermod.*claw-wrap.*vscode'
assert_contains "$DC_JSON" 'claw-wrap'
assert_contains "$VIBESHIELD" 'chown ${DAEMON_USER}:${DAEMON_USER}'
assert_contains "$VIBESHIELD" 'chmod 0751'

# --- No host-side daemon (ADR-012 removed these) ---
echo ""
echo "--- No host-side daemon (ADR-012) ---"
assert_not_contains "$VIBESHIELD" 'claw_wrap_daemon_start'
assert_not_contains "$VIBESHIELD" 'claw_wrap_daemon_stop'
assert_not_contains "$VIBESHIELD" 'daemon.pid'
assert_not_contains "$VIBESHIELD" 'trap.*claw_wrap_daemon_stop'

# --- No host.docker.internal (ADR-012 removed) ---
echo ""
echo "--- No host.docker.internal ---"
assert_not_contains "$VIBESHIELD" 'host.docker.internal'

# --- devcontainer.json ---
echo ""
echo "--- devcontainer.json ---"
# /run/openclaw bind mount REMOVED (in-container daemon creates it)
assert_not_contains "$DC_JSON" 'openclaw'
assert_not_contains "$DC_JSON" '/run/openclaw'
# OP_SERVICE_ACCOUNT_TOKEN REMOVED from remoteEnv
assert_not_contains "$DC_JSON" 'OP_SERVICE_ACCOUNT_TOKEN'
# ANTHROPIC_API_KEY and GITHUB_TOKEN still present (env-direct fallback)
assert_contains "$DC_JSON" 'ANTHROPIC_API_KEY'
assert_contains "$DC_JSON" 'GITHUB_TOKEN'

# --- HTTPS_PROXY is localhost (in-container daemon) ---
echo ""
echo "--- HTTPS_PROXY localhost ---"
assert_contains "$VIBESHIELD" '127.0.0.1:18080'

# --- Container setup function ---
echo ""
echo "--- Container setup function ---"
assert_contains "$VIBESHIELD" 'claw_wrap_container_setup'
assert_contains "$VIBESHIELD" '/usr/local/bin/claw-wrap'
assert_contains "$VIBESHIELD" 'update-ca-certificates'
assert_contains "$VIBESHIELD" 'git-askpass-claw'
# Stale bind mount detection
assert_contains "$VIBESHIELD" 'mountpoint -q /run/openclaw'

# --- Security deny rules ---
echo ""
echo "--- Security deny rules ---"
assert_contains "$CONTAINER_SETTINGS" 'Bash(/usr/bin/gh'
assert_contains "$CONTAINER_SETTINGS" 'Bash(/usr/bin/git'
assert_contains "$CONTAINER_SETTINGS" 'Read(//run/openclaw/auth'
assert_contains "$CONTAINER_SETTINGS" 'Read(//run/openclaw/config'
assert_contains "$CONTAINER_SETTINGS" 'Read(//run/openclaw/env'
assert_contains "$CONTAINER_SETTINGS" 'Read(//run/openclaw/proxy-auth-token'
assert_contains "$CONTAINER_SETTINGS" 'Read(//var/log/vibeshield'
assert_contains "$CONTAINER_SETTINGS" 'Read(//etc/openclaw'
assert_contains "$CONTAINER_SETTINGS" 'Bash(cat /run/openclaw'
assert_contains "$CONTAINER_SETTINGS" 'Bash(printenv HTTPS_PROXY'
assert_contains "$CONTAINER_SETTINGS" 'kill.*claw'
assert_contains "$CONTAINER_SETTINGS" 'pkill.*claw'
assert_contains "$CONTAINER_SETTINGS" 'killall.*claw'
assert_contains "$CONTAINER_SETTINGS" 'kill.*socat'
assert_contains "$CONTAINER_SETTINGS" 'pkill.*socat'
# Git wrapper deny rules (argument filtering + binary access control)
assert_contains "$CONTAINER_SETTINGS" 'Bash(get-github-token'
assert_contains "$CONTAINER_SETTINGS" 'Bash(claw-wrap'
assert_contains "$CONTAINER_SETTINGS" 'Bash(git credential'
assert_contains "$CONTAINER_SETTINGS" 'Bash(git config.\+credential'
assert_contains "$CONTAINER_SETTINGS" 'Bash(git config core.askPass'
assert_contains "$CONTAINER_SETTINGS" 'Bash(git config http.proxy'
assert_contains "$CONTAINER_SETTINGS" 'Bash(git -c '

# --- Git wrapper architecture ---
echo ""
echo "--- Git wrapper architecture ---"
# git wrapper (not symlink to claw-wrap) with setgid
assert_contains "$VIBESHIELD" 'cat > /usr/local/bin/git'
assert_contains "$VIBESHIELD" 'chmod 755 /usr/local/bin/git'
assert_contains "$VIBESHIELD" 'get-github-token'
# askpass uses get-github-token (not echo $GH_TOKEN)
assert_contains "$VIBESHIELD" 'exec /usr/local/bin/get-github-token'
# GIT_ASKPASS in ENV_FLAGS
assert_contains "$VIBESHIELD" 'GIT_ASKPASS=/opt/vibeshield/bin/git-askpass-claw'
assert_contains "$VIBESHIELD" 'GIT_TERMINAL_PROMPT=0'

# --- Sandbox proxy port ---
echo ""
echo "--- Sandbox proxy port ---"
python3 -I -c "
import json, sys
d = json.load(open(sys.argv[1]))
port = d.get('sandbox', {}).get('network', {}).get('httpProxyPort')
assert port == 18080, f'Expected httpProxyPort 18080, got {port}'
print('httpProxyPort: 18080')
" "$CONTAINER_SETTINGS" && pass "Sandbox httpProxyPort configured" || fail "Sandbox httpProxyPort not configured"

# --- Skill update ---
echo ""
echo "--- Skill update ---"
assert_contains "$SKILL_MD" 'Proxy'
assert_contains "$SKILL_MD" '1Password'

# --- Integration ---
echo ""
echo "--- Integration ---"
assert_contains "$VIBESHIELD" 'SECRETS_MODE'
assert_contains "$VIBESHIELD" 'env-direct'
assert_contains "$VIBESHIELD" 'op-proxy'
assert_contains "$VIBESHIELD" 'env-proxy'
assert_contains "$VIBESHIELD" 'claw_wrap_container_setup'

# --- Status (in-container checks) ---
echo ""
echo "--- Status ---"
assert_contains "$VIBESHIELD" 'Proxy:'
assert_contains "$VIBESHIELD" 'secrets.sock'
assert_contains "$VIBESHIELD" 'pgrep.*claw-wrap'

# --- Proxy prompt and credential resolution ---
echo ""
echo "--- Proxy prompt and credential resolution ---"
assert_contains "$VIBESHIELD" 'Continue without proxy'
assert_contains "$VIBESHIELD" 'OP_SERVICE_ACCOUNT_TOKEN.*OP_VIBESHIELD'
assert_contains "$VIBESHIELD" '\-\-socket.*secrets.sock'
# VS_CRED_* cleanup after container setup
assert_contains "$VIBESHIELD" 'compgen -v VS_CRED_'

# --- Summary ---
summary
