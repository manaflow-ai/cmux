#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/strip-cmux-cua-rpaths.sh"
TMP_DIR="$(mktemp -d "/tmp/cmux-strip-rpaths.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/fake-bin"
BINARY="$TMP_DIR/cmux-cua"
LOG="$TMP_DIR/tool.log"
mkdir -p "$FAKE_BIN"
printf 'universal fixture\n' > "$BINARY"

cat > "$FAKE_BIN/lipo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'lipo %s\n' "$*" >> "$CMUX_STRIP_LOG"
case "$1" in
  -archs)
    echo 'arm64 x86_64'
    ;;
  -thin)
    printf '%s\n' "$2" > "$5"
    ;;
  -create)
    cat "$2" "$3" > "$5"
    ;;
  *)
    echo "unexpected lipo invocation: $*" >&2
    exit 2
    ;;
esac
EOF

cat > "$FAKE_BIN/otool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == '-arch' && "$2" == all && "$3" == '-l' ]] || exit 2
cat <<'OUTPUT'
Load command 0
      cmd LC_RPATH
     path /usr/lib/swift (offset 12)
Load command 1
      cmd LC_RPATH
     path /Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx (offset 12)
Load command 2
      cmd LC_RPATH
     path @loader_path/../Frameworks (offset 12)
OUTPUT
EOF

cat > "$FAKE_BIN/install_name_tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'install_name_tool %s\n' "$*" >> "$CMUX_STRIP_LOG"
EOF
chmod +x "$FAKE_BIN"/*

CMUX_STRIP_LOG="$LOG" \
  OTOOL_TOOL="$FAKE_BIN/otool" \
  INSTALL_NAME_TOOL="$FAKE_BIN/install_name_tool" \
  LIPO_TOOL="$FAKE_BIN/lipo" \
  "$SCRIPT" "$BINARY" > "$TMP_DIR/output.log"

if [ "$(grep -c -- 'install_name_tool -delete_rpath /Applications/Xcode_26.6.app' "$LOG")" -ne 2 ]; then
  echo 'FAIL: every universal slice must lose the Xcode toolchain rpath' >&2
  cat "$LOG" >&2
  exit 1
fi
if grep -Fq -- 'install_name_tool -delete_rpath /usr/lib/swift' "$LOG" \
  || grep -Fq -- 'install_name_tool -delete_rpath @loader_path/../Frameworks' "$LOG"; then
  echo 'FAIL: allowed Swift and loader-relative rpaths were removed' >&2
  cat "$LOG" >&2
  exit 1
fi
grep -Fq 'lipo -thin arm64' "$LOG"
grep -Fq 'lipo -thin x86_64' "$LOG"
grep -Fq 'lipo -create' "$LOG"

echo 'PASS: cmux-cua rpath stripper removes only forbidden paths from every slice'
