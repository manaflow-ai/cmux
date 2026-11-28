#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain stable
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

rustup target add aarch64-apple-darwin x86_64-apple-darwin
cargo --version
rustc --version

if [ -f Native/DiffSidecar/rust-toolchain.toml ]; then
  DIFF_RUST_TOOLCHAIN="$(awk -F '"' '/^[[:space:]]*channel[[:space:]]*=/{print $2; exit}' Native/DiffSidecar/rust-toolchain.toml)"
  rustup toolchain install "$DIFF_RUST_TOOLCHAIN" --profile minimal --component clippy,rustfmt
  rustup target add --toolchain "$DIFF_RUST_TOOLCHAIN" aarch64-apple-darwin x86_64-apple-darwin
  rustup run "$DIFF_RUST_TOOLCHAIN" cargo --version
  rustup run "$DIFF_RUST_TOOLCHAIN" rustc --version
fi
