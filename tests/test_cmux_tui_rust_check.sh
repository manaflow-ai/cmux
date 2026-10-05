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
  which) echo "$TOOLCHAIN_BIN/$2" ;;
esac
S
cat >"$work/bin/cargo" <<'S'
#!/usr/bin/env bash
echo "path-cargo $*" >>"$CALLS"
S
# The pinned toolchain's own bin dir (cargo, cargo-fmt, cargo-clippy). A cargo
# that is not the rustup proxy finds `cargo-fmt` only on PATH (2026-10-05:
# step fafed265 on cmux7 had rustfmt installed and still got "no such command").
mkdir -p "$work/toolchain/bin"
cat >"$work/toolchain/bin/cargo" <<'S'
#!/usr/bin/env bash
echo "cargo $*" >>"$CALLS"
S
# The step's checkout has empty submodules (2026-10-05, step ee99e05f:
# ghostty-vt-sys found no build.zig in ghostty-next).
cat >"$work/bin/git" <<'S'
#!/usr/bin/env bash
echo "git $*" >>"$CALLS"
exit "${GIT_RC:-0}"
S
chmod +x "$work/bin/"* "$work/toolchain/bin/cargo"
export TOOLCHAIN_BIN="$work/toolchain/bin"
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
add_line="$(grep -n "^rustup component add clippy rustfmt$" "$work/calls" | cut -d: -f1)"
first_cargo="$(grep -n "^cargo " "$work/calls" | head -1 | cut -d: -f1)"
[[ -n "$add_line" && "$add_line" -lt "$first_cargo" ]] || fail "components not installed before cargo"
grep -q "^cargo fmt --all --check$" "$work/calls" || fail "cargo fmt not run with the toolchain's own cargo"
! grep -q "^path-cargo" "$work/calls" || fail "a cargo from PATH ran instead of the toolchain's"
grep -q "1.95.0-aarch64-apple-darwin" <<<"$out" || fail "active toolchain not printed"
sub_line="$(grep -n "^git -C $work/src submodule update --init --depth 1 ghostty ghostty-next$" "$work/calls" | cut -d: -f1)"
cargo_line="$(grep -n "^cargo " "$work/calls" | head -1 | cut -d: -f1)"
[[ -n "$sub_line" && "$sub_line" -lt "$cargo_line" ]] || fail "submodules not initialized before cargo"

GIT_RC=1 run "$script" fmt
[[ $rc -ne 0 ]] || fail "a failed submodule update must fail the step"
! grep -q "cargo " "$work/calls" || fail "cargo ran after a failed submodule update"

RUSTUP_RC=1 run "$script" fmt
[[ $rc -ne 0 ]] || fail "a failed component install must fail the step"
! grep -q "cargo " "$work/calls" || fail "cargo ran after a failed component install"

echo "ok: 3 rust-check cases"
