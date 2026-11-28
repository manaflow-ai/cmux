#!/usr/bin/env bash
# scripts/ci/cargo-test-wine.sh runs a windows-gnu cargo test selection on
# Linux under Wine. Stubs stand in for cargo, wine and wineboot: the wrapper
# must add the target, point cargo's runner at wine, create the prefix once,
# keep cargo-test-selected.sh's "ran no test" refusal, and refuse to run
# without wine.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/scripts/ci/cargo-test-wine.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/nowine"
cat > "$TMP/bin/cargo" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$STUB_DIR/args"
printf '%s\n' "$CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUNNER" > "$STUB_DIR/runner"
printf '%s\n' "$WINEPREFIX" > "$STUB_DIR/prefix"
printf '%b' "$STUB_OUTPUT"
exit "${STUB_STATUS:-0}"
EOF
cat > "$TMP/bin/wine" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TMP/bin/wineboot" <<'EOF'
#!/bin/sh
echo boot >> "$STUB_DIR/boots"
touch "$WINEPREFIX/system.reg"
EOF
chmod +x "$TMP/bin/"*
cp "$TMP/bin/cargo" "$TMP/nowine/cargo"
# The no-wine PATH holds only what the wrappers call, so a wine installed on the host is not found.
for tool in dirname mktemp tee awk rm cat mkdir timeout touch; do
  ln -s "$(command -v "$tool")" "$TMP/nowine/$tool"
done

fail() { printf 'FAIL: %s\n' "$*"; exit 1; }

# run <expected status> <PATH> <stub output> -- <wrapper args...>
run() {
  local want=$1 path=$2 stub_output=$3; shift 4
  local status=0
  OUT=$(env -u CMUX_WINE -u WINEPREFIX PATH="$path" STUB_DIR="$TMP" STUB_STATUS="${STUB_STATUS:-0}" RUNNER_TEMP="$TMP/rt" \
    STUB_OUTPUT="$stub_output" /bin/bash "$SCRIPT" "$@" 2>&1) || status=$?
  [[ $status -eq $want ]] || fail "exit $status, want $want, for: $*
$OUT"
}

five='running 5 tests\n\ntest result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 16 filtered out; finished in 0.00s\n\n'
zero='running 0 tests\n\ntest result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 21 filtered out; finished in 0.00s\n\n'

# A selection that runs tests passes; cargo gets the windows-gnu target, wine as its runner, a private prefix.
run 0 "$TMP/bin:/usr/bin:/bin" "$five" -- -p cmux-tui-platform --lib platform::tests:: -- --test-threads=1
[[ "$(cat "$TMP/args")" == "test --target x86_64-pc-windows-gnu -p cmux-tui-platform --lib platform::tests:: -- --test-threads=1" ]] \
  || fail "cargo args: $(cat "$TMP/args")"
[[ "$(cat "$TMP/runner")" == wine ]] || fail "runner: $(cat "$TMP/runner")"
[[ "$(cat "$TMP/prefix")" == "$TMP/rt/cmux-wine-prefix" ]] || fail "prefix: $(cat "$TMP/prefix")"
[[ "$(wc -l < "$TMP/boots")" -eq 1 ]] || fail "wineboot did not run once"

# The prefix is made once: a second run does not boot again.
run 0 "$TMP/bin:/usr/bin:/bin" "$five" -- -p cmux-tui-platform --lib platform::tests::
[[ "$(wc -l < "$TMP/boots")" -eq 1 ]] || fail "wineboot ran again for an existing prefix"

# A selection that matches nothing is still red (cargo-test-selected.sh).
run 1 "$TMP/bin:/usr/bin:/bin" "$zero" -- -p cmux-tui-platform --lib no_such_test::
grep -q 'ran no test' <<<"$OUT" || fail "no 'ran no test' message:
$OUT"

# A failing cargo run keeps its status.
STUB_STATUS=101 run 101 "$TMP/bin:/usr/bin:/bin" "$five" -- -p cmux-tui-platform --lib platform::tests::

# No wine: refused with an install hint, cargo never runs.
rm -f "$TMP/args"
run 2 "$TMP/nowine" "$five" -- -p cmux-tui-platform --lib platform::tests::
grep -q 'no wine on PATH' <<<"$OUT" || fail "no 'no wine' message:
$OUT"
[[ ! -e "$TMP/args" ]] || fail "cargo ran without wine"

# No selection: usage.
run 2 "$TMP/bin:/usr/bin:/bin" "" --
echo "PASS: cargo-test-wine.sh"
