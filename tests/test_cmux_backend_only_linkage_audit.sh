#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-backend-only-linkage-fixture.XXXXXX")"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

FAKE_BIN="$TEST_ROOT/bin"
BINARY="$TEST_ROOT/cmux"
PLIST="$TEST_ROOT/Info.plist"
mkdir -p "$FAKE_BIN"
: > "$BINARY"
cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CMUXTerminalBackendServiceEnabled</key>
  <true/>
  <key>CMUXTerminalRuntimeOwnership</key>
  <string>backend-only</string>
</dict>
</plist>
EOF

cat > "$FAKE_BIN/file" <<'EOF'
#!/usr/bin/env bash
printf '%s: Mach-O 64-bit executable arm64\n' "$1"
EOF

cat > "$FAKE_BIN/nm" <<'EOF'
#!/usr/bin/env bash
case "${CMUX_BACKEND_ONLY_FIXTURE_CASE:-clean}" in
  ghostty-symbol) printf '                 U _ghostty_surface_new\n' ;;
  pty-symbol) printf '                 U _forkpty\n' ;;
  legacy-symbol) printf '0000000100000000 T _$s4cmux25EmbeddedTerminalPanelFactoryC\n' ;;
esac
EOF

cat > "$FAKE_BIN/otool" <<'EOF'
#!/usr/bin/env bash
printf '%s:\n' "${2:-fixture}"
if [[ "${CMUX_BACKEND_ONLY_FIXTURE_CASE:-clean}" == "ghostty-load" ]]; then
  printf '\t@rpath/GhosttyKit.framework/GhosttyKit (compatibility version 1.0.0, current version 1.0.0)\n'
else
  printf '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n'
fi
EOF

cat > "$FAKE_BIN/strings" <<'EOF'
#!/usr/bin/env bash
if [[ "${CMUX_BACKEND_ONLY_FIXTURE_CASE:-clean}" == "legacy-string" ]]; then
  printf 'GhosttyNSView\n'
fi
EOF
chmod +x "$FAKE_BIN"/*

run_audit() {
  PATH="$FAKE_BIN:$PATH" \
    "$ROOT/scripts/audit-cmux-backend-only-linkage.sh" \
      --info-plist "$PLIST" \
      --binary "$BINARY"
}

CMUX_BACKEND_ONLY_FIXTURE_CASE=clean run_audit > "$TEST_ROOT/clean.log"

assert_rejected() {
  local fixture_case="$1"
  local diagnostic="$2"
  local output="$TEST_ROOT/$fixture_case.log"
  if CMUX_BACKEND_ONLY_FIXTURE_CASE="$fixture_case" run_audit >"$output" 2>&1; then
    echo "backend-only fixture unexpectedly passed: $fixture_case" >&2
    exit 1
  fi
  grep -Fq "$diagnostic" "$output"
}

assert_rejected ghostty-symbol "links Ghostty or PTY ownership symbols"
assert_rejected pty-symbol "links Ghostty or PTY ownership symbols"
assert_rejected legacy-symbol "legacy terminal runtime identity"
assert_rejected legacy-string "legacy terminal runtime identity"
assert_rejected ghostty-load "dynamically loads Ghostty or legacy terminal code"

/usr/libexec/PlistBuddy -c 'Set :CMUXTerminalRuntimeOwnership hybrid' "$PLIST"
if run_audit > "$TEST_ROOT/metadata.log" 2>&1; then
  echo "hybrid runtime metadata unexpectedly passed backend-only audit" >&2
  exit 1
fi
grep -Fq "expected backend-only" "$TEST_ROOT/metadata.log"

echo "cmux backend-only linkage fixtures rejected"
