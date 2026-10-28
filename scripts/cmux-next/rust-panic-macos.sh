#!/usr/bin/env bash
# The macOS half of the Q10 Rust panic run (plans/cmux-next/stability-DESIGN.md, Q10), as a fleet step:
#   cmux-ci run --class isolated --script scripts/cmux-next/rust-panic-macos.sh --ref SHA --key KEY \
#     --artifact .build/artifacts/rust-panic-macos.jsonl --artifact .build/artifacts/rust-panic-macos.md
# It runs the CI panic ratchet's clippy command (cmux-tui.yml "Rust panic ratchet") on macOS, where the
# `#[cfg(target_os = "macos")]` code compiles, and writes:
#   .build/artifacts/rust-panic-macos.jsonl  the clippy --message-format=json output
#   .build/artifacts/rust-panic-macos.md     rust_panic_ratchet.py --report md of this run alone
# Merge it with the Linux run (rbx or a Testbox) on any machine, read-only:
#   python3 scripts/cmux-next/rust_panic_ratchet.py --clippy-json linux=linux.jsonl \
#     --clippy-json macos=rust-panic-macos.jsonl --report md
# The merged report's "Hits only the macos run saw" table lists the macOS-only hits.
# The step is red only when clippy did not finish (a compile error, a missing toolchain); a ratchet RED
# against rust-panic-baseline.json is a finding (the baseline is the Linux run's), printed in the log.
set -euo pipefail
if [[ -z "${CMUX_CI_STEP_KEY:-}" ]]; then
  cat >&2 <<'MSG'
rust-panic-macos.sh runs cargo clippy and runs only as a fleet step:
  cmux-ci run --class isolated --script scripts/cmux-next/rust-panic-macos.sh --ref SHA --key KEY \
    --artifact .build/artifacts/rust-panic-macos.jsonl --artifact .build/artifacts/rust-panic-macos.md
MSG
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo "error: rust-panic-macos.sh is the macOS run; on Linux run the clippy command of its header directly" >&2
  exit 2
fi
umask 022
root="$(pwd -P)"
artifacts="$root/.build/artifacts"
mkdir -p "$artifacts"
jsonl="$artifacts/rust-panic-macos.jsonl"
md="$artifacts/rust-panic-macos.md"
# ghostty-vt-sys builds libghostty-vt from the ghostty-next submodule, which a step checkout leaves empty.
if ! git -C "$root" submodule update --init --depth 1 ghostty-next; then
  echo "error: git submodule update --init ghostty-next failed; no cargo command ran" >&2
  exit 3
fi
cd "$root/cmux-tui"
if [[ "${CMUX_FLEET_WORKER_TRUSTED:-0}" == 1 ]]; then
  # shellcheck source=scripts/ci/fleet-rust-cache.sh
  source "$root/scripts/ci/fleet-rust-cache.sh"
  CARGO_TARGET_DIR="$(fleet_rust_target_dir cmux-tui-panic "" "$PWD")"
else
  CARGO_TARGET_DIR="$root/.build/rust-panic-target"
fi
export CARGO_TARGET_DIR
mkdir -p "$CARGO_TARGET_DIR"
# A step's RUSTUP_HOME installs the pinned toolchain without its listed components; from this
# directory rust-toolchain.toml selects the toolchain, and its own cargo finds cargo-clippy.
rustup component add clippy >&2 || { echo "error: rustup component add clippy failed; no cargo command ran" >&2; exit 3; }
toolchain_cargo="$(rustup which cargo)" || { echo "error: rustup which cargo failed" >&2; exit 3; }
toolchain_bin="$(dirname "$toolchain_cargo")"
export PATH="$toolchain_bin:$PATH"
echo "rust toolchain: $(rustup show active-toolchain); cargo target: $CARGO_TARGET_DIR"
ratchet=(python3 "$root/scripts/cmux-next/rust_panic_ratchet.py")
read -r -a flags <<<"$("${ratchet[@]}" --flags)"
clippy_rc=0
cargo clippy --workspace --lib --bins --locked --message-format=json -- "${flags[@]}" >"$jsonl" || clippy_rc=$?
echo "clippy: exit $clippy_rc, $(wc -l <"$jsonl" | tr -d ' ') JSON lines in $jsonl"
ratchet_rc=0
"${ratchet[@]}" --repo "$root" --clippy-json "macos=$jsonl" --report md >"$md" || ratchet_rc=$?
cat "$md"
case "$ratchet_rc" in
  0) echo "ratchet: macOS run within rust-panic-baseline.json" ;;
  1) echo "ratchet: macOS run above rust-panic-baseline.json (the Linux baseline); merge with the Linux run for the macOS-only hits" ;;
  *) echo "error: the ratchet could not read the macOS clippy run (exit $ratchet_rc)" >&2 ;;
esac
if [[ "$clippy_rc" -ne 0 ]]; then
  exit "$clippy_rc"
fi
if [[ "$ratchet_rc" -gt 1 ]]; then
  exit "$ratchet_rc"
fi
