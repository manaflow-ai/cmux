#!/usr/bin/env bash
set -euo pipefail

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
    cmux|ghostty|cmux-claude-wrapper|grok|open|start-cmux-profiling|submit-cmux-profile)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

looks_like_bun_standalone() {
  local path="$1"
  strings "$path" 2>/dev/null | grep -Eq '(/\$bunfs/|StandaloneExecutable|Bun v[0-9]+\.[0-9]+\.[0-9]+)'
}

violations=()

while IFS= read -r -d '' file; do
  name="$(basename "$file")"
  if ! is_allowed_binary_name "$name"; then
    violations+=("unexpected executable: ${file#$APP_PATH/}")
    continue
  fi
  if looks_like_bun_standalone "$file"; then
    violations+=("Bun standalone runtime signature: ${file#$APP_PATH/}")
  fi
done < <(find "$BIN_DIR" -type f -perm -111 -print0)

if [ "${#violations[@]}" -gt 0 ]; then
  echo "error: cmux app bundle contains forbidden bundled provider runtimes:" >&2
  printf '  %s\n' "${violations[@]}" >&2
  exit 1
fi

echo "verified no bundled provider runtimes: $APP_PATH"
