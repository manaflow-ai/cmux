#!/usr/bin/env bash
# Output parity of the Linux action export with the Swift one. A fresh action export is a function of
# its generator inputs alone, so judge-action-exports.sh keeps it by their key (--inputs-key REV) in R2;
# the entries are made by the Mac jobs that run the Swift export (the base autofix's action-exports job,
# a feat-cmux-next push's generated files job). When HEAD's key has one, this compares it byte for byte
# with the Linux export of HEAD (regenerate-action-exports-linux.sh: the Swift export code, built on Linux) and puts the checkout
# back. Prints parity=match|mismatch|unknown for $GITHUB_OUTPUT; a mismatch also prints the diff and a
# warning, and the Linux generated-files job then gives no verdict, so the Mac job runs (the fallback).
# Usage: scripts/cmux-next/generated-parity-linux.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(git rev-parse --show-toplevel)"
cd "$root"
exports=(plans/cmux-next/action-surfaces.json plans/cmux-next/action-catalog.json plans/cmux-next/actions.md plans/cmux-next/links.json)
r2_url="${CMUX_ACTION_EXPORTS_R2_URL-https://ci-cache-next.cmux.com}"
temp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/generated-parity.XXXXXX")"
trap 'git checkout -q HEAD -- "${exports[@]}" 2>/dev/null || true; rm -rf "$temp" "$temp/out.patch"' EXIT
key="$("$here/judge-action-exports.sh" --inputs-key HEAD 2>/dev/null || true)"
[[ -n "$key" && -n "$r2_url" ]] || { echo "parity=unknown"; exit 0; }
CI_CACHE_R2_PUBLIC_URL="$r2_url" CI_CACHE_R2_NAMESPACE=cmux-next-action-exports \
  CI_CACHE_R2_BUCKET="${CI_CACHE_R2_BUCKET:-cmux-ci-cache-next}" GITHUB_OUTPUT="" \
  "$here/../ci/r2-cache.sh" restore "$temp/mac" "v1.$key" > "$temp/r2.log" 2>&1 || true
if [[ ! -f "$temp/mac/.complete" ]]; then
  echo "no Swift-made action export kept for inputs key ${key:0:12}: parity not checked here" >&2
  echo "parity=unknown"
  exit 0
fi
"$here/regenerate-action-exports-linux.sh" "$temp/out" >&2
differ=()
for file in "${exports[@]}"; do
  [[ -f "$temp/mac/$file" ]] || continue
  cmp -s "$temp/mac/$file" "$file" || { differ+=("$file"); diff -u "$temp/mac/$file" "$file" | head -60 >&2 || true; }
done
if ((${#differ[@]})); then
  echo "::warning title=Linux generated files: parity::the Linux action export differs from the Swift export kept for inputs key ${key:0:12}: ${differ[*]}; the Mac job decides this run" >&2
  echo "parity=mismatch"
else
  echo "the Linux action export equals the Swift export kept for inputs key ${key:0:12}" >&2
  echo "parity=match"
fi
