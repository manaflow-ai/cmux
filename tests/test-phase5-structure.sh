#!/usr/bin/env bash
# Phase 5 Structural Tests — no Docker required
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/tests/helpers/assert.sh"

echo "=== Phase 5: Structural Validation ==="

SKILLS_DIR="${REPO_ROOT}/.claude/skills"
SKILL_DIR="${SKILLS_DIR}/vibeshield-init"
SKILL_FILE="${SKILL_DIR}/SKILL.md"
TEMPLATE_FILE="${SKILL_DIR}/safety-profile-template.md"
GITIGNORE="${REPO_ROOT}/.gitignore"

# --- File existence ---
echo ""
echo "--- File existence ---"
assert_dir_exists "${SKILLS_DIR}"
assert_dir_exists "${SKILL_DIR}"
assert_file_exists "${SKILL_FILE}"
assert_file_exists "${TEMPLATE_FILE}"

# --- YAML frontmatter ---
echo ""
echo "--- YAML frontmatter ---"
if head -1 "${SKILL_FILE}" | grep -q "^---$"; then
  pass "SKILL.md starts with YAML frontmatter delimiter"
else
  fail "SKILL.md missing YAML frontmatter opening ---"
fi

if sed -n '2,10p' "${SKILL_FILE}" | grep -q "^name:"; then
  pass "SKILL.md has name field in frontmatter"
else
  fail "SKILL.md missing name field in frontmatter"
fi

if sed -n '2,10p' "${SKILL_FILE}" | grep -q "^description:"; then
  pass "SKILL.md has description field in frontmatter"
else
  fail "SKILL.md missing description field in frontmatter"
fi

# Check name matches directory
SKILL_NAME=$(sed -n 's/^name: *//p' "${SKILL_FILE}" | head -1)
if [[ "${SKILL_NAME}" == "vibeshield-init" ]]; then
  pass "Skill name matches directory name: ${SKILL_NAME}"
else
  fail "Skill name '${SKILL_NAME}' does not match directory name 'vibeshield-init'"
fi

# --- Skill file is non-empty and reasonable size ---
echo ""
echo "--- Skill file size ---"
LINE_COUNT=$(wc -l < "${SKILL_FILE}")
if [[ ${LINE_COUNT} -gt 10 ]]; then
  pass "SKILL.md has substantial content (${LINE_COUNT} lines)"
else
  fail "SKILL.md too short (${LINE_COUNT} lines)"
fi

if [[ ${LINE_COUNT} -lt 500 ]]; then
  pass "SKILL.md under 500-line limit (${LINE_COUNT} lines)"
else
  fail "SKILL.md exceeds 500-line limit (${LINE_COUNT} lines)"
fi

# --- Markdown headings ---
echo ""
echo "--- Markdown structure ---"
if grep -q "^#" "${SKILL_FILE}"; then
  pass "SKILL.md contains markdown headings"
else
  fail "SKILL.md missing markdown headings"
fi

# No XML tags (skill best practice)
if grep -qE "<[a-zA-Z]+>" "${SKILL_FILE}" 2>/dev/null; then
  # Allow markdown angle brackets in examples (like <email>, <date>, <mode>)
  # Only fail on actual XML-like tags with closing tags
  if grep -qE "</[a-zA-Z]+>" "${SKILL_FILE}" 2>/dev/null; then
    fail "SKILL.md contains XML tags (use markdown headings instead)"
  else
    pass "SKILL.md uses markdown headings (no XML tags)"
  fi
else
  pass "SKILL.md uses markdown headings (no XML tags)"
fi

# --- Required sections ---
echo ""
echo "--- Required sections ---"
assert_contains "${SKILL_FILE}" "Environment Inspection"
assert_contains "${SKILL_FILE}" "Migration Checklist"
assert_contains "${SKILL_FILE}" "Safety Warnings"
assert_contains "${SKILL_FILE}" "Safety Profile"
assert_contains "${SKILL_FILE}" "Apply Configuration"
assert_contains "${SKILL_FILE}" "Summary"
assert_contains "${SKILL_FILE}" "Guidelines"

# --- Security rules ---
echo ""
echo "--- Security rules ---"
assert_contains "${SKILL_FILE}" "NEVER copy raw content"
assert_contains "${SKILL_FILE}" "credential"
assert_contains "${SKILL_FILE}" "user confirmation"

# --- Tiered warnings ---
echo ""
echo "--- Tiered safety warnings ---"
assert_contains "${SKILL_FILE}" "Tier 1"
assert_contains "${SKILL_FILE}" "Tier 2"
assert_contains "${SKILL_FILE}" "Tier 3"
assert_contains "${SKILL_FILE}" "I understand the risks"

# --- Network modes referenced ---
echo ""
echo "--- Network mode coverage ---"
assert_contains "${SKILL_FILE}" "lockdown"
assert_contains "${SKILL_FILE}" "standard"
assert_contains "${SKILL_FILE}" "open"

# --- Integration points ---
echo ""
echo "--- Integration with existing components ---"
assert_contains "${SKILL_FILE}" "settings.json"
assert_contains "${SKILL_FILE}" "devcontainer.json"
assert_contains "${SKILL_FILE}" "vibeshield/state/current-mode"
assert_contains "${SKILL_FILE}" "config.local.yaml"
assert_contains "${SKILL_FILE}" "vibeshield-safety-profile"
assert_contains "${SKILL_FILE}" "reload-firewall"

# --- Secrets safety ---
echo ""
echo "--- Secrets safety ---"
if grep -q "NEVER ask for" "${SKILL_FILE}" && grep -q "NEVER.*values" "${SKILL_FILE}"; then
  pass "File contains secrets safety: NEVER ask for values"
else
  fail "File missing secrets safety rules in ${SKILL_FILE}"
fi
assert_contains "${SKILL_FILE}" "NEVER remove anything from.*deny"
assert_contains "${SKILL_FILE}" "NEVER modify the.*sandbox"

# --- Safety profile gitignored ---
echo ""
echo "--- Gitignore ---"
assert_contains "${GITIGNORE}" ".vibeshield-safety-profile"

# --- Inspection targets ---
echo ""
echo "--- Inspection targets ---"
assert_contains "${SKILL_FILE}" "gitconfig"
assert_contains "${SKILL_FILE}" "zshrc"
assert_contains "${SKILL_FILE}" "plugins"

# --- Summary section has next steps ---
echo ""
echo "--- Onboarding summary ---"
assert_contains "${SKILL_FILE}" "Next steps"
assert_contains "${SKILL_FILE}" "Reopen in Container"

# --- Reference file ---
echo ""
echo "--- Safety profile template ---"
assert_contains "${TEMPLATE_FILE}" "network_mode"
assert_contains "${TEMPLATE_FILE}" "secrets_method"
assert_contains "${TEMPLATE_FILE}" "safety_tier"
assert_contains "${TEMPLATE_FILE}" "acknowledged_risks"

# --- Skill references template ---
assert_contains "${SKILL_FILE}" "safety-profile-template.md"

# --- Profile version ---
echo ""
echo "--- Profile versioning ---"
assert_contains "${TEMPLATE_FILE}" "profile_version"

# --- Re-run detection ---
echo ""
echo "--- Idempotency ---"
assert_contains "${SKILL_FILE}" "Re-run Detection"
assert_contains "${SKILL_FILE}" "duplicate"

# --- JSON validation guidance ---
echo ""
echo "--- JSON safety ---"
assert_contains "${SKILL_FILE}" "valid JSON"

# --- Mode precedence ---
echo ""
echo "--- Mode precedence ---"
assert_contains "${SKILL_FILE}" "takes priority"

summary
