#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/verify-bundle-load-commands.sh"
TMP_DIR="$(mktemp -d "/tmp/cmux-load-command-guard.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

APP="$TMP_DIR/cmux.app"
FAKE_BIN="$TMP_DIR/fake-bin"
mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources/bin" \
  "$APP/Contents/Frameworks" \
  "$APP/Contents/Library/cmux Computer Use.app/Contents/MacOS" \
  "$FAKE_BIN"
APP="$(cd "$APP" && pwd -P)"

for binary in \
  "$APP/Contents/MacOS/cmux" \
  "$APP/Contents/Resources/bin/cmux-cua" \
  "$APP/Contents/Library/cmux Computer Use.app/Contents/MacOS/cmux-cua" \
  "$APP/Contents/Frameworks/nested-macho"; do
  : > "$binary"
done
printf 'resource\n' > "$APP/Contents/Info.plist"

cat > "$FAKE_BIN/file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="$(printf '%s\n' "$@" | tail -n 1)"
case "$target" in
  */cmux|*/cmux-cua|*/nested-macho) echo 'Mach-O universal binary with 2 architectures' ;;
  *) echo 'ASCII text' ;;
esac
EOF

cat > "$FAKE_BIN/otool" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\$1" == '-arch' && "\$2" == all && "\$3" == '-l' ]] || exit 2
target="\$4"
if [[ "\${CMUX_FAKE_MODE:-}" == bad-rpath && "\$target" == */cmux-cua ]]; then
  cat <<'BAD_RPATH'
Load command 0
      cmd LC_RPATH
     path /usr/lib/swift (offset 12)
Load command 1
      cmd LC_RPATH
     path /Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx (offset 12)
Load command 2
      cmd LC_RPATH
     path @loader_path/../Frameworks (offset 12)
BAD_RPATH
  exit 0
fi
if [[ "\${CMUX_FAKE_MODE:-}" == bad-load && "\$target" == */nested-macho ]]; then
  cat <<'BAD_LOAD'
Load command 0
      cmd LC_LOAD_DYLIB
     name /Users/runner/work/cmux/third-party/libbad.dylib (offset 24)
BAD_LOAD
  exit 0
fi
if [[ "\${CMUX_FAKE_MODE:-}" == bad-bundle-path && "\$target" == */nested-macho ]]; then
  cat <<BAD_BUNDLE_PATH
Load command 0
      cmd LC_LOAD_DYLIB
     name $APP/Contents/Frameworks/nested-macho (offset 24)
BAD_BUNDLE_PATH
  exit 0
fi
if [[ "\${CMUX_FAKE_MODE:-}" == bad-system-traversal && "\$target" == */nested-macho ]]; then
  cat <<'BAD_SYSTEM_TRAVERSAL'
Load command 0
      cmd LC_LOAD_DYLIB
     name /usr/lib/../../tmp/libexample.dylib (offset 24)
BAD_SYSTEM_TRAVERSAL
  exit 0
fi
if [[ "\${CMUX_FAKE_MODE:-}" == bad-loader-traversal && "\$target" == */nested-macho ]]; then
  cat <<'BAD_LOADER_TRAVERSAL'
Load command 0
      cmd LC_LOAD_DYLIB
     name @loader_path/../../../../tmp/libexample.dylib (offset 24)
BAD_LOADER_TRAVERSAL
  exit 0
fi
if [[ "\${CMUX_FAKE_MODE:-}" == bad-executable-traversal && "\$target" == */nested-macho ]]; then
  cat <<'BAD_EXECUTABLE_TRAVERSAL'
Load command 0
      cmd LC_LOAD_DYLIB
     name @executable_path/../../../../tmp/libexample.dylib (offset 24)
BAD_EXECUTABLE_TRAVERSAL
  exit 0
fi
cat <<'GOOD'
Load command 0
      cmd LC_RPATH
     path /usr/lib/swift (offset 12)
Load command 1
      cmd LC_RPATH
     path @loader_path/../Frameworks (offset 12)
Load command 2
      cmd LC_LOAD_DYLIB
     name @rpath/libswift_Concurrency.dylib (offset 24)
Load command 3
      cmd LC_LOAD_WEAK_DYLIB
     name /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation (offset 24)
Load command 4
      cmd LC_REEXPORT_DYLIB
     name @loader_path/../Frameworks/nested-macho (offset 24)
GOOD
EOF
chmod +x "$FAKE_BIN/file" "$FAKE_BIN/otool"

run_guard() {
  OTOOL_TOOL="$FAKE_BIN/otool" \
    FILE_TOOL="$FAKE_BIN/file" \
    "$SCRIPT" "$APP"
}

run_guard > "$TMP_DIR/clean.log"
grep -Fq "PASS: Mach-O load commands are distribution-safe" "$TMP_DIR/clean.log"

if CMUX_FAKE_MODE=bad-rpath run_guard > "$TMP_DIR/bad-rpath.log" 2>&1; then
  echo 'FAIL: the guard accepted an absolute Xcode toolchain rpath' >&2
  exit 1
fi
grep -Fq '/Applications/Xcode_26.6.app/Contents/Developer/Toolchains' "$TMP_DIR/bad-rpath.log"
grep -Fq 'cmux-cua' "$TMP_DIR/bad-rpath.log"

if CMUX_FAKE_MODE=bad-load run_guard > "$TMP_DIR/bad-load.log" 2>&1; then
  echo 'FAIL: the guard accepted an absolute third-party load path' >&2
  exit 1
fi
grep -Fq '/Users/runner/work/cmux/third-party/libbad.dylib' "$TMP_DIR/bad-load.log"
grep -Fq 'nested-macho' "$TMP_DIR/bad-load.log"

if CMUX_FAKE_MODE=bad-bundle-path run_guard > "$TMP_DIR/bad-bundle-path.log" 2>&1; then
  echo 'FAIL: the guard accepted an absolute path inside the build-time app root' >&2
  exit 1
fi
grep -Fq "$APP/Contents/Frameworks/nested-macho" "$TMP_DIR/bad-bundle-path.log"

if CMUX_FAKE_MODE=bad-system-traversal run_guard > "$TMP_DIR/bad-system-traversal.log" 2>&1; then
  echo 'FAIL: the guard accepted a traversal through an allowed system root' >&2
  exit 1
fi
grep -Fq '/usr/lib/../../tmp/libexample.dylib' "$TMP_DIR/bad-system-traversal.log"

if CMUX_FAKE_MODE=bad-loader-traversal run_guard > "$TMP_DIR/bad-loader-traversal.log" 2>&1; then
  echo 'FAIL: the guard accepted loader-relative traversal outside the app' >&2
  exit 1
fi
grep -Fq '@loader_path/../../../../tmp/libexample.dylib' "$TMP_DIR/bad-loader-traversal.log"

if CMUX_FAKE_MODE=bad-executable-traversal run_guard > "$TMP_DIR/bad-executable-traversal.log" 2>&1; then
  echo 'FAIL: the guard accepted executable-relative traversal outside the app' >&2
  exit 1
fi
grep -Fq '@executable_path/../../../../tmp/libexample.dylib' "$TMP_DIR/bad-executable-traversal.log"

echo 'PASS: bundle load-command guard rejects bad rpaths and load paths across nested Mach-O files'
