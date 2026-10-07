#!/usr/bin/env bash
# Regenerates crates/cmux-vm-client/src/generated.rs from the cmux VM OpenAPI
# document. CI runs this and fails if the checked-in file changes.
#
# The document is S1's workers/cmux-vm/openapi.json once that lands on this
# branch; until then it is fixtures/openapi.json, a snapshot of the S1 API.
set -euo pipefail
cli_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$cli_root"
spec="fixtures/openapi.json"
cargo run --locked --quiet -p cmux-vm-codegen -- \
  --spec "$spec" \
  --out crates/cmux-vm-client/src/generated.rs \
  --label "workers/cmux-vm/cli/$spec"
