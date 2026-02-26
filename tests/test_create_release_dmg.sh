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

BIN_WITH_NPX="$TMPDIR/bin-with-npx"
BIN_NO_NPX="$TMPDIR/bin-no-npx"
PATH_BASE="/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$BIN_WITH_NPX" "$BIN_NO_NPX"

cat > "$BIN_WITH_NPX/create-dmg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--version" ]; then
  echo "create-dmg ${FAKE_CREATE_DMG_VERSION:-8.0.0}"
  exit 0
fi

if [ "${1:-}" = "--help" ]; then
  if [ "${FAKE_CREATE_DMG_VERSION:-8.0.0}" = "1.2.1" ]; then
    echo "Usage: create-dmg [options] <output_name.dmg> <source_folder>"
  else
    echo "Usage: create-dmg <app> [destination]"
  fi
  exit 0
fi

printf '%s\n' "$*" >> "$FAKE_CREATE_DMG_LOG"

if printf '%s\n' "$*" | grep -Fq -- "--overwrite"; then
  dest="${!#}"
  mkdir -p "$dest"
  : > "$dest/generated.dmg"
  exit 0
fi

for arg in "$@"; do
  if [[ "$arg" == *.dmg ]]; then
    mkdir -p "$(dirname "$arg")"
    : > "$arg"
    exit 0
  fi
done

echo "fake create-dmg did not receive a valid destination" >&2
exit 1
EOF

cp "$BIN_WITH_NPX/create-dmg" "$BIN_NO_NPX/create-dmg"

cat > "$BIN_WITH_NPX/npx" <<'EOF'
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

chmod +x "$BIN_WITH_NPX/create-dmg" "$BIN_NO_NPX/create-dmg" "$BIN_WITH_NPX/npx"

APP_DIR="$TMPDIR/cmux.app"
mkdir -p "$APP_DIR/Contents"

run_script() {
  local output_path create_dmg_log npx_log
  output_path="$1"
  create_dmg_log="$2"
  npx_log="$3"
  shift 3

  FAKE_CREATE_DMG_LOG="$create_dmg_log" \
    FAKE_NPX_LOG="$npx_log" \
    "$@" "$SCRIPT" "$APP_DIR" "$output_path" "SIGNING-ID"
}

case_modern_binary() {
  local output_path create_dmg_log npx_log
  output_path="$TMPDIR/modern/cmux-macos.dmg"
  create_dmg_log="$TMPDIR/modern-create-dmg.log"
  npx_log="$TMPDIR/modern-npx.log"
  : > "$create_dmg_log"
  : > "$npx_log"

  run_script "$output_path" "$create_dmg_log" "$npx_log" \
    env PATH="$BIN_WITH_NPX:$PATH_BASE" FAKE_CREATE_DMG_VERSION="8.0.0"

  [ -f "$output_path" ] || { echo "FAIL: modern binary case did not produce DMG"; exit 1; }
  grep -F -- "--overwrite" "$create_dmg_log" >/dev/null || {
    echo "FAIL: modern binary case did not use --overwrite"
    exit 1
  }
  grep -F -- "--identity=SIGNING-ID" "$create_dmg_log" >/dev/null || {
    echo "FAIL: modern binary case did not pass --identity"
    exit 1
  }
  if [ -s "$npx_log" ]; then
    echo "FAIL: modern binary case should not invoke npx"
    exit 1
  fi
}

case_legacy_promoted_to_modern() {
  local output_path create_dmg_log npx_log
  output_path="$TMPDIR/legacy-modernized/cmux-macos.dmg"
  create_dmg_log="$TMPDIR/legacy-modernized-create-dmg.log"
  npx_log="$TMPDIR/legacy-modernized-npx.log"
  : > "$create_dmg_log"
  : > "$npx_log"

  run_script "$output_path" "$create_dmg_log" "$npx_log" \
    env PATH="$BIN_WITH_NPX:$PATH_BASE" FAKE_CREATE_DMG_VERSION="1.2.1" CMUX_CREATE_DMG_REQUIRE_MODERN=1

  [ -f "$output_path" ] || { echo "FAIL: legacy modernized case did not produce DMG"; exit 1; }
  grep -F -- "create-dmg@8.0.0" "$npx_log" >/dev/null || {
    echo "FAIL: legacy modernized case did not invoke npx create-dmg@8.0.0"
    exit 1
  }
  grep -F -- "--overwrite" "$npx_log" >/dev/null || {
    echo "FAIL: legacy modernized case did not pass --overwrite through npx"
    exit 1
  }
}

case_legacy_fallback() {
  local output_path create_dmg_log npx_log
  output_path="$TMPDIR/legacy-fallback/cmux-macos.dmg"
  create_dmg_log="$TMPDIR/legacy-fallback-create-dmg.log"
  npx_log="$TMPDIR/legacy-fallback-npx.log"
  : > "$create_dmg_log"
  : > "$npx_log"

  run_script "$output_path" "$create_dmg_log" "$npx_log" \
    env PATH="$BIN_NO_NPX:$PATH_BASE" FAKE_CREATE_DMG_VERSION="1.2.1"

  [ -f "$output_path" ] || { echo "FAIL: legacy fallback case did not produce DMG"; exit 1; }
  grep -F -- "--app-drop-link 480 170" "$create_dmg_log" >/dev/null || {
    echo "FAIL: legacy fallback case did not pass --app-drop-link"
    exit 1
  }
  grep -F -- "--codesign SIGNING-ID" "$create_dmg_log" >/dev/null || {
    echo "FAIL: legacy fallback case did not pass --codesign"
    exit 1
  }
  if [ -s "$npx_log" ]; then
    echo "FAIL: legacy fallback case should not invoke npx"
    exit 1
  fi
}

case_require_modern_without_npx_fails() {
  local output_path create_dmg_log npx_log
  output_path="$TMPDIR/require-modern-fail/cmux-macos.dmg"
  create_dmg_log="$TMPDIR/require-modern-fail-create-dmg.log"
  npx_log="$TMPDIR/require-modern-fail-npx.log"
  : > "$create_dmg_log"
  : > "$npx_log"

  if run_script "$output_path" "$create_dmg_log" "$npx_log" \
    env PATH="$BIN_NO_NPX:$PATH_BASE" FAKE_CREATE_DMG_VERSION="1.2.1" CMUX_CREATE_DMG_REQUIRE_MODERN=1 \
    >/dev/null 2>&1; then
    echo "FAIL: require modern without npx should fail"
    exit 1
  fi
}

case_modern_binary
case_legacy_promoted_to_modern
case_legacy_fallback
case_require_modern_without_npx_fails

echo "PASS: create_release_dmg script modern path and legacy fallback behavior"
