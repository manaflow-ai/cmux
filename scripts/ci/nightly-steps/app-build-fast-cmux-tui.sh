#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Build fast arm64 cmux-tui client". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
cd cmux-tui
unset CMUX_GHOSTTY_SRC
CMUX_TUI_BUILD_COMMIT="$(git -C .. rev-parse HEAD)"
CMUX_TUI_GHOSTTY_COMMIT="$(git -C ../ghostty-next rev-parse HEAD)"
export CMUX_TUI_BUILD_COMMIT CMUX_TUI_GHOSTTY_COMMIT
cargo build -p cmux-tui --bin cmux-tui --bin cmux-tui-host --release --locked --target aarch64-apple-darwin
# The terminal holder, installed beside cmux-tui (its own invocation: std and libc only).
cargo build -p cmux-holder --bin cmux-holder --release --locked --target aarch64-apple-darwin
cargo build -p acpmux --bin acpmux --release --locked --target aarch64-apple-darwin
binary="target/aarch64-apple-darwin/release/cmux-tui"
test -x "$binary"
probe="$($binary remote-probe --json)"
PROBE="$probe" EXPECTED_COMMIT="$CMUX_TUI_BUILD_COMMIT" python3 - <<'PY'
import json
import os

probe = json.loads(os.environ["PROBE"])
expected = os.environ["EXPECTED_COMMIT"]
if probe.get("build_identity") != expected:
    raise SystemExit(
        f"cmux-tui build identity {probe.get('build_identity')!r} != {expected!r}"
    )
if "wireguard-hub" not in probe.get("capabilities", []):
    raise SystemExit("fast cmux-tui client lacks wireguard-hub capability")
PY
