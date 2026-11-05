#!/usr/bin/env bash
# Regenerates src/generated.rs from openapi.json, the selection of
# cmux-platform's spec this crate vendors (tags.txt). CI runs this and fails
# when the checked-in file changes. To take a newer platform spec, run
# scripts/update-spec.sh instead; it rewrites openapi.json, then this file.
set -euo pipefail
crate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$crate/../../.." && pwd)"
cargo run --locked --quiet \
  --manifest-path "$repo/workers/cmux-vm/cli/Cargo.toml" -p cmux-vm-codegen -- \
  --spec "$crate/openapi.json" \
  --tags "$crate/tags.txt" \
  --out "$crate/src/generated.rs" \
  --label "cmux-platform openapi.json at $(cat "$crate/PLATFORM_REF")" \
  --script "cmux-tui/crates/cmux-cloud-client/scripts/regenerate.sh" \
  --panicking-new omit
