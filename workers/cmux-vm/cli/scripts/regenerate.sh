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

# A regenerated client can change a method's signature (cmux#62617 added an
# argument to vms_create_vm), and the crates that call it then stop compiling.
# Compile every crate in the workspace that links the client here, so the
# regeneration and its callers' fix land in one PR. CI's job runs clippy over
# the workspace before this step, so it sets CMUX_VM_REGEN_SKIP_CALLERS=1.
if [[ "${CMUX_VM_REGEN_SKIP_CALLERS:-}" != 1 ]]; then
  if ! cargo check --locked --quiet --workspace --all-targets; then
    echo "regenerate.sh: the regenerated client no longer compiles with its callers; fix the call sites in this change" >&2
    exit 1
  fi
fi
