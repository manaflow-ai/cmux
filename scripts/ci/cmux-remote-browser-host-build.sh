#!/usr/bin/env bash
# Builds and tests the remote browser host (cmux-tui/crates/cmux-remote-browser-host,
# its own Cargo workspace; plans/cmux-next/remote-tab-r2.md) on a fleet Mac:
#   cmux-ci run --class isolated --script scripts/ci/cmux-remote-browser-host-build.sh \
#     --ref SHA --cef sha256:HEX --artifact .build/artifacts/cmux-remote-browser-host \
#     [--arg=--build-only]
# --build-only compiles the tests (cargo test --no-run) without running them, for
# workers that run builds only (the physical fleet minis).
# Needs CMUX_CI_CEF_DIR: the unpacked CEF fork release (cef_cmux.h API >= 19), either the
# dist folder itself or a folder holding exactly one. Output (fixed path, for --artifact):
#   .build/artifacts/cmux-remote-browser-host   (the release binary, macOS arm64)
# Runs only as a fleet step or job: a developer Mac never runs cargo.
set -euo pipefail
build_only=0
case "${1:-}" in
  "") ;;
  --build-only) build_only=1 ;;
  *) echo "usage: cmux-remote-browser-host-build.sh [--build-only]" >&2; exit 2 ;;
esac
if [[ -z "${CMUX_CI_STEP_KEY:-}" && -z "${CMUX_CI_JOB_VOLUME:-}" ]]; then
  echo "cmux-remote-browser-host-build.sh runs cargo and runs only on the fleet (cmux-ci run)" >&2
  exit 2
fi
cef="${CMUX_CI_CEF_DIR:?CMUX_CI_CEF_DIR must name the unpacked CEF fork release}"
if [[ ! -d "$cef/include" ]]; then
  inner=("$cef"/*/)
  [[ ${#inner[@]} -eq 1 && -d "${inner[0]}include" ]] ||
    { echo "error: $cef holds no CEF dist (include/ missing)" >&2; exit 3; }
  cef="${inner[0]%/}"
fi
grep -q 'cmux_rp_capture_start' "$cef/include/cef_cmux.h" ||
  { echo "error: $cef is not a remote presentation build (no cmux_rp_* in cef_cmux.h)" >&2; exit 3; }
umask 022
root="$(pwd -P)"
crate="$root/cmux-tui/crates/cmux-remote-browser-host"
export CEF_PATH="$cef"
export CARGO_TARGET_DIR="$root/.build/cmux-remote-browser-host-target"
cd "$crate"
echo "rust toolchain: $(rustup show active-toolchain 2>/dev/null || echo unknown)"
echo "CEF_PATH=$CEF_PATH"
# --all-targets runs the lib, bin and integration tests; no doctests until the
# fleet toolchain ships rustdoc with a self-test (hq PR 1406 was reverted by
# hq PR 1411: its cargo symlink ran rustup).
if [[ "$build_only" == 1 ]]; then
  cargo test --locked --all-targets --no-run
else
  cargo test --locked --all-targets
fi
cargo build --release --locked
mkdir -p "$root/.build/artifacts"
cp "$CARGO_TARGET_DIR/release/cmux-remote-browser-host" "$root/.build/artifacts/cmux-remote-browser-host"
ls -l "$root/.build/artifacts/cmux-remote-browser-host"
