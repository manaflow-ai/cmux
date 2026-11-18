#!/usr/bin/env bash
# Fleet entry for the daemon's part of the floating pane look, with no app and no display: builds release
# `cmux-tui` at this checkout (as daemon-registry-start.sh) and runs
# scripts/cmux-next/floating-pane-look.py --daemon-only against it. The driver starts that daemon alone on its own
# default socket, makes a workspace and a split, sends `float-pane` on and off and reads the screen's `floating`
# list, with the same functions as the look's display step (floating-pane-look.sh): a fault in the driver's
# daemon calls shows here, before a step that builds the whole app and holds a display.
#   cmux-ci run --class light --script scripts/measure/floating-pane-look-daemon.sh --ref <sha> --timeout 1800
# Output: one FLOATING-PANE-LOOK line for each reply, then `daemon-only PASS` or `daemon-only FAIL`.
# Exit: the driver's (0 = each call answered as the look needs it, 1 = one did not); cargo's when the build failed.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
# ghostty-vt-sys builds libghostty-vt from the ghostty-next submodule (as daemon-registry-start.sh).
if [[ ! -f "$root/ghostty-next/build.zig" ]]; then
  git -C "$root" submodule update --init --depth 1 ghostty-next
fi
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$root/.build/cmux-tui-rust-target}"
(cd "$root/cmux-tui" && cargo build --release --locked -p cmux-tui --bin cmux-tui)
python3 "$root/scripts/cmux-next/floating-pane-look.py" --tag floatlook \
  --daemon-only "$CARGO_TARGET_DIR/release/cmux-tui"
