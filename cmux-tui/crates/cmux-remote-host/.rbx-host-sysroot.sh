#!/usr/bin/env bash
# Runs on rbx inside the cu-integ-host lane: unpack the X11/Wayland/PipeWire/D-Bus dev packages the
# upstream Linux driver links into a private sysroot (no root), then build and test cmux-remote-host.
set -euo pipefail
root="$PWD/.sysroot"
if [ ! -f "$root/.done" ]; then
  mkdir -p "$root/debs"; cd "$root/debs"
  pkgs="libx11-dev libx11-6 libxi-dev libxi6 libxtst-dev libxtst6 libxext-dev libxext6 libxfixes-dev libxfixes3 libxrandr-dev libxrandr2 libxcb1-dev libxcb1 libxau-dev libxau6 libxdmcp-dev libxdmcp6 x11proto-dev libxrender-dev libxrender1 libxkbcommon-dev libxkbcommon0 libpipewire-0.3-dev libpipewire-0.3-0t64 libspa-0.2-dev libdbus-1-dev libdbus-1-3 libwayland-dev libwayland-client0 xorg-sgml-doctools"
  for p in $pkgs; do apt-get download "$p" >/dev/null 2>&1 || echo "skip $p"; done
  for d in *.deb; do dpkg-deb -x "$d" "$root"; done
  cd - >/dev/null; touch "$root/.done"
fi
export PKG_CONFIG_SYSROOT_DIR="$root"
export PKG_CONFIG_PATH="$root/usr/lib/x86_64-linux-gnu/pkgconfig:$root/usr/share/pkgconfig"
export LIBRARY_PATH="$root/usr/lib/x86_64-linux-gnu"
export LD_LIBRARY_PATH="$root/usr/lib/x86_64-linux-gnu"
export BINDGEN_EXTRA_CLANG_ARGS="-I$root/usr/include -I$root/usr/include/x86_64-linux-gnu"
export C_INCLUDE_PATH="$root/usr/include:$root/usr/include/x86_64-linux-gnu"
status=0
echo "=== cargo test --no-default-features"; cargo test --locked --no-default-features || status=1
echo "=== cargo test (driver)"; cargo test --locked || status=1
echo "=== cargo clippy"; cargo clippy --locked --all-targets -- -D warnings || status=1
echo "=== cargo build --release"; cargo build --locked --release && (sha256sum "${CARGO_TARGET_DIR:-target}/release/cmux-remote-host" 2>/dev/null || true) || status=1
echo "=== windows gnu check"; cargo clippy --locked --target x86_64-pc-windows-gnu --all-targets -- -D warnings || status=1
exit $status
