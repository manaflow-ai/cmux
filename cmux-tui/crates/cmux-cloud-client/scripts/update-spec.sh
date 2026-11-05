#!/usr/bin/env bash
# Takes cmux-platform's openapi.json at REF (default: main), keeps the groups
# tags.txt names and the schemas they reach, writes openapi.json and
# PLATFORM_REF, and regenerates the client.
#
#   cmux-tui/crates/cmux-cloud-client/scripts/update-spec.sh [REF]
set -euo pipefail
crate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$crate/../../.." && pwd)"
ref="${1:-main}"
sha="$(gh api "repos/manaflow-ai/cmux-platform/commits/$ref" --jq .sha)"
full="$(mktemp)"
trap 'rm -f "$full"' EXIT
gh api "repos/manaflow-ai/cmux-platform/contents/openapi.json?ref=$sha" \
  -H 'Accept: application/vnd.github.raw' >"$full"
printf '%s\n' "$sha" >"$crate/PLATFORM_REF"
cargo run --locked --quiet \
  --manifest-path "$repo/workers/cmux-vm/cli/Cargo.toml" -p cmux-vm-codegen -- \
  --spec "$full" \
  --tags "$crate/tags.txt" \
  --selected-out "$crate/openapi.json" \
  --out "$crate/src/generated.rs" \
  --label "cmux-platform openapi.json at $sha" \
  --script "cmux-tui/crates/cmux-cloud-client/scripts/regenerate.sh"
"$crate/scripts/regenerate.sh"
