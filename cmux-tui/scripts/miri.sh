#!/usr/bin/env bash
# Runs the tests of the cmux NEXT crates that hold unsafe code under Miri, which stops on undefined
# behavior (an out-of-bounds or dangling access, a bad alignment, an invalid value, a data race, a
# leak) where a native run passes by luck.
#
#   cmux-tui/scripts/miri.sh [CRATE...]     no CRATE runs every row of CRATES below
#
# On the fleet: cmux-ci test -- bash cmux-tui/scripts/miri.sh
#
# Miri interprets Rust only. A test that reaches C (a linked library, or a syscall Miri has no
# shim for) cannot run there, and says so with `#[cfg_attr(miri, ignore = "<why>")]`. A crate whose
# unsafe code is all such calls is not listed: NOT_UNDER_MIRI below names it and why.
#
# The toolchain is a pinned nightly (Miri ships only there), installed with its miri and rust-src
# components when absent; MIRI_TOOLCHAIN names another. Tests run through cargo-nextest, one
# process per test in parallel, with scripts/miri-nextest.toml's longer timeouts.
set -uo pipefail

TOOLCHAIN=${MIRI_TOOLCHAIN:-nightly-2026-11-16}
NEXTEST_VERSION=0.9.148
NEXTEST_SHA256=223ba936714cc861a9cdedad5a8eb664dfdd69d6fbdf6cea6aa8184f523290dc

# CRATE|WORKSPACE (from the repository root)|more `cargo miri nextest run` arguments
CRATES=(
  "acpmux-client|cmux-tui|"
  "acpmux-core|cmux-tui|--features allocation-metrics"
  "cmux-rd-ffi|cmux-tui/crates/cmux-app-ffi|"
  "cmux-wg-tun|cmux-tui|"
)

# Crates whose unsafe code Miri cannot reach, and why (checked 2026-11-17 on nightly-2026-11-16):
NOT_UNDER_MIRI=(
  "acpmux: syscalls with no Miri shim (prctl, landlock, seccomp, process_vm_readv, Windows and macOS APIs) and 8,800 tests that spawn processes and daemons"
  "cmux-tui-core: the same: process, pty, signal and Windows job calls, 5,400 tests"
  "cmux-wg, cmux-rd-link: setsockopt and poll on UDP sockets, which Miri has no shim for"
  "cmux-tailnet: calls into libtailscale (Go, linked as C)"
  "cmux-app-host: its allocator and VM run inside QuickJS (C); the rest is prctl, landlock and pre_exec"
  "cmux-rd-host: capture, encode and input through X11, PipeWire, x264 and shared memory"
)

repo=$(cd "$(dirname "$0")/../.." && pwd) || exit 2
config="$repo/cmux-tui/scripts/miri-nextest.toml"

if ! cargo "+$TOOLCHAIN" miri --version >/dev/null 2>&1; then
  rustup toolchain install "$TOOLCHAIN" --profile minimal --component miri,rust-src || exit 2
fi
if [[ "$(cargo nextest --version 2>/dev/null | head -n 1)" != "cargo-nextest $NEXTEST_VERSION "* ]]; then
  bin="${CARGO_HOME:-$HOME/.cargo}/bin"
  archive=$(mktemp) || exit 2
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 --max-time 120 --output "$archive" \
    "https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-$NEXTEST_VERSION/cargo-nextest-$NEXTEST_VERSION-x86_64-unknown-linux-gnu.tar.gz" &&
    echo "$NEXTEST_SHA256  $archive" | sha256sum --check --strict - &&
    mkdir -p "$bin" && tar -xzf "$archive" -C "$bin" cargo-nextest
  code=$?
  rm -f "$archive"
  ((code == 0)) || exit 2
  export PATH="$bin:$PATH"
fi
cargo "+$TOOLCHAIN" miri setup >/dev/null || exit 2

# Isolation off: tests read the clock, the environment and temporary files.
export MIRIFLAGS="${MIRIFLAGS:--Zmiri-disable-isolation}"

summary=()
status=0
for row in "${CRATES[@]}"; do
  IFS='|' read -r crate workspace args <<<"$row"
  if (($#)) && [[ " $* " != *" $crate "* ]]; then
    continue
  fi
  echo "::group::miri $crate"
  start=$SECONDS
  # shellcheck disable=SC2086 # a row's arguments are space-separated words
  (cd "$repo/$workspace" && cargo "+$TOOLCHAIN" miri nextest run --locked -p "$crate" --config-file "$config" $args)
  code=$?
  echo "::endgroup::"
  summary+=("$crate: $( ((code == 0)) && echo passed || echo "FAILED ($code)") in $((SECONDS - start)) s")
  ((code == 0)) || status=1
done
printf '%s\n' "${summary[@]}"
printf 'not under Miri: %s\n' "${NOT_UNDER_MIRI[@]}"
exit "$status"
