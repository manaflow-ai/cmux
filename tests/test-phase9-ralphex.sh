#!/usr/bin/env bash
# Phase 9: ralphex Integration — structural tests (no Docker required)
#
# These tests verify that the vibeshield launcher contains the expected
# ralphex constants, argument handling, config sync, and skill deployment
# code. They use grep/pattern matching against the source files.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/tests/helpers/assert.sh"

VIBESHIELD="${REPO_ROOT}/vibeshield"
DC_JSON="${REPO_ROOT}/.devcontainer/devcontainer.json"
SKILL_MD="${REPO_ROOT}/docs/optional/ralphex-init/SKILL.md"

echo "=== Phase 9: ralphex Integration ==="

# --- devcontainer.json ---
echo ""
echo "--- devcontainer.json ---"
assert_contains "$DC_JSON" "ralphex"

# --- Launcher flag ---
echo ""
echo "--- Launcher flag ---"
assert_contains "$VIBESHIELD" "\-\-ralphex"

# --- Argument passthrough ---
echo ""
echo "--- Argument passthrough ---"
assert_contains "$VIBESHIELD" "RALPHEX_ARGS"

# --- Action handling ---
echo ""
echo "--- Action handling ---"
assert_contains "$VIBESHIELD" '"ralphex"'

# --- Config sync ---
echo ""
echo "--- Config sync ---"
assert_contains "$VIBESHIELD" "HOST_RALPHEX_DIR"

# --- Skill file ---
echo ""
echo "--- Skill file ---"
assert_file_exists "$SKILL_MD"

# --- Skill frontmatter ---
echo ""
echo "--- Skill frontmatter ---"
assert_contains "$SKILL_MD" "ralphex-init"

# --- Conditional skill deployment ---
echo ""
echo "--- Conditional skill deployment ---"
assert_contains "$VIBESHIELD" "RALPHEX_SKILL_SRC"

# --- Container ralphex check fallback ---
echo ""
echo "--- Container ralphex check fallback ---"
assert_contains "$VIBESHIELD" "docker exec.*command -v ralphex"

# --- codex install in devcontainer.json ---
echo ""
echo "--- codex install ---"
assert_contains "$DC_JSON" "codex"

# --- OpenRouter integration ---
echo ""
echo "--- OpenRouter integration ---"
assert_contains "$VIBESHIELD" "OPENROUTER_API_KEY"
assert_contains "$VIBESHIELD" "openrouter-key"
assert_contains "$VIBESHIELD" "openrouter.ai"

# --- COPYFILE_DISABLE on tar ---
echo ""
echo "--- COPYFILE_DISABLE ---"
assert_contains "$VIBESHIELD" "COPYFILE_DISABLE=1"

# --- Codex config sync ---
echo ""
echo "--- Codex config sync ---"
assert_contains "$VIBESHIELD" "HOST_CODEX_DIR"
assert_contains "$VIBESHIELD" "config.toml"

# --- No appPort (removed to prevent conflicts) ---
echo ""
echo "--- No fixed appPort ---"
assert_not_contains "$DC_JSON" "appPort"

# --- Summary ---
summary
