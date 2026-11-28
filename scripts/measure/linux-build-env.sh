#!/usr/bin/env bash
# Sourced: measure_linux_build_env ROOT puts what building cmux-tui's daemons needs in place on a fleet Linux job
# (infinite-items-linux.sh before it builds; memory_bisect.py before its first probe). Leo, 2026-11-22
# (ask-5b56389121): "i also want us to keep pursuing the ability to have infinite f***ing tabs and workspaces and
# s*** without getting starved of cpu/ram".
measure_linux_build_env() {
  local root="$1"
  # cmux-tui's terminal engine builds from the ghostty-next submodule, which a fast-checks snapshot leaves empty.
  [ -f "$root/ghostty-next/build.zig" ] || [ -n "${CMUX_GHOSTTY_SRC:-}" ] ||
    git -C "$root" submodule update --init --depth 1 ghostty-next || return 1
  # A bare runner (the perf cron's Linux part): the pinned Rust and Zig and the native build tools.
  command -v cargo >/dev/null || (cd "$root" && ./scripts/install-rust-ci.sh) || return 1
  if ! command -v zig >/dev/null && [ -z "${ZIG:-}${CMUX_ZIG:-}" ]; then
    # The pinned Zig is ghostty-next's (the classic submodule is not checked out). A runner without passwordless
    # sudo gets it under RUNNER_TEMP, published only through GITHUB_ENV: read CMUX_ZIG back from a file of our own.
    local zig_env zig_line
    zig_env="$(mktemp)"
    (cd "$root" && GHOSTTY_ZIG_SOURCE=ghostty-next GITHUB_ENV="$zig_env" GITHUB_PATH=/dev/null ./scripts/install-zig-ci.sh) || { rm -f "$zig_env"; return 1; }
    zig_line="$(grep '^CMUX_ZIG=' "$zig_env" | tail -n 1 || true)"
    rm -f "$zig_env"
    [ -z "$zig_line" ] || export "$zig_line"
  fi
  command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; } || return 1
  export PATH="$HOME/.cargo/bin:$PATH"
}
