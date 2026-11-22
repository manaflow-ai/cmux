#!/usr/bin/env bash
# Regenerates crates/cmux-vm-client/src/generated.rs and generated_raw.rs from the cmux VM OpenAPI
# document. CI runs this and fails if the checked-in file changes.
#
# The document is workers/cmux-vm/openapi.json, which the Worker generates
# from its Effect HttpApi definition (`bun run openapi` in workers/cmux-vm).
set -euo pipefail
cli_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$cli_root"
spec="../openapi.json"
cargo run --locked --quiet -p cmux-vm-codegen -- \
  --spec "$spec" \
  --out crates/cmux-vm-client/src/generated.rs \
  --raw-out crates/cmux-vm-client/src/generated_raw.rs \
  --label "workers/cmux-vm/openapi.json"
