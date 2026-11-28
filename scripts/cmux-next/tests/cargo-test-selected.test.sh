#!/usr/bin/env bash
# scripts/ci/cargo-test-selected.sh runs `cargo test` for a hand-picked test
# selection in CI and fails when the selection ran no test. After the
# platform crate split (f8e3500ec0df), four macOS steps kept selecting
# `-p cmux-tui-core --lib platform::tests::...`, matched 0 tests and passed
# green while running nothing. A stub `cargo` prints canned libtest output.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/scripts/ci/cargo-test-selected.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/cargo" <<'EOF'
#!/bin/sh
# Records its arguments, prints $STUB_OUTPUT, exits $STUB_STATUS.
printf '%s\n' "$*" > "$STUB_ARGS"
printf '%b' "$STUB_OUTPUT"
exit "${STUB_STATUS:-0}"
EOF
chmod +x "$TMP/bin/cargo"

fail() { printf 'FAIL: %s\n' "$*"; exit 1; }

# run <expected status> <stub status> <stub output> -- <wrapper args...>
run() {
  local want=$1 stub_status=$2 stub_output=$3; shift 4
  local status=0
  OUT=$(env PATH="$TMP/bin:/usr/bin:/bin" STUB_ARGS="$TMP/args" STUB_STATUS="$stub_status" \
    STUB_OUTPUT="$stub_output" /bin/bash "$SCRIPT" "$@" 2>&1) || status=$?
  [[ $status -eq $want ]] || fail "exit $status, want $want, for: $*
$OUT"
}

zero='running 0 tests\n\ntest result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 41 filtered out; finished in 0.00s\n\n'
three='running 3 tests\ntest a ... ok\ntest b ... ok\ntest c ... ok\n\ntest result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 38 filtered out; finished in 0.01s\n\n'
ignored_only='running 1 test\ntest slow ... ignored\n\ntest result: ok. 0 passed; 0 failed; 1 ignored; 0 measured; 40 filtered out; finished in 0.00s\n\n'

# A selection that matches nothing fails, names the arguments, and says why.
run 1 0 "$zero" -- -p cmux-tui-core --lib platform::tests:: -- --test-threads=2
grep -q 'ran no test' <<<"$OUT" || fail "no 'ran no test' message:
$OUT"
grep -qF -- '-p cmux-tui-core --lib platform::tests::' <<<"$OUT" || fail "message does not name the selection:
$OUT"
[[ "$(cat "$TMP/args")" == "test -p cmux-tui-core --lib platform::tests:: -- --test-threads=2" ]] \
  || fail "cargo got: $(cat "$TMP/args")"

# Several test binaries that all match nothing still fail.
run 1 0 "$zero$zero" -- -p cmux-remote workspace::process::tests::macos_pty_

# A selection that only reaches ignored tests runs nothing either.
run 1 0 "$ignored_only" -- -p cmux-tui-core --lib slow -- --exact

# A selection that runs tests passes, and the libtest output stays visible.
run 0 0 "$zero$three" -- -p cmux-tui-platform --lib platform::tests::
grep -q 'test result: ok. 3 passed' <<<"$OUT" || fail "libtest output was hidden:
$OUT"

# A failing cargo run keeps its own exit status (no count check hides it).
run 101 101 'test result: FAILED. 2 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out\n' -- -p x --lib y

# No selection at all is a usage error, not a silent run.
run 2 0 "$three" --

printf 'cargo-test-selected tests: ok\n'
