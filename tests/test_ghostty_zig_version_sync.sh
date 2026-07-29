#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_HELPER="$ROOT_DIR/scripts/ghostty-zig-version.sh"

if [[ ! -f "$VERSION_HELPER" ]]; then
  echo "missing shared Ghostty Zig version helper: $VERSION_HELPER" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$VERSION_HELPER"

expected="$(
  sed -nE 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
    "$ROOT_DIR/ghostty/build.zig.zon" | head -1
)"
actual="$(ghostty_minimum_zig_version "$ROOT_DIR")"

if [[ -z "$expected" || "$actual" != "$expected" ]]; then
  echo "Ghostty Zig version mismatch: expected '$expected', helper returned '$actual'" >&2
  exit 1
fi

for consumer in \
  "$ROOT_DIR/scripts/install-zig-ci.sh" \
  "$ROOT_DIR/scripts/build-ghostty-cli-helper.sh"; do
  if ! grep -Fq 'ghostty_minimum_zig_version "$REPO_ROOT"' "$consumer"; then
    echo "$(basename "$consumer") does not use the shared Ghostty Zig version" >&2
    exit 1
  fi
done

if ! awk '
  /^  workflow-guard-tests:$/ { in_job = 1; next }
  in_job && /^  [[:alnum:]_-]+:$/ { exit }
  in_job && index($0, "git submodule update --init --depth 1 ghostty") { found = 1 }
  END { exit !found }
' "$ROOT_DIR/.github/workflows/ci.yml"; then
  echo "workflow-guard-tests does not initialize Ghostty before reading its Zig manifest" >&2
  exit 1
fi

tui_workflows=(
  "$ROOT_DIR/.github/workflows/cmux-tui-build-package.yml"
  "$ROOT_DIR/.github/workflows/cmux-tui.yml"
)
count_occurrences() {
  local needle="$1"
  shift
  awk -v needle="$needle" 'index($0, needle) { count++ } END { print count + 0 }' "$@"
}
setup_count="$(count_occurrences 'uses: mlugg/setup-zig@' "${tui_workflows[@]}")"
resolver_count="$(count_occurrences 'id: ghostty-zig-version' "${tui_workflows[@]}")"
helper_count="$(count_occurrences 'bash ./scripts/ghostty-zig-version.sh' "${tui_workflows[@]}")"
version_count="$(
  count_occurrences \
    'version: ${{ steps.ghostty-zig-version.outputs.version }}' \
    "${tui_workflows[@]}"
)"
if [[ "$setup_count" -eq 0 ||
      "$resolver_count" -ne "$setup_count" ||
      "$helper_count" -ne "$setup_count" ||
      "$version_count" -ne "$setup_count" ]]; then
  echo "TUI setup-zig steps do not all derive their version from Ghostty" >&2
  exit 1
fi

echo "PASS: cmux build scripts use Ghostty's declared Zig version ($actual)"
