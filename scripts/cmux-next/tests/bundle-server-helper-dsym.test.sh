#!/usr/bin/env bash
# bundle-server-helper.sh compiles the server helper with -gline-tables-only
# only where dsymutil exists. With debug info, the
# swift driver runs dsymutil at the link and stops with
# `unableToFind(tool: "dsymutil")` when there is none: the Linux pool's
# server-helper step (job 97f92c02180a0a75fb769144). A Mac always has
# /usr/bin/dsymutil and keeps its dSYM; a host without one builds the helper
# without debug info, as before p09-085. xcrun, plutil and dsymutil are
# stubs: no compiler, no signing; runs on Linux.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'bundle-server-helper-dsym: %s\n' "$*" >&2; exit 1; }
mkdir -p "$TMP/bin" "$TMP/dsymutil-bin" "$TMP/build/app.app/Contents/Resources/bin" "$TMP/temp"
cat > "$TMP/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
# xcrun swiftc ...: log the arguments, create every -o / -emit-module-path output.
tool="$1"; shift
[[ "$tool" == swiftc ]] || exit 1
printf '%s\n' "$*" >> "$XCRUN_LOG"
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" || "$prev" == "-emit-module-path" ]]; then mkdir -p "$(dirname "$arg")"; : > "$arg"; fi
  prev="$arg"
done
STUB
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/plutil"
printf '#!/bin/sh\nexit 0\n' > "$TMP/dsymutil-bin/dsymutil"
chmod +x "$TMP/bin/xcrun" "$TMP/bin/plutil" "$TMP/dsymutil-bin/dsymutil"
run() { # <PATH>
  : > "$TMP/xcrun.log"
  env -i PATH="$1" HOME="$TMP" XCRUN_LOG="$TMP/xcrun.log" TARGET_BUILD_DIR="$TMP/build" WRAPPER_NAME=app.app \
    TARGET_TEMP_DIR="$TMP/temp" SRCROOT="$ROOT" ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CONFIGURATION=Debug \
    PRODUCT_BUNDLE_IDENTIFIER=com.cmuxterm.app.debug.testtag \
    /bin/bash "$ROOT/scripts/cmux-next/bundle-server-helper.sh" > "$TMP/out" 2>&1 || true
  [[ -s "$TMP/xcrun.log" ]] || fail "no swiftc ran: $(cat "$TMP/out")"
}
link_line() { grep -- '-module-name cmux_server_helper' "$TMP/xcrun.log" || fail "no link of cmux-server-helper"; }

# A host without dsymutil: the helper links with no debug info.
[[ ! -x /usr/bin/dsymutil && ! -x /bin/dsymutil ]] || { echo "bundle-server-helper-dsym: skipped (this host has a dsymutil on the test PATH)"; exit 0; }
run "$TMP/bin:/usr/bin:/bin"
if link_line | grep -q -- '-gline-tables-only'; then fail "the helper links with -gline-tables-only on a host with no dsymutil"; fi
if grep -q -- '-gline-tables-only' "$TMP/xcrun.log"; then fail "a module compiles with -gline-tables-only on a host with no dsymutil"; fi
grep -q 'without a dSYM' "$TMP/out" || fail "the phase did not say the helper has no dSYM: $(cat "$TMP/out")"

# A host with dsymutil (a Mac): line tables, so the dSYM is written.
run "$TMP/bin:$TMP/dsymutil-bin:/usr/bin:/bin"
link_line | grep -q -- '-gline-tables-only' || fail "the helper links without -gline-tables-only on a host with dsymutil"
echo "bundle-server-helper-dsym: ok"
