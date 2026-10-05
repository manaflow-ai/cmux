#!/usr/bin/env bash
# Behavior test for scripts/ci/cmux-tui-rust-check.sh with fake rustup and
# cargo: the step installs clippy and rustfmt before any cargo command (a
# step's own RUSTUP_HOME auto-installed the pinned toolchain without them on
# 2026-10-05, and `cargo fmt` failed with "no such command"), prints the
# toolchain, and fails loudly when the component install fails.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/ci/cmux-tui-rust-check.sh"
work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/src/cmux-tui"
cat >"$work/bin/rustup" <<'S'
#!/usr/bin/env bash
echo "rustup $*" >>"$CALLS"
case "$1" in
  component) [[ "$2" == list ]] && echo "rustfmt-aarch64-apple-darwin"; exit "${RUSTUP_RC:-0}" ;;
  show) echo "1.95.0-aarch64-apple-darwin (overridden by rust-toolchain.toml)" ;;
esac
S
cat >"$work/bin/cargo" <<'S'
#!/usr/bin/env bash
echo "cargo $*" >>"$CALLS"
S
chmod +x "$work/bin/"*
run() { # rc out
  : >"$work/calls"
  set +e
  out="$(cd "$work/src" && CALLS="$work/calls" PATH="$work/bin:$PATH" CMUX_CI_STEP_KEY=test "$@" 2>&1)"
  rc=$?
  set -e
}
fail() { echo "FAIL: $*" >&2; echo "$out" >&2; cat "$work/calls" >&2; exit 1; }

run "$script" fmt
[[ $rc -eq 0 ]] || fail "fmt: rc=$rc"
[[ "$(head -1 "$work/calls")" == "rustup component add clippy rustfmt" ]] || fail "components not installed first"
grep -q "^cargo fmt --all --check$" "$work/calls" || fail "cargo fmt not run"
grep -q "1.95.0-aarch64-apple-darwin" <<<"$out" || fail "active toolchain not printed"

RUSTUP_RC=1 run "$script" fmt
[[ $rc -ne 0 ]] || fail "a failed component install must fail the step"
! grep -q "^cargo" "$work/calls" || fail "cargo ran after a failed component install"

echo "ok: 2 rust-check cases"
