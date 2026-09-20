#!/usr/bin/env bash
# The CI Release check is universal unless a maintainer opts into arm64, and
# nightly never takes that option.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVER="$ROOT_DIR/scripts/ci/release-build-archs.sh"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"
NIGHTLY_FILE="$ROOT_DIR/.github/workflows/nightly.yml"

expect() {
  local input="$1" want="$2" got
  got="$("$RESOLVER" "$input")"
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: '$input' resolved to '$got', expected '$want'"
    exit 1
  fi
}

expect "" "arm64 x86_64"
expect "default" "arm64 x86_64"
expect "universal" "arm64 x86_64"
expect "arm64" "arm64"
if [[ "$("$RESOLVER")" != "arm64 x86_64" ]]; then
  echo "FAIL: no argument must resolve to the universal build"
  exit 1
fi

for bad in "x86_64" "arm64 x86_64" "ARM64" "arm64;rm -rf /"; do
  if "$RESOLVER" "$bad" >/dev/null 2>&1; then
    echo "FAIL: '$bad' must be rejected, not silently narrowed or widened"
    exit 1
  fi
done

if ! awk '
  /^  release-build:/ { in_job=1; next }
  in_job && /^  [a-zA-Z0-9_-]+:/ { in_job=0 }
  in_job && /scripts\/ci\/release-build-archs\.sh/ { saw_resolver=1 }
  in_job && /ARCHS="\$RELEASE_ARCHS"/ { saw_build=1 }
  in_job && /ARCHS="arm64/ { saw_literal=1 }
  END { exit !(saw_resolver && saw_build && !saw_literal) }
' "$CI_FILE"; then
  echo "FAIL: release-build must take its architectures from scripts/ci/release-build-archs.sh"
  exit 1
fi

if grep -n -E 'CI_RELEASE_BUILD_ARCHS|release-build-archs\.sh|release_archs' "$NIGHTLY_FILE"; then
  echo "FAIL: nightly builds what ships and must stay universal unconditionally"
  exit 1
fi

echo "PASS: the CI Release check defaults to universal, arm64 is opt-in, and nightly cannot be narrowed"
