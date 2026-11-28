#!/usr/bin/env bash
# Run a cargo test selection for x86_64-pc-windows-gnu on Linux, under Wine.
#
# usage: scripts/ci/cargo-test-wine.sh <cargo test args...>
#   e.g. (from cmux-tui/) ../scripts/ci/cargo-test-wine.sh -p cmux-tui-platform --lib platform::tests:: -- --test-threads=1
#
# The Windows tests that do not need a real Windows security model (owner-only
# DACLs, integrity levels, job-object process reads, another user's SID) pass
# under Wine on a Linux runner, so a unix-only change shows red on a Linux box
# in minutes instead of only on a dispatched Windows runner. What Wine cannot
# run stays on test (windows) in cmux-tui.yml.
#
# The test selection goes through cargo-test-selected.sh, so a selector that
# matches nothing is red. The target and the Wine runner are added here; pass
# neither. Needs wine (wine64), the MinGW toolchain and the Rust target
# x86_64-pc-windows-gnu; installing them is the caller's step.
# Test: scripts/cmux-next/tests/cargo-test-wine.test.sh.
set -euo pipefail

if [[ $# -eq 0 || "$1" == "--" ]]; then
  echo "usage: cargo-test-wine.sh <cargo test args...> (a test selection is required)" >&2
  exit 2
fi

wine=${CMUX_WINE:-}
if [[ -z "$wine" ]]; then
  for candidate in wine wine64; do
    if command -v "$candidate" >/dev/null 2>&1; then
      wine=$candidate
      break
    fi
  done
fi
if [[ -z "$wine" ]]; then
  echo "::error::cargo-test-wine.sh: no wine on PATH (apt-get install wine64), or set CMUX_WINE" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# A private prefix per run directory: a shared ~/.wine from another job or user
# can hold a half-created prefix, and wineboot then waits on its lock.
export WINEPREFIX=${WINEPREFIX:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cmux-wine-prefix}
# No debug channels (the default floods the log with fixme lines), and no Mono or
# Gecko install prompt: the tests are console programs.
export WINEDEBUG=${WINEDEBUG:--all}
export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-mscoree,mshtml=}
export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUNNER=$wine

# Create the prefix once, bounded: a first test run would otherwise pay for it
# inside its own per-test time.
if [[ ! -f "$WINEPREFIX/system.reg" ]]; then
  mkdir -p "$WINEPREFIX"
  bash "$(dirname "${BASH_SOURCE[0]}")/timeout.sh" 300 "${wine}boot" -i >/dev/null 2>&1 || bash "$(dirname "${BASH_SOURCE[0]}")/timeout.sh" 300 "$wine" wineboot -i >/dev/null 2>&1 || {
    echo "::error::cargo-test-wine.sh: wineboot could not create $WINEPREFIX" >&2
    exit 1
  }
fi

exec "$script_dir/cargo-test-selected.sh" --target x86_64-pc-windows-gnu "$@"
