#!/usr/bin/env bash
# cmux-tui's Rust checks on a macOS fleet host, as a cmux-ci step:
#   cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --ref SHA --key KEY \
#     --arg MODE [--arg TEST_FILTER]
# MODE: fmt (cargo fmt --check), clippy (-D warnings), test [FILTER], or all [FILTER].
# The fleet may run cargo through cmux-ci (coordinator, 2026-10-04); a developer
# Mac never runs it (the laptop and the minis by hand stay off limits), so
# outside a step (CMUX_CI_STEP_KEY) it refuses. The target dir is the step's
# own (.build/cmux-tui-rust-target in its checkout), and files are created
# with umask 022.
set -euo pipefail
if [[ -z "${CMUX_CI_STEP_KEY:-}" ]]; then
  cat >&2 <<'MSG'
cmux-tui-rust-check.sh runs cargo and runs only as a fleet step:
  cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --ref SHA --key KEY --arg all
MSG
  exit 2
fi
mode="${1:-}"
filter="${2:-}"
case "$mode" in fmt|clippy|test|all) ;; *) echo "usage: cmux-tui-rust-check.sh fmt|clippy|test|all [TEST_FILTER]" >&2; exit 2 ;; esac
if [[ -n "$filter" && ! "$filter" =~ ^[A-Za-z0-9_:.-]{1,200}$ ]]; then
  echo "error: TEST_FILTER must be one Rust test-name substring (letters, digits, _ : . -)" >&2
  exit 2
fi
umask 022
root="$(pwd -P)"
export CARGO_TARGET_DIR="$root/.build/cmux-tui-rust-target"
# The step's checkout has empty submodules; ghostty-vt-sys builds
# libghostty-vt from ghostty-next (2026-10-05, step ee99e05f: "missing
# build.zig"). Initialize the pinned commits shallowly before any cargo.
if ! git -C "$root" submodule update --init --depth 1 ghostty ghostty-next; then
  echo "error: git submodule update --init ghostty ghostty-next failed; no cargo command ran" >&2
  exit 3
fi
cd "$root/cmux-tui"
# The step's own RUSTUP_HOME auto-installed the pinned toolchain WITHOUT the
# components rust-toolchain.toml lists (rustup 1.29.1, 2026-10-05: `cargo fmt`
# failed with "no such command"). Install them explicitly; from this directory
# the toolchain file selects the toolchain.
if ! rustup component add clippy rustfmt; then
  echo "error: rustup component add clippy rustfmt failed; no cargo command ran" >&2
  exit 3
fi
echo "rust toolchain: $(rustup show active-toolchain)"
rustup component list --installed
# Run the pinned toolchain's own cargo, whose bin dir also holds cargo-fmt and
# cargo-clippy. The cargo on the step's PATH is not always the rustup proxy;
# then `cargo fmt` looks for cargo-fmt on PATH only (2026-10-05: step fafed265
# on cmux7 had rustfmt installed and still failed with "no such command").
toolchain_cargo="$(rustup which cargo)" || { echo "error: rustup which cargo failed" >&2; exit 3; }
export PATH="$(dirname "$toolchain_cargo"):$PATH"
echo "cargo: $toolchain_cargo"
if [[ "$mode" == fmt || "$mode" == all ]]; then
  cargo fmt --all --check
fi
if [[ "$mode" == clippy || "$mode" == all ]]; then
  cargo clippy --workspace --all-targets --locked -- -D warnings
fi
if [[ "$mode" == test || "$mode" == all ]]; then
  cargo test --workspace --locked ${filter:+"$filter"}
fi
