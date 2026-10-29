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
  "$APP/Contents/Library/SystemExtensions/cmuxTunnel.systemextension/Contents/MacOS" \
  "$APP/Contents/Frameworks" \
  "$APP/Contents/Resources/bin/cmux-tui-ssh" \
  "$TMP_DIR/tools"

for path in \
  "$APP/Contents/MacOS/cmux" \
  "$APP/Contents/Resources/bin/cmux" \
  "$APP/Contents/Resources/bin/cmux-tui" \
  "$APP/Contents/Resources/bin/cmux-diff-sidecar" \
  "$APP/Contents/Resources/bin/ghostty" \
  "$APP/Contents/PlugIns/CmuxDockTilePlugin.plugin/Contents/MacOS/CmuxDockTilePlugin" \
  "$APP/Contents/Library/SystemExtensions/cmuxTunnel.systemextension/Contents/MacOS/cmuxTunnel" \
  "$APP/Contents/Frameworks/libcmux_command_palette_nucleo_ffi.dylib" \
  "$APP/Contents/Frameworks/Sparkle.framework"
do
  mkdir -p "$(dirname "$path")"
  printf '#!/bin/sh\nexit 0\n' > "$path"
  chmod +x "$path"
done

# cmux-tui SSH bootstrap payloads are installed 0644. The macOS ones are Mach-O
# and must be stripped; the Linux ones are ELF and arrive already stripped.
for target in aarch64-apple-darwin x86_64-apple-darwin aarch64-unknown-linux-musl x86_64-unknown-linux-musl; do
  printf 'payload\n' > "$APP/Contents/Resources/bin/cmux-tui-ssh/cmux-tui-$target"
  chmod 644 "$APP/Contents/Resources/bin/cmux-tui-ssh/cmux-tui-$target"
done
printf '{}\n' > "$APP/Contents/Resources/bin/cmux-tui-ssh/manifest.json"

cat > "$TMP_DIR/tools/file" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *"/Contents/MacOS/cmux"|*"/Contents/Resources/bin/cmux"|*"/Contents/Resources/bin/cmux-tui"|*"/Contents/Resources/bin/cmux-diff-sidecar"|*"CmuxDockTilePlugin"|*"/Contents/MacOS/cmuxTunnel"|*"libcmux_"*|*"-apple-darwin")
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

# cmux's own executables lose every symbol dyld doesn't need (plain strip
# keeps undefined and dynamically referenced ones): crashes symbolicate from the
# uploaded dSYMs. Plug-ins, libraries and extensions keep their global symbols.
expected="$TMP_DIR/expected.log"
printf '%s\n' \
  "$APP/Contents/MacOS/cmux" \
  "$APP/Contents/Resources/bin/cmux" \
  "$APP/Contents/Resources/bin/cmux-tui" \
  "$APP/Contents/Resources/bin/cmux-diff-sidecar" \
  "-S -x $APP/Contents/Resources/bin/cmux-tui-ssh/cmux-tui-aarch64-apple-darwin" \
  "-S -x $APP/Contents/Resources/bin/cmux-tui-ssh/cmux-tui-x86_64-apple-darwin" \
  "-S -x $APP/Contents/PlugIns/CmuxDockTilePlugin.plugin/Contents/MacOS/CmuxDockTilePlugin" \
  "-S -x $APP/Contents/Frameworks/libcmux_command_palette_nucleo_ffi.dylib" \
  "-S -x $APP/Contents/Library/SystemExtensions/cmuxTunnel.systemextension/Contents/MacOS/cmuxTunnel" \
  > "$expected"

if ! diff -u "$expected" "$TMP_DIR/strip.log"; then
  echo "strip-release-bundle.sh stripped the wrong files" >&2
  exit 1
fi
