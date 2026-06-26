#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_SCRIPT="$ROOT_DIR/scripts/verify-no-bundled-agent-runtimes.sh"

if [ ! -x "$VERIFY_SCRIPT" ]; then
  echo "FAIL: missing bundled provider runtime verifier at $VERIFY_SCRIPT" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-bundled-runtime-guard.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

make_app() {
  local app_path="$1"
  mkdir -p "$app_path/Contents/Resources/bin"
}

write_executable() {
  local path="$1"
  local body="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" > "$path"
  chmod 0755 "$path"
}

GOOD_APP="$TMP_DIR/good/cmux.app"
make_app "$GOOD_APP"
write_executable "$GOOD_APP/Contents/Resources/bin/cmux" "#!/bin/sh"
write_executable "$GOOD_APP/Contents/Resources/bin/ghostty" "#!/bin/sh"
write_executable "$GOOD_APP/Contents/Resources/bin/cmux-claude-wrapper" "#!/bin/sh"
write_executable "$GOOD_APP/Contents/Resources/bin/grok" "#!/bin/sh"
"$VERIFY_SCRIPT" "$GOOD_APP"

for forbidden in claude opencode codex pi bun bunx; do
  BAD_APP="$TMP_DIR/bad-$forbidden/cmux.app"
  make_app "$BAD_APP"
  write_executable "$BAD_APP/Contents/Resources/bin/cmux" "#!/bin/sh"
  write_executable "$BAD_APP/Contents/Resources/bin/$forbidden" "#!/bin/sh"
  OUTPUT="$TMP_DIR/$forbidden.out"
  if "$VERIFY_SCRIPT" "$BAD_APP" >"$OUTPUT" 2>&1; then
    echo "FAIL: verifier allowed bundled $forbidden executable" >&2
    exit 1
  fi
  if ! grep -Fq "Contents/Resources/bin/$forbidden" "$OUTPUT"; then
    echo "FAIL: verifier rejection for $forbidden did not name the offending path" >&2
    cat "$OUTPUT" >&2
    exit 1
  fi
done

echo "PASS: bundled provider runtime guard rejects stale provider and Bun executables"
