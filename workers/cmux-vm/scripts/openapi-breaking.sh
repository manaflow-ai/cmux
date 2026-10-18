#!/usr/bin/env bash
# Fails when workers/cmux-vm/openapi.json breaks clients generated from the
# version on a base branch or commit (removed endpoints or fields, new required
# inputs, narrowed types), using a pinned, checksum-verified oasdiff release.
# ACCEPT_BREAKING=true reports breaking changes without failing.
#
#   bash scripts/openapi-breaking.sh <base-branch-or-commit>
set -euo pipefail
cd "$(dirname "$0")/.."
base_ref="${1:?usage: openapi-breaking.sh <base-branch-or-commit>}"

OASDIFF_VERSION=1.32.1
OASDIFF_SHA256=7c8939fc49b75ee11fec66a5b83b37a2fca6aee109fed85013b1ba2ac2a1ee7f

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ "$base_ref" =~ ^0+$ ]]; then base_ref=feat-cmux-next; fi
fetch_ref="refs/heads/${base_ref}"
if [[ "$base_ref" =~ ^[0-9a-f]{40}$ ]]; then fetch_ref="$base_ref"; fi
git fetch --quiet --depth=1 origin "$fetch_ref"
if ! git show "FETCH_HEAD:workers/cmux-vm/openapi.json" > "$work/base.json" 2>/dev/null; then
  echo "base branch ${base_ref} has no workers/cmux-vm/openapi.json; nothing to compare"
  exit 0
fi

archive="oasdiff_${OASDIFF_VERSION}_linux_amd64.tar.gz"
curl -fsSL --retry 3 -o "$work/$archive" "https://github.com/oasdiff/oasdiff/releases/download/v${OASDIFF_VERSION}/${archive}"
echo "${OASDIFF_SHA256}  $work/$archive" | sha256sum -c --quiet
tar -xzf "$work/$archive" -C "$work" oasdiff

if "$work/oasdiff" breaking "$work/base.json" openapi.json --fail-on ERR; then
  echo "openapi.json: no breaking change against ${base_ref}"
  exit 0
fi
if [ "${ACCEPT_BREAKING:-false}" = "true" ]; then
  echo "openapi.json breaks clients of ${base_ref}; accepted by the cmux-vm-breaking-change-ok label"
  exit 0
fi
echo "openapi.json breaks clients of ${base_ref}. Make the change additive, or add the label cmux-vm-breaking-change-ok if it is deliberate." >&2
exit 1
