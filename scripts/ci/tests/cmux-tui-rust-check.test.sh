#!/usr/bin/env bash
# scripts/ci/cmux-tui-rust-check.sh: cmux-tui's Rust checks as a fleet CI step
# (`cmux-ci run --class isolated`), never on a developer Mac. A stub cargo
# records its arguments, umask and CARGO_TARGET_DIR.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/work/cmux-tui"
cat > "$TMP/bin/cargo" <<STUB
#!/bin/bash
echo "\$(umask) \${CARGO_TARGET_DIR:-unset} \$*" >> "$TMP/calls"
[[ "\$*" != "nextest --version" ]] || echo "cargo-nextest 0.9.148 (stub)"
STUB
chmod +x "$TMP/bin/cargo"
cat > "$TMP/bin/rustup" <<STUB
#!/bin/bash
case "\$1 \$2" in
  "component add") exit 0 ;;
  "show active-toolchain") echo pinned-toolchain ;;
  "component list") echo clippy ; echo rustfmt ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/rustup"
printf '#!/bin/bash\necho "rustc 1.95.0 (stub)"\n' > "$TMP/bin/rustc"
chmod +x "$TMP/bin/rustc"
cat > "$TMP/bin/git" <<STUB
#!/bin/bash
case " \$* " in
  *" submodule update --init --depth 1 ghostty-next "*) exit 0 ;;
  *) echo "unexpected git invocation: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/git"
run() { (cd "$TMP/work" && env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" "$@" /bin/bash "$ROOT/scripts/ci/cmux-tui-rust-check.sh" "${ARGS[@]}") 2>&1; }
fail() { echo "FAIL: $*"; exit 1; }
ARGS=(fmt)
out=$(run) && fail "ran outside a fleet step"
grep -q 'cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh' <<<"$out" || fail "refusal does not name the fleet command: $out"
[[ ! -e "$TMP/calls" ]] || fail "cargo ran outside a fleet step"
ARGS=(all 'cmux_link::')
(umask 077; run CMUX_CI_STEP_KEY=k) >/dev/null || fail "fleet step refused"
grep -q '^0022 .*/.build/cmux-tui-rust-target fmt --all --check$' "$TMP/calls" || fail "fmt: $(cat "$TMP/calls")"
grep -q '^0022 .*/.build/cmux-tui-rust-target clippy --workspace --exclude cmux-holder-v3 --all-targets --locked -- -D warnings$' "$TMP/calls" || fail "clippy: $(cat "$TMP/calls")"
grep -q '^0022 .*/.build/cmux-tui-rust-target nextest run --workspace --locked --profile ci --no-tests=fail cmux_link::$' "$TMP/calls" || fail "test: $(cat "$TMP/calls")"
! grep -q ' --doc' "$TMP/calls" || fail "doc tests ran with a filter: $(cat "$TMP/calls")"
rm -f "$TMP/calls"
# terminal: only the terminal stack's crates (ghostty-vt's VT, tmux regress and
# kitty suites, the PTY, sizing, encode and client crates), no fmt, clippy or doc tests.
ARGS=(terminal)
run CMUX_CI_STEP_KEY=k >/dev/null || fail "terminal mode refused"
grep -q '^0022 .*/.build/cmux-tui-rust-target nextest run -p ghostty-vt -p ghostty-vt-sys -p cmux-pty -p cmux-terminal-sizing -p cmux-terminal-client -p cmux-encode --locked --profile ci --no-tests=fail$' "$TMP/calls" || fail "terminal: $(cat "$TMP/calls")"
! grep -q -E ' fmt | clippy | --doc|--workspace' "$TMP/calls" || fail "terminal mode ran more than the terminal crates: $(cat "$TMP/calls")"
rm -f "$TMP/calls"
ARGS=(terminal 'tmux_conformance')
run CMUX_CI_STEP_KEY=k >/dev/null || fail "terminal mode with a filter refused"
grep -q -- '--no-tests=fail tmux_conformance$' "$TMP/calls" || fail "terminal filter: $(cat "$TMP/calls")"
rm -f "$TMP/calls"
ARGS=(test 'x; rm -rf /')
run CMUX_CI_STEP_KEY=k >/dev/null && fail "accepted a filter with shell syntax"
ARGS=(deploy)
run CMUX_CI_STEP_KEY=k >/dev/null && fail "accepted an unknown mode"
[[ ! -e "$TMP/calls" ]] || fail "cargo ran for a refused request"
printf 'cmux-tui-rust-check tests: ok\n'
