#!/usr/bin/env bash
# Shared test assertion helpers for vibeshield tests
set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "  FAIL: $1" >&2
}

assert_file_exists() {
  if [[ -f "$1" ]]; then
    pass "File exists: $1"
  else
    fail "File missing: $1"
  fi
}

assert_dir_exists() {
  if [[ -d "$1" ]]; then
    pass "Directory exists: $1"
  else
    fail "Directory missing: $1"
  fi
}

assert_executable() {
  if [[ -x "$1" ]]; then
    pass "File executable: $1"
  else
    fail "File not executable: $1"
  fi
}

assert_json_valid() {
  if python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$1" 2>/dev/null || node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$1" 2>/dev/null; then
    pass "Valid JSON: $1"
  else
    fail "Invalid JSON: $1"
  fi
}

assert_json_has_key() {
  local file="$1"
  local key="$2"
  if python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
keys = sys.argv[2].split('.')
for k in keys:
    d = d[k]
" "$file" "$key" 2>/dev/null; then
    pass "JSON key exists: ${key} in ${file}"
  else
    fail "JSON key missing: ${key} in ${file}"
  fi
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    pass "File contains pattern: $pattern"
  else
    fail "File missing pattern: $pattern in $file"
  fi
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    fail "File should not contain pattern: $pattern in $file"
  else
    pass "File correctly excludes pattern: $pattern"
  fi
}

summary() {
  echo ""
  echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
  if [[ ${FAIL_COUNT} -gt 0 ]]; then
    exit 1
  fi
}
