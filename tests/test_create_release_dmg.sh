#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/create_release_dmg.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: missing executable script $SCRIPT"
  exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

BIN_WITH_BREW="$TMPDIR/bin-with-brew"
BIN_WITH_MODERN="$TMPDIR/bin-with-modern"
BIN_WITH_LEGACY_PATH="$TMPDIR/bin-with-legacy-path"
LEGACY_PREFIX="$TMPDIR/legacy-prefix"
PATH_BASE="/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$BIN_WITH_BREW" "$BIN_WITH_MODERN" "$BIN_WITH_LEGACY_PATH" "$LEGACY_PREFIX/bin"

cat > "$BIN_WITH_MODERN/create-dmg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--version" ]; then
  echo "create-dmg 8.0.0"
  exit 0
fi

if [ "${1:-}" = "--help" ]; then
  echo "Usage: create-dmg <app> [destination]"
  exit 0
fi

printf '%s\n' "$*" >> "$FAKE_MODERN_LOG"

if printf '%s\n' "$*" | grep -Fq -- "--overwrite"; then
  dest="${!#}"
  mkdir -p "$dest"
  : > "$dest/generated.dmg"
  exit 0
fi

echo "fake modern create-dmg did not receive a supported invocation" >&2
exit 1
EOF

cat > "$LEGACY_PREFIX/bin/create-dmg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--version" ]; then
  echo "create-dmg 1.2.3"
  exit 0
fi

if [ "${1:-}" = "--help" ]; then
  echo "Usage: create-dmg [options] <output_name.dmg> <source_folder>"
  exit 0
fi

printf '%s\n' "$*" >> "$FAKE_LEGACY_LOG"

for arg in "$@"; do
  if [[ "$arg" == *.dmg ]]; then
    mkdir -p "$(dirname "$arg")"
    : > "$arg"
    exit 0
  fi
done

echo "fake legacy create-dmg did not receive an output .dmg argument" >&2
exit 1
EOF

cat > "$BIN_WITH_MODERN/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$FAKE_NPX_LOG"

if [ "${1:-}" != "--yes" ]; then
  echo "expected --yes as first arg" >&2
  exit 1
fi

if [[ "${2:-}" != create-dmg@* ]]; then
  echo "expected create-dmg@<version> as second arg" >&2
  exit 1
fi

dest="${!#}"
mkdir -p "$dest"
: > "$dest/generated-via-npx.dmg"
EOF

cat > "$BIN_WITH_BREW/brew" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [ "\${1:-}" = "--prefix" ] && [ "\${2:-}" = "create-dmg" ]; then
  echo "$LEGACY_PREFIX"
  exit 0
fi

echo "unexpected brew invocation: \$*" >&2
exit 1
EOF

cp "$BIN_WITH_MODERN/create-dmg" "$BIN_WITH_BREW/create-dmg"
cp "$BIN_WITH_MODERN/npx" "$BIN_WITH_BREW/npx"
cp "$LEGACY_PREFIX/bin/create-dmg" "$BIN_WITH_LEGACY_PATH/create-dmg"

chmod +x \
  "$BIN_WITH_MODERN/create-dmg" \
  "$BIN_WITH_MODERN/npx" \
  "$BIN_WITH_BREW/brew" \
  "$BIN_WITH_BREW/create-dmg" \
  "$BIN_WITH_BREW/npx" \
  "$LEGACY_PREFIX/bin/create-dmg" \
  "$BIN_WITH_LEGACY_PATH/create-dmg"

APP_DIR="$TMPDIR/cmux.app"
mkdir -p "$APP_DIR/Contents"

run_script() {
  local output_path legacy_log modern_log npx_log
  output_path="$1"
  legacy_log="$2"
  modern_log="$3"
  npx_log="$4"
  shift 4

  FAKE_LEGACY_LOG="$legacy_log" \
    FAKE_MODERN_LOG="$modern_log" \
    FAKE_NPX_LOG="$npx_log" \
    "$@" "$SCRIPT" "$APP_DIR" "$output_path" "SIGNING-ID"
}

case_prefers_brew_legacy_for_styled() {
  local output_path legacy_log modern_log npx_log
  output_path="$TMPDIR/brew-legacy/cmux-macos.dmg"
  legacy_log="$TMPDIR/brew-legacy.log"
  modern_log="$TMPDIR/brew-modern.log"
  npx_log="$TMPDIR/brew-npx.log"
  : > "$legacy_log"
  : > "$modern_log"
  : > "$npx_log"

  run_script "$output_path" "$legacy_log" "$modern_log" "$npx_log" \
    env PATH="$BIN_WITH_BREW:$PATH_BASE" CMUX_CREATE_DMG_REQUIRE_STYLED=1

  [ -f "$output_path" ] || { echo "FAIL: brew legacy case did not produce DMG"; exit 1; }
  grep -F -- "--app-drop-link 480 170" "$legacy_log" >/dev/null || {
    echo "FAIL: brew legacy case did not use legacy DMG layout"
    exit 1
  }
  if [ -s "$modern_log" ] || [ -s "$npx_log" ]; then
    echo "FAIL: brew legacy case should not invoke modern tooling"
    exit 1
  fi
}

case_path_legacy_works_without_brew() {
  local output_path legacy_log modern_log npx_log
  output_path="$TMPDIR/path-legacy/cmux-macos.dmg"
  legacy_log="$TMPDIR/path-legacy.log"
  modern_log="$TMPDIR/path-modern.log"
  npx_log="$TMPDIR/path-npx.log"
  : > "$legacy_log"
  : > "$modern_log"
  : > "$npx_log"

  run_script "$output_path" "$legacy_log" "$modern_log" "$npx_log" \
    env PATH="$BIN_WITH_LEGACY_PATH:$PATH_BASE" CMUX_CREATE_DMG_REQUIRE_STYLED=1

  [ -f "$output_path" ] || { echo "FAIL: path legacy case did not produce DMG"; exit 1; }
  grep -F -- "--app-drop-link 480 170" "$legacy_log" >/dev/null || {
    echo "FAIL: path legacy case did not use legacy DMG layout"
    exit 1
  }
  if [ -s "$modern_log" ] || [ -s "$npx_log" ]; then
    echo "FAIL: path legacy case should not invoke modern tooling"
    exit 1
  fi
}

case_modern_fallback_uses_modern_cli() {
  local output_path legacy_log modern_log npx_log
  output_path="$TMPDIR/modern/cmux-macos.dmg"
  legacy_log="$TMPDIR/modern-legacy.log"
  modern_log="$TMPDIR/modern-modern.log"
  npx_log="$TMPDIR/modern-npx.log"
  : > "$legacy_log"
  : > "$modern_log"
  : > "$npx_log"

  run_script "$output_path" "$legacy_log" "$modern_log" "$npx_log" \
    env PATH="$BIN_WITH_MODERN:$PATH_BASE"

  [ -f "$output_path" ] || { echo "FAIL: modern fallback case did not produce DMG"; exit 1; }
  grep -F -- "--overwrite" "$modern_log" >/dev/null || {
    echo "FAIL: modern fallback case did not invoke the modern CLI"
    exit 1
  }
  if [ -s "$legacy_log" ] || [ -s "$npx_log" ]; then
    echo "FAIL: modern fallback case should not invoke legacy or npx tooling"
    exit 1
  fi
}

case_require_styled_without_legacy_fails() {
  local output_path legacy_log modern_log npx_log
  output_path="$TMPDIR/require-styled-fail/cmux-macos.dmg"
  legacy_log="$TMPDIR/require-styled-legacy.log"
  modern_log="$TMPDIR/require-styled-modern.log"
  npx_log="$TMPDIR/require-styled-npx.log"
  : > "$legacy_log"
  : > "$modern_log"
  : > "$npx_log"

  if run_script "$output_path" "$legacy_log" "$modern_log" "$npx_log" \
    env PATH="$BIN_WITH_MODERN:$PATH_BASE" CMUX_CREATE_DMG_REQUIRE_STYLED=1 \
    >/dev/null 2>&1; then
    echo "FAIL: require styled without legacy tooling should fail"
    exit 1
  fi
}

case_prefers_brew_legacy_for_styled
case_path_legacy_works_without_brew
case_modern_fallback_uses_modern_cli
case_require_styled_without_legacy_fails

echo "PASS: create_release_dmg script preserves styled DMGs and isolates modern fallback"
