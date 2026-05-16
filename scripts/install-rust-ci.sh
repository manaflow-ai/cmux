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
