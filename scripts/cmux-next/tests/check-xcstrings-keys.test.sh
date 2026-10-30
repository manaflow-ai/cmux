#!/usr/bin/env bash
# check-xcstrings-keys.py: a tracked string catalog that names a key twice in one object (a string
# key, a language, a plural category) or is not valid JSON fails; distinct keys, the same key in
# different objects, untracked catalogs and the real tree pass.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-xcstrings-keys.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-xcstrings-keys.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
CATALOG=webviews/src/agent-session/acpmux/Localizable.xcstrings

# Runs the guard on a git repo whose only tracked catalog is $1 holding $2.
check() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$1")"
  printf '%s\n' "$2" > "$tmp/repo/$1"
  git -C "$tmp/repo" init -q
  git -C "$tmp/repo" add -- "$1"
  local code=0
  python3 -I "$CHECK" --root "$tmp/repo" >"$tmp/out" 2>&1 || code=$?
  # 0 = clean; 1 = a finding that names the file; anything else is a crash.
  if [[ $code -eq 1 ]] && ! grep -q "$1" "$tmp/out"; then code=3; fi
  return "$code"
}
pass() { check "$CATALOG" "$2" || { echo "FAIL: must pass: $1" >&2; cat "$tmp/out" >&2; exit 1; }; }
fail() {
  local code=0
  check "$CATALOG" "$2" || code=$?
  [[ $code -eq 1 ]] || { echo "FAIL: must fail with a finding (got $code): $1" >&2; cat "$tmp/out" >&2; exit 1; }
}
unit() { printf '{ "stringUnit" : { "state" : "translated", "value" : "%s" } }' "$1"; }

fail "a string key twice (two branches each added it)" "{ \"strings\" : {
    \"message.delivered\" : { \"localizations\" : { \"en\" : $(unit 'Delivered to {to}') } },
    \"message.delivered\" : { \"localizations\" : { \"en\" : $(unit 'Delivered when the step ends') } }
  }, \"version\" : \"1.0\" }"
grep -q 'lines 2, 3' "$tmp/out" || { echo "FAIL: the finding names both lines" >&2; cat "$tmp/out" >&2; exit 1; }
fail "a language twice" "{ \"strings\" : { \"a\" : { \"localizations\" : { \"en\" : $(unit A), \"en\" : $(unit B) } } } }"
fail "a plural category twice" "{ \"strings\" : { \"a\" : { \"localizations\" : { \"en\" : { \"variations\" : { \"plural\" : {
  \"one\" : $(unit '%d file'), \"one\" : $(unit '%d files') } } } } } } }"
fail "a catalog that is not JSON (a conflict left in it)" $'{ "strings" : {\n<<<<<<< HEAD\n} }'

pass "distinct keys" "{ \"strings\" : { \"a\" : { \"localizations\" : { \"en\" : $(unit A) } }, \"b\" : { \"localizations\" : { \"en\" : $(unit B) } } } }"
pass "the same language under different keys" "{ \"strings\" : { \"a\" : { \"localizations\" : { \"en\" : $(unit A), \"de\" : $(unit A) } }, \"b\" : { \"localizations\" : { \"en\" : $(unit B) } } } }"

# An untracked catalog is not the tree's.
check "$CATALOG" '{ "strings" : { } }'
printf '{ "a" : 1, "a" : 2 }\n' > "$tmp/repo/stray.xcstrings"
python3 -I "$CHECK" --root "$tmp/repo" >"$tmp/out" 2>&1 || { echo "FAIL: an untracked catalog is skipped" >&2; cat "$tmp/out" >&2; exit 1; }

python3 -I "$CHECK" --root "$ROOT_DIR" >"$tmp/out" 2>&1 || { echo "FAIL: the real tree is clean" >&2; cat "$tmp/out" >&2; exit 1; }
echo "check-xcstrings-keys: ok"
