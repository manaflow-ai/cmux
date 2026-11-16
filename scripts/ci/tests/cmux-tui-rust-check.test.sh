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
if [[ -n "\${CLIPPY_FAIL:-}" && "\$1" == clippy ]]; then
  echo '{"reason":"compiler-message","message":{"level":"error","rendered":"error[E0425]: cannot find value x (stub)\\n"}}'
  exit 101
fi
echo "\${GOFLAGS:-unset} \${GOMODCACHE:-unset} \${GOCACHE:-unset}" >> "$TMP/goenv"
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
echo "\$*" >> "$TMP/git-calls"
case " \$* " in
  *" submodule update --init --depth 1 ghostty-next "*) exit 0 ;;
  *" diff --no-color --no-ext-diff --stat -- cmux-tui/spec/api-compat."*) [[ -n "\${API_COMPAT_SAME:-}" ]] || echo " cmux-tui/spec/api-compat.wire.json | 4 ++-- (stub)" ;;
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
# --keep-going: a red crate does not hide the crates after it (one fleet round finds every clippy error).
grep -q '^0022 .*/.build/cmux-tui-rust-target clippy --workspace --exclude cmux-holder-v3 --all-targets --locked --keep-going -- -D warnings$' "$TMP/calls" || fail "clippy: $(cat "$TMP/calls")"
grep -q '^0022 .*/.build/cmux-tui-rust-target nextest run --workspace --locked --profile ci --no-tests=fail cmux_link::$' "$TMP/calls" || fail "test: $(cat "$TMP/calls")"
! grep -q ' --doc' "$TMP/calls" || fail "doc tests ran with a filter: $(cat "$TMP/calls")"
# cmux-tailnet's build script runs Go: its caches stay in the checkout's .build, and
# its module cache is writable, so the step's cleanup can remove it.
! grep -v -q '^-modcacherw .*/work/.build/go-path/pkg/mod .*/work/.build/go-cache$' "$TMP/goenv" || fail "go env: $(cat "$TMP/goenv")"
rm -f "$TMP/calls" "$TMP/goenv"
# CMUX_RUST_CHECK_FAIL_FAST=1 stops clippy at its first red crate too.
ARGS=(clippy)
run CMUX_CI_STEP_KEY=k CMUX_RUST_CHECK_FAIL_FAST=1 >/dev/null || fail "fail-fast clippy refused"
grep -q '^0022 .*/.build/cmux-tui-rust-target clippy --workspace --exclude cmux-holder-v3 --all-targets --locked -- -D warnings$' "$TMP/calls" || fail "fail-fast clippy: $(cat "$TMP/calls")"
rm -f "$TMP/calls" "$TMP/goenv"
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
# test FILTER SCOPE: a third argument names where the filter's tests are: crate names with commas,
# or one CRATE:TARGET for one integration test target of a crate. cargo then builds the test
# binaries of that scope only; a filtered run of the whole workspace builds every test binary of
# every crate to run a few tests. Without it the scope is the whole workspace.
# The step's target has a deps folder here, so the prune (cargo test --no-run) is in the calls.
mkdir -p "$TMP/work/.build/cmux-tui-rust-target/debug/deps"
ARGS=(test 'parked')
run CMUX_CI_STEP_KEY=k >/dev/null || fail "test with a filter refused"
grep -q '^0022 .*/.build/cmux-tui-rust-target nextest run --workspace --locked --profile ci --no-tests=fail parked$' "$TMP/calls" || fail "test without a crate scope: $(cat "$TMP/calls")"
grep -q '^0022 .*/.build/cmux-tui-rust-target test --workspace --locked --no-run --message-format=json$' "$TMP/calls" || fail "the workspace run did not prune: $(cat "$TMP/calls")"
rm -f "$TMP/calls"
ARGS=(test 'parked' cmux-tui-core)
out=$(run CMUX_CI_STEP_KEY=k) || fail "test with one crate refused: $out"
grep -q '^0022 .*/.build/cmux-tui-rust-target nextest run -p cmux-tui-core --locked --profile ci --no-tests=fail parked$' "$TMP/calls" || fail "test with one crate: $(cat "$TMP/calls")"
grep -q '^0022 .*/.build/cmux-tui-rust-target nextest show-config test-groups -p cmux-tui-core --locked --profile ci$' "$TMP/calls" || fail "the test groups of one crate: $(cat "$TMP/calls")"
! grep -q -- '--workspace' "$TMP/calls" || fail "a crate scope reached the whole workspace: $(cat "$TMP/calls")"
# The prune keeps only the units that its own build lists. With a crate scope it would delete the
# units of every other crate from a target that later steps share, so it does not run.
! grep -q -- '--no-run' "$TMP/calls" || fail "a crate scope pruned the target: $(cat "$TMP/calls")"
grep -q 'gate-notice: crate scope: -p cmux-tui-core$' <<<"$out" || fail "the crate scope is not in the log: $out"
rm -f "$TMP/calls"
ARGS=(test 'git_ops' cmux-tui-core,cmux-git)
run CMUX_CI_STEP_KEY=k >/dev/null || fail "test with two crates refused"
grep -q '^0022 .*/.build/cmux-tui-rust-target nextest run -p cmux-tui-core -p cmux-git --locked --profile ci --no-tests=fail git_ops$' "$TMP/calls" || fail "test with two crates: $(cat "$TMP/calls")"
rm -f "$TMP/calls"
# CRATE:TARGET is one test target: tests/startup_timings.rs of the crate cmux-tui here.
ARGS=(test 'build_step' cmux-tui:startup_timings)
out=$(run CMUX_CI_STEP_KEY=k) || fail "test with a crate and a test target refused: $out"
grep -q '^0022 .*/.build/cmux-tui-rust-target nextest run -p cmux-tui --test startup_timings --locked --profile ci --no-tests=fail build_step$' "$TMP/calls" || fail "test with a crate and a test target: $(cat "$TMP/calls")"
! grep -q -- '--workspace' "$TMP/calls" || fail "a test target scope reached the whole workspace: $(cat "$TMP/calls")"
! grep -q -- '--no-run' "$TMP/calls" || fail "a test target scope pruned the target: $(cat "$TMP/calls")"
grep -q 'gate-notice: crate scope: -p cmux-tui --test startup_timings$' <<<"$out" || fail "the test target scope is not in the log: $out"
rm -f "$TMP/calls"
# 8 crates are the most that a scope takes.
ARGS=(test 'parked' a,b,c,d,e,f,g,h)
run CMUX_CI_STEP_KEY=k >/dev/null || fail "test with 8 crates refused"
grep -q '^0022 .*/.build/cmux-tui-rust-target nextest run -p a -p b -p c -p d -p e -p f -p g -p h --locked --profile ci --no-tests=fail parked$' "$TMP/calls" || fail "test with 8 crates: $(cat "$TMP/calls")"
rm -f "$TMP/calls"
# A scope that is not a list of crate names or one CRATE:TARGET, or that has no filter, a shard,
# an @affected scope or another mode, is refused with exit 2 before any cargo command. Refused
# forms: a space, an option, an empty name (at the start, in the middle, at the end), a path, a
# command substitution, more than 8 crates, a name that starts with _, an empty target or crate
# next to the colon, 2 colons, a character that is not a letter, a digit, - or _, and a target
# with a list.
refused() { # WHAT ENV...: the run of ARGS ends with exit 2; its output is in $out
  local what="$1" rc=0
  shift
  out=$(run "$@") || rc=$?
  [[ "$rc" -eq 2 ]] || fail "$what: exit $rc, wanted the refusal's exit 2: $out"
}
for bad in 'cmux tui' '-p' '--workspace' 'cmux-tui-core,' ',cmux-git' 'a,,b' 'crates/cmux-git' 'a;b' '$(id)' '`id`' \
  'a,b,c,d,e,f,g,h,i' '_a' 'cmux-tui:' ':startup_timings' 'cmux-tui:a:b' 'cmux-tui::a' 'cmux-tui:start up' \
  'cmux-tui:a.b' 'cmux-tui:-a' 'cmux-tui:a,cmux-git' 'cmux-git,cmux-tui:a' 'cmux-tui:a,cmux-git:b'; do
  ARGS=(test 'parked' "$bad")
  refused "the crate scope '$bad'" CMUX_CI_STEP_KEY=k
  grep -q 'error: the crate scope must be crate names' <<<"$out" || fail "crate scope '$bad' was refused without its reason: $out"
done
ARGS=(test '' cmux-tui-core)
refused "a crate scope without a filter" CMUX_CI_STEP_KEY=k
grep -q 'error: a crate scope takes the test mode with a TEST_FILTER' <<<"$out" || fail "no filter: refused without its reason: $out"
ARGS=(test '@affected=0123456789abcdef0123456789abcdef01234567' cmux-tui-core)
refused "a crate scope with an @affected scope" CMUX_CI_STEP_KEY=k
ARGS=(all 'parked' cmux-tui-core)
refused "a crate scope in the all mode" CMUX_CI_STEP_KEY=k
ARGS=(terminal 'parked' cmux-tui-core)
refused "a crate scope in the terminal mode" CMUX_CI_STEP_KEY=k
ARGS=(clippy '' cmux-tui-core)
refused "a crate scope in the clippy mode" CMUX_CI_STEP_KEY=k
ARGS=(test 'parked' cmux-tui-core)
refused "a crate scope with a shard" CMUX_CI_STEP_KEY=k CMUX_RUST_TEST_SHARD=1/2
# The scope is one argument. 2 crates as 2 arguments would test the first crate only and say
# nothing of the second one, so a fourth argument is refused.
ARGS=(test 'parked' cmux-tui-core cmux-git)
refused "a fourth argument after the crate scope" CMUX_CI_STEP_KEY=k
grep -q 'error: the crate scope is one argument' <<<"$out" || fail "a fourth argument: refused without its reason: $out"
[[ ! -e "$TMP/calls" ]] || fail "cargo ran for a refused crate scope: $(cat "$TMP/calls")"
rm -rf "$TMP/work/.build/cmux-tui-rust-target/debug"
# api-compat: cmux-tui-spec.yml's protocol compat check, the same cargo command. Its crate
# needs only serde, so no ghostty-next checkout; it takes no filter and returns nothing.
rm -f "$TMP/calls" "$TMP/git-calls"
ARGS=(api-compat)
run CMUX_CI_STEP_KEY=k >/dev/null || fail "api-compat mode refused"
[[ "$(cat "$TMP/calls")" == *"/.build/cmux-tui-rust-target run --locked -p cmux-api-compat --bin api-compat-check" ]] || fail "api-compat: $(cat "$TMP/calls")"
! grep -q -E ' fmt | clippy | nextest | --write' "$TMP/calls" || fail "api-compat ran more than the check: $(cat "$TMP/calls")"
! grep -q submodule "$TMP/git-calls" 2>/dev/null || fail "api-compat checked out ghostty-next: $(cat "$TMP/git-calls")"
rm -f "$TMP/calls" "$TMP/git-calls"
# api-compat-write: the --write form, which rewrites the snapshot and the wire ledger, then packs
# both (those present) into .build/artifacts/api-compat-spec.tar (the step's artifact) and says what
# changed. It never commits or pushes; unchanged files are green.
mkdir -p "$TMP/work/cmux-tui/spec"
echo '{"surface":1}' >"$TMP/work/cmux-tui/spec/api-compat.surface.json"
echo '{"wire":1}' >"$TMP/work/cmux-tui/spec/api-compat.wire.json"
ARGS=(api-compat-write)
out=$(run CMUX_CI_STEP_KEY=k) || fail "api-compat-write mode refused: $out"
grep -q '/.build/cmux-tui-rust-target run --locked -p cmux-api-compat --bin api-compat-check -- --write$' "$TMP/calls" || fail "api-compat-write: $(cat "$TMP/calls")"
grep -q 'api-compat-write: changed: .*(stub)' <<<"$out" || fail "api-compat-write did not report the change: $out"
[[ "$(tar -tf "$TMP/work/.build/artifacts/api-compat-spec.tar" | sort | tr '\n' ' ')" == "cmux-tui/spec/api-compat.surface.json cmux-tui/spec/api-compat.wire.json " ]] || fail "the artifact does not hold both files: $(tar -tf "$TMP/work/.build/artifacts/api-compat-spec.tar")"
mkdir -p "$TMP/x" && tar -xf "$TMP/work/.build/artifacts/api-compat-spec.tar" -C "$TMP/x" && grep -q wire "$TMP/x/cmux-tui/spec/api-compat.wire.json" || fail "the artifact does not extract at a checkout root"
# A crate without the wire ledger (feat-cmux-next today): the snapshot alone.
rm -f "$TMP/work/cmux-tui/spec/api-compat.wire.json"
run CMUX_CI_STEP_KEY=k >/dev/null || fail "api-compat-write without a wire ledger is red"
[[ "$(tar -tf "$TMP/work/.build/artifacts/api-compat-spec.tar")" == "cmux-tui/spec/api-compat.surface.json" ]] || fail "the artifact without a wire ledger: $(tar -tf "$TMP/work/.build/artifacts/api-compat-spec.tar")"
! grep -q -E 'submodule|commit|push|add ' "$TMP/git-calls" || fail "api-compat-write ran git beyond the diff: $(cat "$TMP/git-calls")"
rm -f "$TMP/calls" "$TMP/git-calls"
out=$(run CMUX_CI_STEP_KEY=k API_COMPAT_SAME=1) || fail "api-compat-write with a current snapshot is red: $out"
grep -q 'api-compat.surface.json unchanged' <<<"$out" || fail "api-compat-write did not report a current snapshot: $out"
rm -rf "$TMP/work/cmux-tui/spec" "$TMP/work/.build/artifacts" "$TMP/x"
rm -f "$TMP/calls"
ARGS=(api-compat 'cmux_link::')
run CMUX_CI_STEP_KEY=k >/dev/null && fail "api-compat accepted a filter"
[[ ! -e "$TMP/calls" ]] || fail "cargo ran for an api-compat filter"
# panic: cmux-tui.yml's "Rust panic ratchet" step, the same two commands from cmux-tui/: clippy on the
# production targets with the ratchet's own flags into a JSON file, then the ratchet on that file. No fmt,
# tests or -D warnings; no filter; the ratchet's exit code is the step's.
mkdir -p "$TMP/work/scripts/cmux-next"
cat > "$TMP/work/scripts/cmux-next/rust_panic_ratchet.py" <<STUB
import os, sys
open("$TMP/ratchet-calls", "a").write(os.getcwd() + " " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["--flags"]:
    print("-W clippy::unwrap_used -W clippy::indexing_slicing")
else:
    sys.exit(int(os.environ.get("PANIC_RC", "0")))
STUB
cat > "$TMP/bin/uname" <<'STUB'
#!/bin/bash
echo "${FAKE_UNAME:-Linux}"
STUB
chmod +x "$TMP/bin/uname"
rm -f "$TMP/calls" "$TMP/ratchet-calls"
ARGS=(panic)
out=$(run CMUX_CI_STEP_KEY=k FAKE_UNAME=Darwin) && fail "panic mode ran off Linux: $out"
grep -q 'runs only on Linux' <<<"$out" || fail "panic off-Linux refusal: $out"
[[ ! -e "$TMP/calls" ]] || fail "cargo ran for panic off Linux: $(cat "$TMP/calls")"
out=$(run CMUX_CI_STEP_KEY=k) || fail "panic mode refused or red: $out"
[[ "$(cat "$TMP/calls")" == *"/.build/cmux-tui-rust-target clippy --workspace --lib --bins --locked --message-format=json -- -W clippy::unwrap_used -W clippy::indexing_slicing" ]] || fail "panic clippy: $(cat "$TMP/calls")"
! grep -q -E ' fmt | nextest |-D warnings|--all-targets' "$TMP/calls" || fail "panic mode ran more than the ratchet's clippy: $(cat "$TMP/calls")"
grep -q '/work/cmux-tui --flags$' "$TMP/ratchet-calls" || fail "panic flags: $(cat "$TMP/ratchet-calls")"
grep -q '/work/cmux-tui --clippy-json .*/work/.build/artifacts/panic-clippy.jsonl$' "$TMP/ratchet-calls" || fail "panic ratchet: $(cat "$TMP/ratchet-calls")"
grep -q 'cmux-tui-rust-check: green' <<<"$out" || fail "panic summary: $out"
out=$(run CMUX_CI_STEP_KEY=k PANIC_RC=1) && fail "a ratchet over its baseline was green: $out"
grep -q 'panic ratchet *FAIL (exit 1)' <<<"$out" || fail "panic red summary: $out"
# A clippy that fails (a compile error) prints its errors, never runs the ratchet, and keeps cargo's exit code.
rm -f "$TMP/ratchet-calls"
out=$(run CMUX_CI_STEP_KEY=k CLIPPY_FAIL=1) && fail "a failed clippy was green: $out"
grep -q 'panic ratchet *FAIL (exit 101)' <<<"$out" || fail "failed clippy summary: $out"
grep -q 'cannot find value x (stub)' <<<"$out" || fail "failed clippy printed no compiler error: $out"
! grep -q -- '--clippy-json' "$TMP/ratchet-calls" || fail "the ratchet ran after a failed clippy: $(cat "$TMP/ratchet-calls")"
rm -f "$TMP/calls"
ARGS=(panic 'cmux_link::')
run CMUX_CI_STEP_KEY=k >/dev/null && fail "panic accepted a filter"
[[ ! -e "$TMP/calls" ]] || fail "cargo ran for a panic filter"
rm -rf "$TMP/work/scripts" "$TMP/ratchet-calls"
# One Go pin: the screen mode's checksummed download covers the version the macOS
# job of cmux-tui.yml installs (crates/cmux-tailnet/go-version).
go_version=$(tr -d '[:space:]' <"$ROOT/cmux-tui/crates/cmux-tailnet/go-version")
grep -q "^      $go_version-arm64) " "$ROOT/scripts/ci/cmux-tui-rust-check.sh" || fail "no pinned sha256 for Go $go_version (cmux-tailnet/go-version)"
grep -q "go-version-file: cmux-tui/crates/cmux-tailnet/go-version" "$ROOT/.github/workflows/cmux-tui.yml" || fail "cmux-tui.yml's macOS job does not install cmux-tailnet's Go"
printf 'cmux-tui-rust-check tests: ok\n'
