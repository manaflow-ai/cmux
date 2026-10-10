#!/usr/bin/env bash
# check-app-personalities.sh reads objdump's compact-unwind table of every
# app image: a long table must not break it (SIGPIPE under pipefail failed
# cmux-next.yml run 37317248488 after a successful build), three routines
# pass, four fail, and an image with none means a wrong path.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-app-personalities.sh"
tmp="$(mktemp -d /tmp/cmux-personalities.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/App.app/Contents/MacOS"
cat > "$tmp/App.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>App</string></dict></plist>
PLIST
touch "$tmp/App.app/Contents/MacOS/App" "$tmp/App.app/Contents/MacOS/App.debug.dylib"
# Fake lipo and xcrun objdump: the stub has no table, the dylib $COUNT
# routines followed by a long index list.
cat > "$tmp/bin/lipo" <<'SH'
#!/bin/sh
echo arm64
SH
cat > "$tmp/bin/xcrun" <<'SH'
#!/bin/sh
for arg in "$@"; do last="$arg"; done
case "$last" in
  *.debug.dylib)
    echo "Contents of __unwind_info section:"
    echo "  Personality functions: (count = $COUNT)"
    i=1; while [ "$i" -le "$COUNT" ]; do echo "    personality[$i]: 0x0$i"; i=$((i + 1)); done
    echo "  Top level indices: (count = 5000)"
    i=0; while [ "$i" -lt 5000 ]; do echo "    [$i]: function offset=0x$i"; i=$((i + 1)); done ;;
  *) echo "  Personality functions: (count = 0)" ;;
esac
SH
chmod +x "$tmp/bin/lipo" "$tmp/bin/xcrun"
run() { COUNT="$1" PATH="$tmp/bin:$PATH" bash "$CHECK" "$tmp/App.app" >/dev/null 2>&1; }
run 3 || { echo "FAIL: three routines with a long table must pass" >&2; exit 1; }
if run 4; then echo "FAIL: four routines must fail" >&2; exit 1; fi
if run 0; then echo "FAIL: no personality table at all must fail" >&2; exit 1; fi
echo "PASS: check-app-personalities.sh counts routines and survives a long table"
