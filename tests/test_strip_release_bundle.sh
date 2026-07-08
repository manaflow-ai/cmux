#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

APP="$TMP_DIR/cmux.app"
mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources/bin" \
  "$APP/Contents/PlugIns/CmuxDockTilePlugin.plugin/Contents/MacOS" \
  "$APP/Contents/Frameworks" \
  "$TMP_DIR/tools"

for path in \
  "$APP/Contents/MacOS/cmux" \
  "$APP/Contents/Resources/bin/cmux" \
  "$APP/Contents/Resources/bin/ghostty" \
  "$APP/Contents/PlugIns/CmuxDockTilePlugin.plugin/Contents/MacOS/CmuxDockTilePlugin" \
  "$APP/Contents/Frameworks/libcmux_command_palette_nucleo_ffi.dylib" \
  "$APP/Contents/Frameworks/Sparkle.framework"
do
  mkdir -p "$(dirname "$path")"
  printf '#!/bin/sh\nexit 0\n' > "$path"
  chmod +x "$path"
done

cat > "$TMP_DIR/tools/file" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *"/Contents/MacOS/cmux"|*"/Contents/Resources/bin/cmux"|*"CmuxDockTilePlugin"|*"libcmux_"*)
    printf '%s: Mach-O universal binary\n' "$1"
    ;;
  *)
    printf '%s: POSIX shell script\n' "$1"
    ;;
esac
EOF
chmod +x "$TMP_DIR/tools/file"

cat > "$TMP_DIR/tools/strip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_STRIP_LOG"
EOF
chmod +x "$TMP_DIR/tools/strip"

CMUX_STRIP_LOG="$TMP_DIR/strip.log" \
CMUX_FILE_TOOL="$TMP_DIR/tools/file" \
CMUX_STRIP_TOOL="$TMP_DIR/tools/strip" \
  "$ROOT/scripts/strip-release-bundle.sh" "$APP"

expected="$TMP_DIR/expected.log"
cat > "$expected" <<EOF
-S -x $APP/Contents/MacOS/cmux
-S -x $APP/Contents/Resources/bin/cmux
-S -x $APP/Contents/PlugIns/CmuxDockTilePlugin.plugin/Contents/MacOS/CmuxDockTilePlugin
-S -x $APP/Contents/Frameworks/libcmux_command_palette_nucleo_ffi.dylib
EOF

if ! diff -u "$expected" "$TMP_DIR/strip.log"; then
  echo "strip-release-bundle.sh stripped the wrong files" >&2
  exit 1
fi

