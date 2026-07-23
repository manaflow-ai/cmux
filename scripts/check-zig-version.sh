#!/usr/bin/env bash
# Verifies that the zig on PATH matches Ghostty's build-version contract.
#
# Ghostty's build.zig requires the same major/minor Zig release as
# .minimum_zig_version and a patch version greater than or equal to it. A newer
# Zig minor (for example 0.16.x when Ghostty requires 0.15.2) is intentionally
# rejected because Ghostty's build uses Zig APIs that are not stable across
# minor releases.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

extract_required_zig_version() {
  local build_zig_zon="$PROJECT_DIR/ghostty/build.zig.zon"

  if [[ ! -f "$build_zig_zon" ]]; then
    echo "error: cannot determine required Zig version; missing ghostty/build.zig.zon" >&2
    echo "Run ./scripts/setup.sh to initialize submodules first." >&2
    return 1
  fi

  python3 - "$build_zig_zon" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', text)
if not match:
    raise SystemExit("missing .minimum_zig_version in ghostty/build.zig.zon")
print(match.group(1))
PY
}

parse_semver_core() {
  local version="$1"
  local label="$2"

  if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    printf '%s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi

  echo "error: could not parse $label Zig version: $version" >&2
  return 1
}

REQUIRED_ZIG_VERSION="${1:-}"
if [[ -z "$REQUIRED_ZIG_VERSION" ]]; then
  REQUIRED_ZIG_VERSION="$(extract_required_zig_version)"
fi

read -r REQUIRED_MAJOR REQUIRED_MINOR REQUIRED_PATCH < <(parse_semver_core "$REQUIRED_ZIG_VERSION" "required")

if ! command -v zig >/dev/null 2>&1; then
  echo "Error: cmux requires Zig $REQUIRED_MAJOR.$REQUIRED_MINOR.x with patch >= $REQUIRED_PATCH, but zig is not installed." >&2
  echo "Install a compatible Zig, or see CONTRIBUTING.md for setup instructions." >&2
  exit 1
fi

INSTALLED_ZIG_VERSION="$(zig version 2>/dev/null || true)"
if [[ -z "$INSTALLED_ZIG_VERSION" ]]; then
  echo "Error: zig is on PATH but 'zig version' did not print a version." >&2
  exit 1
fi

read -r INSTALLED_MAJOR INSTALLED_MINOR INSTALLED_PATCH < <(parse_semver_core "$INSTALLED_ZIG_VERSION" "installed")

if (( INSTALLED_MAJOR != REQUIRED_MAJOR || INSTALLED_MINOR != REQUIRED_MINOR || INSTALLED_PATCH < REQUIRED_PATCH )); then
  echo "Error: cmux requires Zig $REQUIRED_MAJOR.$REQUIRED_MINOR.x with patch >= $REQUIRED_PATCH; found $INSTALLED_ZIG_VERSION." >&2
  echo "Install a compatible Zig, or see CONTRIBUTING.md for setup instructions." >&2
  exit 1
fi

echo "zig $INSTALLED_ZIG_VERSION satisfies Ghostty requirement $REQUIRED_ZIG_VERSION"
