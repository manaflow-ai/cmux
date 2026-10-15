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
  "$APP/Contents/Resources/libexec" \
  "$TMP_DIR/tools"

for path in \
  "$APP/Contents/MacOS/cmux" \
  "$APP/Contents/Resources/bin/cmux" \
  "$APP/Contents/Resources/bin/cmux-diff-sidecar" \
  "$APP/Contents/Resources/bin/ghostty" \
  "$APP/Contents/Resources/bin/cmux-app-host" \
  "$APP/Contents/Resources/bin/cmux-browser-host" \
  "$APP/Contents/Resources/bin/cmux-cloud" \
  "$APP/Contents/Resources/bin/cmux-code-mode-run" \
  "$APP/Contents/Resources/libexec/cmux-server-helper" \
  "$APP/Contents/Frameworks/cmux Helper.app/Contents/MacOS/cmux Helper" \
  "$APP/Contents/Frameworks/cmux Helper (GPU).app/Contents/MacOS/cmux Helper (GPU)" \
  "$APP/Contents/PlugIns/CmuxDockTilePlugin.plugin/Contents/MacOS/CmuxDockTilePlugin" \
  "$APP/Contents/Library/SystemExtensions/cmuxTunnel.systemextension/Contents/MacOS/cmuxTunnel" \
  "$APP/Contents/Frameworks/libcmux_command_palette_nucleo_ffi.dylib" \
  "$APP/Contents/Frameworks/Sparkle.framework"
do
  mkdir -p "$(dirname "$path")"
  printf '#!/bin/sh\nexit 0\n' > "$path"
  chmod +x "$path"
done
# bin/cmux is the cmux-tui binary; its other names are symlinks, never stripped.
ln -s cmux "$APP/Contents/Resources/bin/cmux-tui"
ln -s cmux "$APP/Contents/Resources/bin/acpmux"

# cmux-tui SSH bootstrap payloads are installed 0644. The macOS ones are Mach-O
# and must be stripped; the Linux ones are ELF and arrive already stripped.
for target in aarch64-apple-darwin x86_64-apple-darwin aarch64-unknown-linux-musl x86_64-unknown-linux-musl; do
  printf 'payload\n' > "$APP/Contents/Resources/bin/cmux-tui-ssh/cmux-tui-$target"
  chmod 644 "$APP/Contents/Resources/bin/cmux-tui-ssh/cmux-tui-$target"
done
printf '{}\n' > "$APP/Contents/Resources/bin/cmux-tui-ssh/manifest.json"

# Compiled String Catalogs in package resource bundles arrive as UTF-16 XML
# property lists; they ship as binary ones. Binary and old-style text tables
# stay as they are.
STRINGS_DIR="$APP/Contents/Resources/CmuxNext_Fixture.bundle/Contents/Resources/ja.lproj"
mkdir -p "$STRINGS_DIR"
python3 -I - "$STRINGS_DIR" <<'PY'
import plistlib, sys
d = sys.argv[1]
table = {"Open": "\u958b\u304f", "Quote": "\"%@\" & <tag>"}
xml = plistlib.dumps(table, fmt=plistlib.FMT_XML).decode("utf-8")
open(f"{d}/Localizable.strings", "wb").write(b"\xff\xfe" + xml.encode("utf-16-le"))
open(f"{d}/Binary.strings", "wb").write(plistlib.dumps(table, fmt=plistlib.FMT_BINARY))
open(f"{d}/InfoPlist.strings", "wb").write('"CFBundleName" = "\u958b";\n'.encode("utf-8"))
# A UTF-16 big-endian table that declares its real encoding converts too.
declared = xml.replace('encoding="UTF-8"', 'encoding="UTF-16"')
open(f"{d}/Declared.strings", "wb").write(b"\xfe\xff" + declared.encode("utf-16-be"))
# An unreadable table is kept as it is instead of failing the release.
open(f"{d}/Broken.strings", "wb").write(b"\xff\xfe" + "<?xml version".encode("utf-16-le") + b"\x00")
PY
cp "$STRINGS_DIR/Binary.strings" "$TMP_DIR/Binary.before"
cp "$STRINGS_DIR/InfoPlist.strings" "$TMP_DIR/InfoPlist.before"
cp "$STRINGS_DIR/Broken.strings" "$TMP_DIR/Broken.before"

cat > "$TMP_DIR/tools/file" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *"/Contents/MacOS/cmux"|*"/Contents/Resources/bin/cmux"|*"/Contents/Resources/bin/cmux-tui"|*"/Contents/Resources/bin/acpmux"|*"/Contents/Resources/bin/cmux-diff-sidecar"|*"CmuxDockTilePlugin"|*"/Contents/MacOS/cmuxTunnel"|*"libcmux_"*|*"-apple-darwin"|*"/bin/ghostty"|*"/bin/cmux-app-host"|*"/bin/cmux-browser-host"|*"/bin/cmux-cloud"|*"/libexec/cmux-server-helper"|*"/Contents/MacOS/cmux Helper"*)
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
  "-S -x $APP/Contents/Resources/bin/cmux" \
  "$APP/Contents/Resources/bin/cmux-diff-sidecar" \
  "-S -x $APP/Contents/Resources/bin/cmux-app-host" \
  "-S -x $APP/Contents/Resources/bin/cmux-browser-host" \
  "-S -x $APP/Contents/Resources/bin/cmux-cloud" \
  "-S -x $APP/Contents/Resources/bin/ghostty" \
  "-S -x $APP/Contents/Resources/libexec/cmux-server-helper" \
  "-S -x $APP/Contents/Resources/bin/cmux-tui-ssh/cmux-tui-aarch64-apple-darwin" \
  "-S -x $APP/Contents/Resources/bin/cmux-tui-ssh/cmux-tui-x86_64-apple-darwin" \
  "-S -x $APP/Contents/PlugIns/CmuxDockTilePlugin.plugin/Contents/MacOS/CmuxDockTilePlugin" \
  "-S -x $APP/Contents/Frameworks/libcmux_command_palette_nucleo_ffi.dylib" \
  "-S -x $APP/Contents/Frameworks/cmux Helper (GPU).app/Contents/MacOS/cmux Helper (GPU)" \
  "-S -x $APP/Contents/Frameworks/cmux Helper.app/Contents/MacOS/cmux Helper" \
  "-S -x $APP/Contents/Library/SystemExtensions/cmuxTunnel.systemextension/Contents/MacOS/cmuxTunnel" \
  | LC_ALL=C sort > "$expected"
LC_ALL=C sort "$TMP_DIR/strip.log" > "$TMP_DIR/strip.sorted.log"

if ! diff -u "$expected" "$TMP_DIR/strip.sorted.log"; then
  echo "strip-release-bundle.sh stripped the wrong files" >&2
  exit 1
fi

python3 -I - "$STRINGS_DIR" <<'PY' || { echo "strip-release-bundle.sh left compiled strings as XML" >&2; exit 1; }
import plistlib, sys
d = sys.argv[1]
data = open(f"{d}/Localizable.strings", "rb").read()
assert data.startswith(b"bplist00"), data[:16]
assert plistlib.loads(data) == {"Open": "\u958b\u304f", "Quote": "\"%@\" & <tag>"}
declared = open(f"{d}/Declared.strings", "rb").read()
assert declared.startswith(b"bplist00"), declared[:16]
assert plistlib.loads(declared) == plistlib.loads(data)
PY
cmp -s "$STRINGS_DIR/Binary.strings" "$TMP_DIR/Binary.before" || { echo "binary strings table changed" >&2; exit 1; }
cmp -s "$STRINGS_DIR/InfoPlist.strings" "$TMP_DIR/InfoPlist.before" || { echo "text strings table changed" >&2; exit 1; }
cmp -s "$STRINGS_DIR/Broken.strings" "$TMP_DIR/Broken.before" || { echo "unreadable strings table changed" >&2; exit 1; }
