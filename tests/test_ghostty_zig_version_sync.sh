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

for compatible_version in \
  "$actual" \
  "${actual%.*}.$((10#${actual##*.} + 1))" \
  "${actual}-dev.1+test"; do
  if ! ghostty_zig_version_is_compatible "$compatible_version" "$actual"; then
    echo "Ghostty-compatible Zig version rejected: $compatible_version >= $actual" >&2
    exit 1
  fi
done

IFS=. read -r actual_major actual_minor actual_patch <<< "$actual"
incompatible_versions=(
  "$((10#$actual_major + 1)).${actual_minor}.${actual_patch}"
  "${actual_major}.$((10#$actual_minor + 1)).${actual_patch}"
)
if (( 10#$actual_patch > 0 )); then
  incompatible_versions+=("${actual_major}.${actual_minor}.$((10#$actual_patch - 1))")
fi
incompatible_versions+=("invalid")
for incompatible_version in "${incompatible_versions[@]}"; do
  if ghostty_zig_version_is_compatible "$incompatible_version" "$actual"; then
    echo "Incompatible Zig version accepted: $incompatible_version for $actual" >&2
    exit 1
  fi
done

for consumer in \
  "$ROOT_DIR/scripts/install-zig-ci.sh" \
  "$ROOT_DIR/scripts/build-ghostty-cli-helper.sh" \
  "$ROOT_DIR/cmux-tui/apps/macos/TerminalBytesDemo/run-demo.sh"; do
  if ! grep -Eq 'ghostty_minimum_zig_version[[:space:]]+' "$consumer"; then
    echo "$(basename "$consumer") does not use the shared Ghostty Zig version" >&2
    exit 1
  fi
done

# Every workflow command that reads Ghostty's Zig manifest must initialize the
# submodule earlier in the same job. Scan all workflows so a new consumer is
# covered automatically instead of maintaining a list of job names.
python3 "$ROOT_DIR/tests/test_check_ghostty_zig_workflows.py"

python3 \
  "$ROOT_DIR/tests/check_ghostty_zig_workflows.py" \
  --require-setup-zig \
  "$ROOT_DIR/.github/workflows"

if ! grep -Fq 'source "$SCRIPT_DIR/ghostty-zig-version.sh"' "$ROOT_DIR/scripts/setup.sh" ||
   ! grep -Fq 'ghostty_minimum_zig_version "$PROJECT_DIR"' "$ROOT_DIR/scripts/setup.sh" ||
   ! grep -Fq 'ZIG_ACTUAL="$(zig version)"' "$ROOT_DIR/scripts/setup.sh" ||
   ! grep -Fq 'ghostty_zig_version_is_compatible "$ZIG_ACTUAL" "$ZIG_REQUIRED"' "$ROOT_DIR/scripts/setup.sh"; then
  echo "setup.sh does not validate the manifest-derived Ghostty Zig version" >&2
  exit 1
fi

if ! awk '
  /^  workflow-guard-tests:$/ { in_job = 1; next }
  in_job && /^  [[:alnum:]_-]+:$/ { exit }
  in_job && index($0, "git submodule update --init --depth 1 ghostty") { found = 1 }
  END { exit !found }
' "$ROOT_DIR/.github/workflows/ci.yml"; then
  echo "workflow-guard-tests does not initialize Ghostty before reading its Zig manifest" >&2
  exit 1
fi

echo "PASS: cmux build scripts use Ghostty's declared Zig version ($actual)"
