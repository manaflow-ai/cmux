#!/usr/bin/env bash
# Check the lockfile marker baked into VM runner guest images. A miss leaves the workflow's Actions cache restore/save
# enabled. The marker contains one SHA-256 per lockfile, so a stale image cannot hide a package-cache change.
set -euo pipefail

[[ "${1:-}" == check && $# -ge 3 ]] || {
  echo "usage: fsr-bun-cache.sh check MARKER_NAME LOCKFILE..." >&2
  exit 2
}
marker_name="$2"
shift 2
workspace="${GITHUB_WORKSPACE:-$PWD}"
marker="$HOME/.bun/install/cache/.cmux-prefilled/$marker_name.sha256"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for path in "$@"; do
  file="$workspace/$path"
  [[ -f "$file" ]] || continue
  sha256sum "$file" | awk -v p="$path" '{ print $1 "  " p }' >> "$tmp"
done

hit=false
if [[ -s "$tmp" && -s "$marker" ]] && cmp -s "$tmp" "$marker"; then
  hit=true
fi
printf 'fsr-bun-cache marker=%s hit=%s\n' "$marker_name" "$hit"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'hit=%s\n' "$hit" >> "$GITHUB_OUTPUT"
fi
