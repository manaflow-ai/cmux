#!/usr/bin/env bash
# regenerate-action-exports.sh's contract, off the Mac: rewrites plans/cmux-next/action-surfaces.json,
# action-catalog.json, actions.md's generated block and links.json in place from the Rust catalog
# (export-action-surfaces-linux.sh, at the catalog commit app-ffi-pin.json names, which is what the
# Swift export reads) and the deep link sources (export-settings-links-linux.sh --only links), and
# copies the ones that changed into OUT at their repository paths, with "regenerated: PATH" lines.
# The Linux generated-files job (cmux-next.yml generated-files-linux) passes it to
# base-autofix-exports-pack.sh as CMUX_BASE_EXPORTS_REGENERATE_ACTIONS: it needs cargo only, where
# regenerate-action-exports-linux.sh (the autofix workflows' Linux regeneration) builds CmuxNextActions' Swift
# and needs a Swift 6.2 toolchain the job does not have.
# Usage: scripts/cmux-next/regenerate-action-exports-catalog-linux.sh OUT
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$(mkdir -p "${1:?usage: $0 OUT}" && cd "$1" && pwd)"
root="$(git rev-parse --show-toplevel)"
cd "$root"
exports=(plans/cmux-next/action-surfaces.json plans/cmux-next/action-catalog.json plans/cmux-next/actions.md plans/cmux-next/links.json)
"$here/export-action-surfaces-linux.sh"
"$here/export-settings-links-linux.sh" --only links
for file in "${exports[@]}"; do
  rm -f -- "$out/$file"
  git diff --quiet -- "$file" && continue
  mkdir -p "$out/$(dirname "$file")"
  cp "$file" "$out/$file"
  echo "regenerated: $file"
done
