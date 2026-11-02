#!/usr/bin/env bash
# Builds and tests cmux-remote-host on a Debian or Ubuntu box (a Testbox, a VM):
# installs the system libraries upstream Cua Driver links, runs the tests with
# and without the driver, builds the release binary, and checks the Windows GNU
# target. Not a CI job: run it yourself, e.g.
#   cd cmux-tui/crates/cmux-remote-host && cmux-ci test --setup none --artifact /tmp/rh -- scripts/verify-linux.sh
# Results and the resolved Cargo.lock go to $FAST_CHECKS_OUT when it is set.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${FAST_CHECKS_OUT:-}"
SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo"
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq --no-install-recommends \
  pkg-config clang libclang-dev libx11-dev libxi-dev libxtst-dev libxext-dev libxfixes-dev libxrandr-dev \
  libxcb1-dev libxkbcommon-dev libpipewire-0.3-dev libdbus-1-dev libwayland-dev gcc-mingw-w64-x86-64 >/dev/null
command -v rustup >/dev/null || { curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none; . "$HOME/.cargo/env"; }
rustup show active-toolchain >/dev/null 2>&1 || rustup toolchain install "$(sed -n 's/^channel = "\(.*\)"/\1/p' rust-toolchain.toml)" --profile minimal
rustup target add x86_64-pc-windows-gnu >/dev/null
step() { echo "=== $*"; "$@"; }
status=0
step cargo test --no-default-features || status=1
step cargo test || status=1
step cargo build --release || status=1
step cargo check --target x86_64-pc-windows-gnu --no-default-features --all-targets || status=1
step cargo check --target x86_64-pc-windows-gnu --all-targets || status=1
if [ -n "$out" ]; then
  cp Cargo.lock "$out/Cargo.lock" || true
  [ -f target/release/cmux-remote-host ] && cp target/release/cmux-remote-host "$out/" && sha256sum target/release/cmux-remote-host | tee "$out/cmux-remote-host.sha256"
  cargo tree -e normal --prefix none 2>/dev/null | sort -u > "$out/dependency-tree.txt" || true
  ldd target/release/cmux-remote-host > "$out/ldd.txt" 2>&1 || true
fi
exit $status
