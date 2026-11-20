#!/usr/bin/env bash
# check-no-inline-tests.py: a top-level inline `#[cfg(test)] mod NAME {` block in cmux-tui Rust is a finding (one
# line each); a `#[path]` declared test module, test files, tests/ folders and Rust outside cmux-tui are not.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-no-inline-tests.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-no-inline-tests.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Writes FILE with CONTENT into a fresh root (no git: the check walks the folder) and runs the check.
run() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$1")"
  printf '%b' "$2" > "$tmp/repo/$1"
  local code=0
  python3 -I "$CHECK" "$tmp/repo" > "$tmp/out" 2>&1 || code=$?
  echo "$code"
}
expect() {
  local what="$1" want="$2" got="$3"
  [[ "$got" == "$want" ]] || { echo "FAIL: $what: exit $got, want $want" >&2; cat "$tmp/out" >&2; exit 1; }
}
SRC=cmux-tui/crates/demo/src/foo.rs
INLINE='pub fn f() {}\n\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn t() {}\n}\n'

expect "an inline tests module" 1 "$(run "$SRC" "$INLINE")"
grep -q "^$SRC: inline #\[cfg(test)\] mod tests" "$tmp/out" || { echo "FAIL: finding names file and module" >&2; exit 1; }
expect "attributes between cfg and mod" 1 "$(run "$SRC" '#[cfg(test)]\n#[allow(clippy::unwrap_used)]\npub(crate) mod proptests {\n}\n')"
expect "a declared test module" 0 "$(run "$SRC" '#[cfg(test)]\n#[path = "foo_tests.rs"]\nmod tests;\n')"
expect "a nested (indented) module" 0 "$(run "$SRC" 'mod outer {\n    #[cfg(test)]\n    mod tests {\n    }\n}\n')"
expect "a _tests.rs file" 0 "$(run cmux-tui/crates/demo/src/foo_tests.rs "$INLINE")"
expect "a tests/ folder" 0 "$(run cmux-tui/crates/demo/tests/it.rs "$INLINE")"
expect "Rust outside cmux-tui" 0 "$(run Native/demo/src/foo.rs "$INLINE")"
echo "check-no-inline-tests: all cases pass"
