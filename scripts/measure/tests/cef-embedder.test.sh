#!/usr/bin/env bash
# scripts/measure/cef-embedder.sh with a read-only CEF dist, as the fleet seeds $CMUX_CI_CEF_DIR. The fork's
# runner copies the dist's framework into its test app and re-signs the copy; with the dist read-only the copy
# was read-only, codesign failed with its stderr hidden, and no case ran (fleet steps 6d191ccb and 100ec79a,
# 2026-11-02: "cmux-embedder: 0/14 passed"), and the worker could not remove the step's files. Runs on Linux
# and macOS with a fake runner that needs a writable framework copy, as the real one does.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../cef-embedder.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/cef-embedder-test.XXXXXX")"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
REF=1c8c314e580ab5630f79e6cb969d58e6be358960
FW="Chromium Embedded Framework.framework"

# The seeded dist: read-only, as the fleet worker unpacks it.
dist="$work/seed/cef-x"
mkdir -p "$dist/$FW/Resources/id.lproj" "$dist/include" "$dist/libcef_dll"
printf 'int cmux_cef_api_version(void);\n#define CMUX_CEF_API_VERSION 24\n' >"$dist/include/cef_cmux.h"
echo pak >"$dist/$FW/Resources/id.lproj/locale.pak"
chmod -R a-w "$work/seed"

# The test sources: REF and a fake runner. Like the real one it copies the framework into an app under the
# work dir and writes into that copy (codesign does); it fails before its first case when it cannot.
mk_sources() { # mk_sources <runner body> -> prints the archive's sha256
  rm -rf "$work/s" && mkdir -p "$work/s/src/scripts" "$work/s/src/tests/cmux_embedder"
  printf '%s\n' "$REF" >"$work/s/src/REF"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$1" >"$work/s/src/scripts/test-cmux-embedder.sh"
  tar -C "$work/s" -czf "$work/src.tar.gz" src
  mkdir -p "$work/in" && cp "$work/src.tar.gz" "$work/in/$(sha "$work/src.tar.gz")"
  sha "$work/src.tar.gz"
}
runner='app="$CMUX_EMBEDDER_TEST_DIR/App.app/Contents/Frameworks"; mkdir -p "$app"
cp -R "$1/Chromium Embedded Framework.framework" "$app/"
touch "$app/Chromium Embedded Framework.framework/_CodeSignature" 2>/dev/null || exit 1
shift; for c in "$@"; do echo "==> case $c"; echo "    PASS ($c, exit 0, 1s)"; done'
run() { CMUX_CI_CEF_DIR="$work/seed" CI_JOB_DIR="$work/job" CMUX_EMBEDDER_INPUT_DIR="$work/in" \
  bash "$script" "$@" >"$work/out" 2>&1; }

SRC="sha256:$(mk_sources "$runner")"
run "$SRC" "$REF" parent-dealloc-hidden signals || { cat "$work/out"; fail "a run on a read-only dist ran no case"; }
grep -qx 'cmux-embedder: 2/2 passed' "$work/out" || { cat "$work/out"; fail "no 2/2 summary"; }
[ -w "$dist/$FW" ] && fail "the seeded dist was made writable (it must stay as the worker seeded it)"
rm -rf "$work/job" 2>/dev/null || fail "the step's files cannot be removed (the worker cleanup failed this way)"

# A runner that stops before its first case says so, not only "0/N passed".
SRC="sha256:$(mk_sources 'echo "codesign: some error" >&2; exit 1')"
if run "$SRC" "$REF" signals; then fail "a runner that stopped passed the step"; fi
grep -q 'stopped (exit 1) before its first case' "$work/out" || { cat "$work/out"; fail "an early stop was not named"; }
echo "cef-embedder: ok"
