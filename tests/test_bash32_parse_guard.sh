#!/usr/bin/env bash
# Behavior test: a script that macOS /bin/bash 3.2 cannot parse fails, both in
# scripts/ci/check-bash32-parse.sh and when notarize-nightly-dmg.sh runs.
# Runs on a macOS runner (signing-keychain-macos.yml, bash32-syntax), where
# /bin/bash is 3.2. CMUX_PARSE_BASH can point at another bash 3.2.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PARSE_BASH="${CMUX_PARSE_BASH:-/bin/bash}"
case "$("$PARSE_BASH" -c 'echo "${BASH_VERSINFO[0]}"')" in
  3) ;;
  *) echo "SKIP: $PARSE_BASH is not bash 3 (this test needs the macOS /bin/bash)"; exit 0 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The construct that broke nightly-next runs 39014131817 and 39014922771: a
# heredoc inside $(...) whose body has an apostrophe.
broken_function() {
  cat <<'SH'
broken_clock() {
  verdict="$(python3 - <<'PY'
# Apple's dates
print("x")
PY
)"
}
SH
}

# 1. The control: bash 3.2 really exits 0 on this parse error once an EXIT
#    trap is set. If this ever changes, the guards are still right, but say so.
{
  echo 'set -euo pipefail'
  echo 'trap "rm -f /dev/null.never" EXIT'
  broken_function
} >"$work/trap-masks.sh"
set +e
"$PARSE_BASH" "$work/trap-masks.sh" >/dev/null 2>&1
masked=$?
set -e
echo "control: bash 3.2 exit status of a parse error under an EXIT trap: $masked"

# 2. check-bash32-parse.sh fails on a broken scripts/ci file and names it, and
#    passes on a tree without one.
mkdir -p "$work/tree/scripts/ci/lib" "$work/tree/.github/workflows"
printf '#!/usr/bin/env bash\necho ok\n' >"$work/tree/scripts/ci/good.sh"
printf '#!/usr/bin/env bash\necho ok\n' >"$work/tree/scripts/named.sh"
printf 'run: ./scripts/named.sh\n' >"$work/tree/.github/workflows/w.yml"
CMUX_PARSE_ROOT="$work/tree" CMUX_PARSE_BASH="$PARSE_BASH" \
  "$ROOT_DIR/scripts/ci/check-bash32-parse.sh" .github/workflows/w.yml >"$work/ok.out" 2>&1 \
  || { cat "$work/ok.out"; fail "check-bash32-parse.sh refused a tree that parses"; }
grep -q 'Parsed 2 script' "$work/ok.out" || { cat "$work/ok.out"; fail "the workflow-named script was not parsed"; }

{ echo '#!/usr/bin/env bash'; broken_function; } >"$work/tree/scripts/ci/lib/broken.sh"
set +e
CMUX_PARSE_ROOT="$work/tree" CMUX_PARSE_BASH="$PARSE_BASH" \
  "$ROOT_DIR/scripts/ci/check-bash32-parse.sh" .github/workflows/w.yml >"$work/bad.out" 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || { cat "$work/bad.out"; fail "check-bash32-parse.sh passed a broken scripts/ci file"; }
grep -q 'scripts/ci/lib/broken.sh' "$work/bad.out" || { cat "$work/bad.out"; fail "the broken file is not named"; }

# A broken script that only the workflow names is caught too.
rm "$work/tree/scripts/ci/lib/broken.sh"
{ echo '#!/usr/bin/env bash'; broken_function; } >"$work/tree/scripts/named.sh"
set +e
CMUX_PARSE_ROOT="$work/tree" CMUX_PARSE_BASH="$PARSE_BASH" \
  "$ROOT_DIR/scripts/ci/check-bash32-parse.sh" .github/workflows/w.yml >"$work/named.out" 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || { cat "$work/named.out"; fail "check-bash32-parse.sh passed a broken workflow-named script"; }

# 3. notarize-nightly-dmg.sh with the same broken code appended exits 2 under
#    /bin/bash 3.2, before it touches anything, instead of the old exit 0.
cp "$ROOT_DIR/scripts/ci/notarize-nightly-dmg.sh" "$work/notarize-broken.sh"
broken_function >>"$work/notarize-broken.sh"
set +e
"$PARSE_BASH" "$work/notarize-broken.sh" "$work/none.app" "$work/r.dmg" "$work/i.dmg" >"$work/notarize.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || { cat "$work/notarize.out"; fail "a broken notarize-nightly-dmg.sh exited $status, not 2"; }
grep -q 'does not parse' "$work/notarize.out" || { cat "$work/notarize.out"; fail "no parse error message"; }

# 4. The real script parses under bash 3.2 and still fails on a missing app.
"$PARSE_BASH" -n "$ROOT_DIR/scripts/ci/notarize-nightly-dmg.sh" || fail "notarize-nightly-dmg.sh does not parse"
set +e
"$PARSE_BASH" "$ROOT_DIR/scripts/ci/notarize-nightly-dmg.sh" "$work/none.app" "$work/r.dmg" "$work/i.dmg" >"$work/missing.out" 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || { cat "$work/missing.out"; fail "notarize-nightly-dmg.sh exited 0 for a missing app"; }

# 5. A failure after the EXIT trap is set keeps its status: every tool the
#    script calls is a stub that exits 7, so the first one ends the run with 7.
mkdir -p "$work/stub-bin" "$work/stub.app/Contents/Library"
printf '#!/bin/sh\nexit 7\n' >"$work/stub-bin/fail7"
chmod +x "$work/stub-bin/fail7"
stub="$work/stub-bin/fail7"
set +e
APPLE_SIGNING_IDENTITY=stub CMUX_SKIP_NOTARIZATION=true CMUX_STAPLE_APP_IN_DMG=false \
  CMUX_CREATE_DMG_TOOL="$stub" CMUX_CODESIGN_TOOL="$stub" CMUX_XCRUN_TOOL="$stub" \
  CMUX_HDIUTIL_TOOL="$stub" CMUX_SPCTL_TOOL="$stub" CMUX_SMOKE_TOOL="$stub" \
  CMUX_VERIFY_METADATA_TOOL="$stub" CMUX_VERIFY_LICENSES_TOOL="$stub" \
  CMUX_NOTARIZE_COMPUTER_USE_HELPER_TOOL="$stub" CMUX_SIGNING_KEYCHAIN_TOOL="$stub" \
  "$PARSE_BASH" "$ROOT_DIR/scripts/ci/notarize-nightly-dmg.sh" "$work/stub.app" "$work/r.dmg" "$work/i.dmg" >"$work/trap.out" 2>&1
status=$?
set -e
[ "$status" -eq 7 ] || { cat "$work/trap.out"; fail "a failing tool after the EXIT trap gave exit $status, not 7"; }

echo "PASS: bash 3.2 parse guards (check-bash32-parse.sh, notarize-nightly-dmg.sh)"
