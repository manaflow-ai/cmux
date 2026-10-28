#!/usr/bin/env bash
# check-cmux-scheme-compile.sh with CMUX_NEXT_BROWSER_DATA_IMPORT=compiled-out
# builds the browser-data import out the way nightly.yml builds every
# nightly-next app (cx-f58x): xcodebuild gets
# OTHER_SWIFT_FLAGS=$(inherited) -DCMUX_NO_PASSWORD_IMPORT -DCMUX_NO_BROWSER_DATA_IMPORT
# and sees an empty browser-sources.json, which is restored after the build,
# passed or failed. Without the variable nothing changes. Runs the script from
# a scratch copy of the repository layout so the real checkout is never edited;
# a stub xcodebuild records its arguments and the file it built.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cmux-scheme-import-test.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
repo="$TMP/repo"
sources="$repo/Packages/macOS/CmuxNext/Sources/CmuxNextBrowserImport/Resources/browser-sources.json"
mkdir -p "$repo/scripts/cmux-next/lib" "$repo/scripts/ci" "$(dirname "$sources")" "$TMP/bin" "$TMP/steptmp"
cp "$ROOT/scripts/cmux-next/check-cmux-scheme-compile.sh" "$repo/scripts/cmux-next/"
cp "$ROOT/scripts/cmux-next/lib/fleet-only.sh" "$ROOT/scripts/cmux-next/lib/workspace-resolved.sh" "$ROOT/scripts/cmux-next/lib/compilation-cache.sh" "$ROOT/scripts/cmux-next/lib/browser-sources-compiled-out.json" "$repo/scripts/cmux-next/lib/"
cat > "$repo/scripts/ci/run-xcodebuild-with-diagnostics.sh" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
chmod +x "$repo/scripts/ci/run-xcodebuild-with-diagnostics.sh"
original='{"schemaVersion": 1, "engines": {"chromium": {}}, "browsers": [{"id": "real"}]}'
cat > "$TMP/bin/xcodebuild" <<EOF
#!/bin/bash
if [[ "\$1" == "-version" ]]; then echo "Xcode 26.6"; exit 0; fi
printf '%s\n' "\$@" > "$TMP/args"
cat "$sources" > "$TMP/built-sources"
exit "\${STUB_XCODEBUILD_STATUS:-0}"
EOF
chmod +x "$TMP/bin/xcodebuild"

run() {
  printf '%s\n' "$original" > "$sources"
  rm -f "$TMP/args" "$TMP/built-sources"
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP/steptmp" CMUX_CI_STEP_KEY=test-step "$@" \
    /bin/bash "$repo/scripts/cmux-next/check-cmux-scheme-compile.sh" >"$TMP/out" 2>&1
}
fail() { printf 'FAIL: %s\n' "$1"; cat "$TMP/out"; exit 1; }
# shellcheck disable=SC2016 # $(inherited) is an Xcode build setting
flags='OTHER_SWIFT_FLAGS=$(inherited) -DCMUX_NO_PASSWORD_IMPORT -DCMUX_NO_BROWSER_DATA_IMPORT'
empty='{"schemaVersion": 1, "engines": {}, "browsers": []}'

# 1. Default: the import is built in; no flags, the file untouched.
run || fail "default run exited $?"
! grep -q '^OTHER_SWIFT_FLAGS=' "$TMP/args" || fail "the default build got OTHER_SWIFT_FLAGS"
[[ "$(cat "$TMP/built-sources")" == "$original" ]] || fail "the default build saw a changed browser-sources.json"

# 2. compiled-out: nightly's flags and empty file during the build, the file back after.
run CMUX_NEXT_BROWSER_DATA_IMPORT=compiled-out CMUX_NEXT_CONFIGURATION=Release || fail "compiled-out run exited $?"
grep -qxF "$flags" "$TMP/args" || fail "xcodebuild did not get: $flags"
[[ "$(cat "$TMP/built-sources")" == "$empty" ]] || fail "the build saw browser-sources.json: $(cat "$TMP/built-sources")"
[[ "$(cat "$sources")" == "$original" ]] || fail "browser-sources.json was not restored"
grep -q 'browser-data import compiled-out' "$TMP/out" || fail "the run did not say the import is compiled out"
[[ -z "$(ls -A "$TMP/steptmp")" ]] || fail "the run left files in TMPDIR: $(ls -A "$TMP/steptmp")"

# 3. A failed compiled-out build keeps its status and still restores the file.
status=0; run CMUX_NEXT_BROWSER_DATA_IMPORT=compiled-out STUB_XCODEBUILD_STATUS=65 || status=$?
[[ $status -eq 65 ]] || fail "failed compiled-out build exited $status (want 65)"
[[ "$(cat "$sources")" == "$original" ]] || fail "a failed build left browser-sources.json emptied"

# 4. Any other value builds the import in.
run CMUX_NEXT_BROWSER_DATA_IMPORT=built-in || fail "built-in run exited $?"
! grep -q '^OTHER_SWIFT_FLAGS=' "$TMP/args" || fail "built-in got OTHER_SWIFT_FLAGS"

printf 'scheme compile browser-data import tests: ok\n'
