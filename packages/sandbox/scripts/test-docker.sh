#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RUST_VERSION="${RUST_VERSION:-1.91.0}"

echo "Running cargo tests inside rust:${RUST_VERSION}-bullseye"
docker run --rm \
  -v "${ROOT_DIR}:/cmux" \
  -w /cmux/packages/sandbox \
  "rust:${RUST_VERSION}-bullseye" \
  bash -lc "apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev clang ca-certificates curl && if ! command -v cargo >/usr/local/cargo/bin/cargo; then curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain ${RUST_VERSION} --profile minimal; fi; source /usr/local/cargo/env && cargo test"
