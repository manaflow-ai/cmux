#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v rustup >/dev/null 2>&1; then
  # To a file first: a retried transfer never pipes a partial installer into sh.
  rustup_init="$(mktemp "${TMPDIR:-/tmp}/rustup-init.XXXXXX")"
  trap 'rm -f "$rustup_init"' EXIT
  curl --proto '=https' --tlsv1.2 -sSf --retry 3 --retry-all-errors --connect-timeout 20 --max-time 120 \
    -o "$rustup_init" https://sh.rustup.rs
  # A distro rustc in /usr/bin would make rustup-init print "cannot install while Rust is installed" before going
  # on under -y, a line that reads as the failure in a red job's log; skip that check.
  RUSTUP_INIT_SKIP_PATH_CHECK=yes sh "$rustup_init" -y --profile minimal --default-toolchain stable
  rm -f "$rustup_init"
  export PATH="$HOME/.cargo/bin:$PATH"
fi

if [ -n "${BASH_ENV:-}" ]; then
  echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> "$BASH_ENV"
fi

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$HOME/.cargo/bin" >> "$GITHUB_PATH"
fi

if ! rustup show active-toolchain >/dev/null 2>&1; then
  rustup default stable
fi

# shellcheck source=scripts/lib/rust-targets.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/rust-targets.sh"
ensure_rust_targets aarch64-apple-darwin x86_64-apple-darwin
cargo --version
rustc --version

if [ -f Native/DiffSidecar/rust-toolchain.toml ]; then
  DIFF_RUST_TOOLCHAIN="$(awk -F '"' '/^[[:space:]]*channel[[:space:]]*=/{print $2; exit}' Native/DiffSidecar/rust-toolchain.toml)"
  rustup toolchain install "$DIFF_RUST_TOOLCHAIN" --profile minimal --component clippy,rustfmt
  ensure_rust_targets --toolchain "$DIFF_RUST_TOOLCHAIN" aarch64-apple-darwin x86_64-apple-darwin
  rustup run "$DIFF_RUST_TOOLCHAIN" cargo --version
  rustup run "$DIFF_RUST_TOOLCHAIN" rustc --version
fi
