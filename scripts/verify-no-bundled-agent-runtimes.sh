#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_GROK_WRAPPER="$SCRIPT_DIR/../Resources/bin/grok"

usage() {
  cat <<'EOF'
Usage: scripts/verify-no-bundled-agent-runtimes.sh <cmux.app>

Verifies that a built cmux app bundle does not ship provider executables or a
Bun standalone runtime in Contents/Resources/bin.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi

APP_PATH="$1"
BIN_DIR="$APP_PATH/Contents/Resources/bin"

if [ ! -d "$APP_PATH" ]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi

if [ ! -d "$BIN_DIR" ]; then
  echo "error: bundled bin directory not found at $BIN_DIR" >&2
  exit 1
fi

is_allowed_binary_name() {
  case "$1" in
    # `grok` is allowed only when it matches cmux's checked-in wrapper script;
    # it still goes through the Bun-standalone signature scan below.
    cmux|ghostty|cmux-claude-wrapper|cmux-codex-wrapper|grok|open|start-cmux-profiling|submit-cmux-profile)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

looks_like_bun_standalone() {
  local path="$1"
  strings -a "$path" 2>/dev/null | grep -Eq '(/\$bunfs/|StandaloneExecutable|Bun v[0-9]+\.[0-9]+\.[0-9]+)'
}

is_checked_in_grok_wrapper() {
  local path="$1"
  [ -f "$EXPECTED_GROK_WRAPPER" ] && cmp -s "$EXPECTED_GROK_WRAPPER" "$path"
}

relative_to_app() {
  local path="$1"
  printf '%s\n' "${path#"$APP_PATH"/}"
}

violations=()

while IFS= read -r -d '' file; do
  name="$(basename "$file")"
  if ! is_allowed_binary_name "$name"; then
    violations+=("unexpected bundled bin entry: $(relative_to_app "$file")")
    continue
  fi
  if [ ! -x "$file" ] && [ ! -L "$file" ]; then
    violations+=("allowed bin entry is not executable: $(relative_to_app "$file")")
  fi
  if [ "$name" = "grok" ] && ! is_checked_in_grok_wrapper "$file"; then
    violations+=("grok wrapper does not match checked-in cmux wrapper: $(relative_to_app "$file")")
  fi
  if looks_like_bun_standalone "$file"; then
    violations+=("Bun standalone runtime signature: $(relative_to_app "$file")")
  fi
done < <(find "$BIN_DIR" \( -type f -o -type l \) -print0)

if [ "${#violations[@]}" -gt 0 ]; then
  echo "error: cmux app bundle contains forbidden bundled provider runtimes:" >&2
  printf '  %s\n' "${violations[@]}" >&2
  exit 1
fi

echo "verified no bundled provider runtimes: $APP_PATH"
