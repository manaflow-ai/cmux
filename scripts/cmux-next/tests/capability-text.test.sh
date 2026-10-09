#!/usr/bin/env bash
# check-capability-text.py: capability error texts never tell the user to
# update the app or daemon (plans/cmux-next/version-skew.md step 4).
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
check="$repo/scripts/cmux-next/check-capability-text.py"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

src="$tmp/cmux-tui/crates/demo/src"
mkdir -p "$src" "$tmp/cmux-tui/crates/demo/tests"
cat >"$src/lib.rs" <<'RS'
// A comment may say: update the app.
pub const OK: &str = "run the CLI that ships with the daemon: /x/cmux";
RS
cat >"$tmp/cmux-tui/crates/demo/tests/t.rs" <<'RS'
const T: &str = "update the cmux app or daemon";
RS
cat >"$src/m_tests.rs" <<'RS'
const T: &str = "update the app";
RS
python3 "$check" --root "$tmp" >/dev/null || fail "clean tree, comments and test files must pass"

for text in "update the cmux app or daemon" "Update and relaunch {app}" "upgrade cmux-tui" \
  "cmux アプリまたはデーモンを更新してください" "{app} を更新して再起動"; do
  printf 'pub const E: &str = "%s";\n' "$text" >"$src/bad.rs"
  if out="$(python3 "$check" --root "$tmp")"; then fail "'$text' must be refused"; fi
  case "$out" in *"demo/src/bad.rs:1"*) ;; *) fail "'$text' not named: $out" ;; esac
done
rm "$src/bad.rs"

printf 'pub const E: &str = "x";\n#[cfg(test)]\nmod tests {\n    const T: &str = "update the app";\n}\n' >"$src/inline.rs"
python3 "$check" --root "$tmp" >/dev/null || fail "an inline #[cfg(test)] module must be skipped"

python3 "$check" --root "$repo" || fail "the repository has capability texts that say update"
echo "capability-text tests: ok"
