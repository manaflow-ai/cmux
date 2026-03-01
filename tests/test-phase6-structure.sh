#!/usr/bin/env bash
set -euo pipefail

# Phase 6: Documentation structural tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers/assert.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Phase 6 Structural Tests ==="

# --- LICENSE ---
echo ""
echo "--- LICENSE ---"

assert_file_exists "$REPO_ROOT/LICENSE"
assert_contains "$REPO_ROOT/LICENSE" "Commons Clause"
assert_contains "$REPO_ROOT/LICENSE" "Apache License"
assert_contains "$REPO_ROOT/LICENSE" "Version 2.0"
assert_contains "$REPO_ROOT/LICENSE" "Vibeshield"
assert_contains "$REPO_ROOT/LICENSE" "swannysec"

# --- README.md ---
echo ""
echo "--- README.md ---"

assert_file_exists "$REPO_ROOT/README.md"

# Defense-in-depth diagram (primary element)
assert_contains "$REPO_ROOT/README.md" "Defense-in-Depth"
assert_contains "$REPO_ROOT/README.md" "Layer 5"
assert_contains "$REPO_ROOT/README.md" "Layer 1"
assert_contains "$REPO_ROOT/README.md" "mermaid"
assert_contains "$REPO_ROOT/README.md" "bubblewrap"
assert_contains "$REPO_ROOT/README.md" "iptables"
assert_contains "$REPO_ROOT/README.md" "Enforced By"
assert_contains "$REPO_ROOT/README.md" "Soft"
assert_contains "$REPO_ROOT/README.md" "Hard"

# Quick start
assert_contains "$REPO_ROOT/README.md" "Quick Start"
assert_contains "$REPO_ROOT/README.md" "git clone"
assert_contains "$REPO_ROOT/README.md" "ANTHROPIC_API_KEY"
assert_contains "$REPO_ROOT/README.md" "vibeshield-init"

# Network modes
assert_contains "$REPO_ROOT/README.md" "lockdown"
assert_contains "$REPO_ROOT/README.md" "standard"
assert_contains "$REPO_ROOT/README.md" "open --confirm"

# Permissions
assert_contains "$REPO_ROOT/README.md" "50 allow"
assert_contains "$REPO_ROOT/README.md" "19 ask"
assert_contains "$REPO_ROOT/README.md" "119 deny"
assert_contains "$REPO_ROOT/README.md" "skip-permissions"

# Secrets
assert_contains "$REPO_ROOT/README.md" "1Password"
assert_contains "$REPO_ROOT/README.md" "fine-grained"

# Hardening for Production
assert_contains "$REPO_ROOT/README.md" "Hardening for Production"
assert_contains "$REPO_ROOT/README.md" "sha256"

# Acknowledgments / Credits
assert_contains "$REPO_ROOT/README.md" "Acknowledgments"
assert_contains "$REPO_ROOT/README.md" "Anthropic"
assert_contains "$REPO_ROOT/README.md" "Vercel"
assert_contains "$REPO_ROOT/README.md" "Cisco"
assert_contains "$REPO_ROOT/README.md" "Microsoft"

# Threat model link + key statement
assert_contains "$REPO_ROOT/README.md" "threat-model.md"
assert_contains "$REPO_ROOT/README.md" "blast radius"

# License reference
assert_contains "$REPO_ROOT/README.md" "Apache 2.0"
assert_contains "$REPO_ROOT/README.md" "Commons Clause"

# Host Config Transfer section
assert_contains "$REPO_ROOT/README.md" "Host Config Transfer"
assert_contains "$REPO_ROOT/README.md" "Path Rewriting"

# --- docs/threat-model.md ---
echo ""
echo "--- docs/threat-model.md ---"

assert_file_exists "$REPO_ROOT/docs/threat-model.md"
assert_contains "$REPO_ROOT/docs/threat-model.md" "Trust Boundaries"
assert_contains "$REPO_ROOT/docs/threat-model.md" "Hard Boundaries"
assert_contains "$REPO_ROOT/docs/threat-model.md" "Soft Guardrails"
assert_contains "$REPO_ROOT/docs/threat-model.md" "blast radius"
assert_contains "$REPO_ROOT/docs/threat-model.md" "does not make it safe"
assert_contains "$REPO_ROOT/docs/threat-model.md" "socat"
assert_contains "$REPO_ROOT/docs/threat-model.md" "seccomp"
assert_contains "$REPO_ROOT/docs/threat-model.md" "AppArmor"
assert_contains "$REPO_ROOT/docs/threat-model.md" "volume"
assert_contains "$REPO_ROOT/docs/threat-model.md" "upgradePackages"
assert_contains "$REPO_ROOT/docs/threat-model.md" "Bootstrap Attack Surface"
assert_contains "$REPO_ROOT/docs/threat-model.md" "exfiltration"
assert_contains "$REPO_ROOT/docs/threat-model.md" "api.github.com"
assert_contains "$REPO_ROOT/docs/threat-model.md" "Zero exfiltration"
assert_contains "$REPO_ROOT/docs/threat-model.md" "linter"

# --- docs/future-enhancements.md ---
echo ""
echo "--- docs/future-enhancements.md ---"

assert_file_exists "$REPO_ROOT/docs/future-enhancements.md"
assert_contains "$REPO_ROOT/docs/future-enhancements.md" "CONTRIBUTING"
assert_contains "$REPO_ROOT/docs/future-enhancements.md" "Actions"
assert_contains "$REPO_ROOT/docs/future-enhancements.md" "seccomp"

# --- docs/recipes/ ---
echo ""
echo "--- docs/recipes/ ---"

assert_file_exists "$REPO_ROOT/docs/recipes/agent-browser.md"
assert_file_exists "$REPO_ROOT/docs/recipes/playwright-headless.md"
assert_file_exists "$REPO_ROOT/docs/recipes/playwright-desktop.md"
assert_file_exists "$REPO_ROOT/docs/recipes/language-tooling.md"

assert_contains "$REPO_ROOT/docs/recipes/agent-browser.md" "Vercel"
assert_contains "$REPO_ROOT/docs/recipes/agent-browser.md" "config.local.yaml"
assert_contains "$REPO_ROOT/docs/recipes/playwright-headless.md" "chromium"
assert_contains "$REPO_ROOT/docs/recipes/playwright-desktop.md" "desktop-lite"
assert_contains "$REPO_ROOT/docs/recipes/playwright-desktop.md" "6080"
assert_contains "$REPO_ROOT/docs/recipes/language-tooling.md" "Python"
assert_contains "$REPO_ROOT/docs/recipes/language-tooling.md" "Rust"
assert_contains "$REPO_ROOT/docs/recipes/language-tooling.md" "Go"

# --- Summary ---
echo ""
summary
