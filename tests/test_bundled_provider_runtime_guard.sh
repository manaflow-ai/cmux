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
write_executable "$GOOD_APP/Contents/Resources/bin/open" "#!/bin/sh"
write_executable "$GOOD_APP/Contents/Resources/bin/start-cmux-profiling" "#!/bin/sh"
write_executable "$GOOD_APP/Contents/Resources/bin/submit-cmux-profile" "#!/bin/sh"
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

NONEXEC_FORBIDDEN_APP="$TMP_DIR/bad-nonexec-bun/cmux.app"
make_app "$NONEXEC_FORBIDDEN_APP"
write_executable "$NONEXEC_FORBIDDEN_APP/Contents/Resources/bin/cmux" "#!/bin/sh"
printf '%s\n' 'Bun v1.3.14 StandaloneExecutable /$bunfs/root' > "$NONEXEC_FORBIDDEN_APP/Contents/Resources/bin/bun"
chmod 0644 "$NONEXEC_FORBIDDEN_APP/Contents/Resources/bin/bun"
if "$VERIFY_SCRIPT" "$NONEXEC_FORBIDDEN_APP" >"$TMP_DIR/nonexec-bun.out" 2>&1; then
  echo "FAIL: verifier allowed a non-executable bundled bun file" >&2
  exit 1
fi
if ! grep -Fq "unexpected bundled bin entry: Contents/Resources/bin/bun" "$TMP_DIR/nonexec-bun.out"; then
  echo "FAIL: non-executable bun rejection did not name the offending path" >&2
  cat "$TMP_DIR/nonexec-bun.out" >&2
  exit 1
fi

NONEXEC_ALLOWED_APP="$TMP_DIR/bad-nonexec-allowed/cmux.app"
make_app "$NONEXEC_ALLOWED_APP"
printf '%s\n' '#!/bin/sh' > "$NONEXEC_ALLOWED_APP/Contents/Resources/bin/cmux"
chmod 0644 "$NONEXEC_ALLOWED_APP/Contents/Resources/bin/cmux"
if "$VERIFY_SCRIPT" "$NONEXEC_ALLOWED_APP" >"$TMP_DIR/nonexec-allowed.out" 2>&1; then
  echo "FAIL: verifier allowed a non-executable allowlisted bin entry" >&2
  exit 1
fi
if ! grep -Fq "allowed bin entry is not executable: Contents/Resources/bin/cmux" "$TMP_DIR/nonexec-allowed.out"; then
  echo "FAIL: non-executable allowlisted rejection did not name the offending path" >&2
  cat "$TMP_DIR/nonexec-allowed.out" >&2
  exit 1
fi

SYMLINK_APP="$TMP_DIR/bad-symlink/cmux.app"
make_app "$SYMLINK_APP"
write_executable "$SYMLINK_APP/Contents/Resources/bin/cmux" "#!/bin/sh"
ln -s cmux "$SYMLINK_APP/Contents/Resources/bin/claude"
if "$VERIFY_SCRIPT" "$SYMLINK_APP" >"$TMP_DIR/symlink.out" 2>&1; then
  echo "FAIL: verifier allowed a symlinked bundled claude executable" >&2
  exit 1
fi
if ! grep -Fq "Contents/Resources/bin/claude" "$TMP_DIR/symlink.out"; then
  echo "FAIL: symlink rejection did not name the offending path" >&2
  cat "$TMP_DIR/symlink.out" >&2
  exit 1
fi

BUN_SIGNATURE_APP="$TMP_DIR/bad-bun-signature/cmux.app"
make_app "$BUN_SIGNATURE_APP"
write_executable "$BUN_SIGNATURE_APP/Contents/Resources/bin/cmux" '#!/bin/sh
printf "%s\n" "Bun v1.3.14 StandaloneExecutable /$bunfs/root"'
if "$VERIFY_SCRIPT" "$BUN_SIGNATURE_APP" >"$TMP_DIR/bun-signature.out" 2>&1; then
  echo "FAIL: verifier allowed an allowlisted executable with a Bun standalone signature" >&2
  exit 1
fi
if ! grep -Fq "Bun standalone runtime signature: Contents/Resources/bin/cmux" "$TMP_DIR/bun-signature.out"; then
  echo "FAIL: Bun signature rejection did not name the offending path" >&2
  cat "$TMP_DIR/bun-signature.out" >&2
  exit 1
fi

echo "PASS: bundled provider runtime guard rejects stale provider and Bun executables"
