#!/usr/bin/env bash
# p05-ipc-137 acceptance numbers on a macOS fleet host: the journal writer's
# read_barrier_qos tests in release, the ignored bench included (barrier wait
# p50/p99/max under utility hogs on every core, without and with QoS donation,
# from a user-initiated and a user-interactive thread, and the overrides each
# row started). A measurement, not a gate:
#   cmux-ci run --class isolated --script scripts/measure/read-barrier-qos.sh --ref SHA
# It runs cargo, so only as a fleet step (CMUX_CI_STEP_KEY), never on a developer Mac.
set -euo pipefail
if [[ -z "${CMUX_CI_STEP_KEY:-}" ]]; then
  echo "read-barrier-qos.sh runs cargo and runs only as a fleet step (cmux-ci run)" >&2
  exit 2
fi
umask 022
root="$(git rev-parse --show-toplevel)"
export CARGO_TARGET_DIR="$root/.build/cmux-tui-rust-target"
# The step's checkout has empty submodules; ghostty-vt-sys builds libghostty-vt
# from ghostty-next (as scripts/ci/cmux-tui-rust-check.sh).
[[ -f "$root/ghostty-next/build.zig" ]] || git -C "$root" submodule update --init --depth 1 ghostty-next
cd "$root/cmux-tui"
toolchain_cargo="$(rustup which cargo)"
PATH="$(dirname "$toolchain_cargo"):$PATH"
export PATH
echo "host: $(sw_vers -productVersion 2>/dev/null || uname -sr) $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"
cargo test --locked -p cmux-tui-core --release --lib read_barrier_qos -- --include-ignored --nocapture --test-threads 1
