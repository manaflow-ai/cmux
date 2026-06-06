#!/usr/bin/env bash
# Ensures CI installs Bun through the retrying repo-owned installer, pinned to
# an explicit semver, instead of relying on setup-bun's short download retry.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

found_setup=0
while IFS= read -r workflow; do
  if grep -n 'uses: oven-sh/setup-bun@' "$workflow"; then
    echo "FAIL: $workflow must use scripts/ci/setup-bun-with-retry.sh instead of oven-sh/setup-bun" >&2
    exit 1
  fi

  while IFS=: read -r line_number _; do
    found_setup=1
    line="$(sed -n "${line_number}p" "$workflow")"
    if ! grep -Eq 'setup-bun-with-retry\.sh[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+([[:space:]]|$)' <<<"$line"; then
      echo "FAIL: $workflow:$line_number setup-bun-with-retry.sh must pin Bun to an explicit semver"
      exit 1
    fi
  done < <(grep -n 'setup-bun-with-retry\.sh' "$workflow" || true)
done < <(git -C "$ROOT_DIR" ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')

if [[ "$found_setup" -eq 0 ]]; then
  echo "FAIL: no setup-bun-with-retry.sh workflow calls found" >&2
  exit 1
fi

echo "PASS: Bun setup uses retrying semver-pinned installer"
