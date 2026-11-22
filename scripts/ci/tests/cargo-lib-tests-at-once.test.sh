#!/usr/bin/env bash
# Tests scripts/ci/cargo-lib-tests-at-once.sh on a real three-crate workspace: the library binaries run at
# once (two 3 s tests finish in well under 6 s), each from its package's directory, the log reads as
# `cargo test --lib` prints it (one `Running` line and one `test result:` per binary, a failure's
# `test NAME ... FAILED` and cargo's rerun line), and a red or crashed binary fails the run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../cargo-lib-tests-at-once.sh"
verdict="$here/../cargo_test_verdict.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/ws/slow_a/src" "$work/ws/slow_b/src" "$work/ws/red/src"
cat > "$work/ws/Cargo.toml" <<'TOML'
[workspace]
members = ["slow_a", "slow_b", "red"]
resolver = "2"
TOML
for name in slow_a slow_b red; do
  printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n' "${name//_/-}" > "$work/ws/$name/Cargo.toml"
done
cat > "$work/ws/slow_a/src/lib.rs" <<'RS'
#[test]
fn waits() { std::thread::sleep(std::time::Duration::from_secs(3)); }
#[test]
fn runs_from_its_package() {
    assert!(std::path::Path::new("Cargo.toml").exists());
    assert_eq!(std::env::var("CARGO_PKG_NAME").unwrap(), "slow-a");
    assert!(std::env::var("CARGO_MANIFEST_DIR").unwrap().ends_with("slow_a"));
}
RS
cat > "$work/ws/slow_b/src/lib.rs" <<'RS'
#[test]
fn waits() { std::thread::sleep(std::time::Duration::from_secs(3)); }
RS
cat > "$work/ws/red/src/lib.rs" <<'RS'
#[test]
fn passes() {}
#[test]
fn is_red() {
    if std::env::var_os("RED_CRASH").is_some() { std::process::abort(); }
    assert_eq!(1, 2);
}
RS

# The fixture sits outside the repo, so rustup would pick the host's default toolchain, which pool hosts
# do not agree on: use the one cmux-tui pins (the job installed it).
if [[ -z "${RUSTUP_TOOLCHAIN:-}" && -f "$here/../../../cmux-tui/rust-toolchain.toml" ]]; then
  RUSTUP_TOOLCHAIN="$(sed -n 's/^channel = "\(.*\)"$/\1/p' "$here/../../../cmux-tui/rust-toolchain.toml")"
  [[ -n "$RUSTUP_TOOLCHAIN" ]] && export RUSTUP_TOOLCHAIN
fi
cd "$work/ws"
export CARGO_TARGET_DIR="$work/target"
cargo test --quiet -p slow-a -p slow-b -p red --lib --no-run >/dev/null 2>&1 || fail "the fixture workspace does not build"

# Green: two packages whose 3 s tests run at once.
started=$(date +%s)
"$script" "$work/logs-green" -p slow-a -p slow-b > "$work/green.log" 2>&1 || { cat "$work/green.log"; fail "a green run failed"; }
took=$(( $(date +%s) - started ))
(( took < 6 )) || fail "the binaries ran one after another (${took} s)"
[[ $(grep -c '^     Running unittests src/lib.rs (' "$work/green.log") == 2 ]] || fail "not one Running line per binary"
[[ $(grep -c '^test result: ok\.' "$work/green.log") == 2 ]] || fail "not one test result per binary"
grep -qx 'test runs_from_its_package ... ok' "$work/green.log" || fail "a binary did not run from its package"

# Serial switch: today's order and timing.
started=$(date +%s)
CMUX_LIB_TESTS_SERIAL=1 "$script" "$work/logs-serial" -p slow-a -p slow-b > /dev/null 2>&1 || fail "a serial run failed"
(( $(date +%s) - started >= 6 )) || fail "CMUX_LIB_TESTS_SERIAL=1 still ran the binaries at once"

# Red: exit 101, cargo's lines, and the verdict reads the failing test by name.
code=0
"$script" "$work/logs-red" -p slow-b -p red > "$work/red.log" 2>&1 || code=$?
[[ $code == 101 ]] || fail "a red run exited $code, not 101"
grep -qx 'test is_red ... FAILED' "$work/red.log" || fail "the failing test is not named"
grep -qF 'error: test failed, to rerun pass `-p red --lib`' "$work/red.log" || fail "no rerun line"
[[ "$(python3 "$verdict" failed "$work/red.log")" == is_red ]] || fail "the verdict does not read the failing test"

# Crash: the signal is named as cargo names it, so test_reds counts the binary as crashed.
code=0
RED_CRASH=1 "$script" "$work/logs-crash" -p red > "$work/crash.log" 2>&1 || code=$?
[[ $code == 101 ]] || fail "a crashed run exited $code, not 101"
grep -qE "process didn't exit successfully: .*\(signal: 6\)" "$work/crash.log" || fail "the crash signal is not named"

# Nothing listed (no such package): exit 1.
code=0
"$script" "$work/logs-none" -p no-such-package > /dev/null 2>&1 || code=$?
[[ $code == 1 ]] || fail "an empty list exited $code, not 1"

echo "cargo-lib-tests-at-once: ok"
