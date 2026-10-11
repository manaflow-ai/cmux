#!/usr/bin/env bash
# scripts/ci/tests/ensure-web-bundles.test.sh: the fleet Swift lane builds the cmux-next web
# bundles before its Swift run. Since the bundles are build output (cx-vn5), a cmux-ci suite
# step that skipped them failed every page-bundle suite (IconPickerOpenTests and
# PageRouterTests on cmux-ci step 41ed80a6). ensure-web-bundles.sh keeps a source-keyed cache:
# a hit installs it with --from, a miss builds into the cache with --out-root and installs it,
# and a checkout whose bundles are current builds nothing. It puts the pinned bun first on PATH.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$ROOT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

# Fake build-web-bundles.sh: records each call; --verify passes once a --from ran.
cat > "$WORK/build" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$1" in
  --verify) [ -f "$STATE/installed" ] ;;
  --out-root) mkdir -p "$2/Packages"; echo bundle > "$2/Packages/built" ;;
  --from) [ -f "$2/Packages/built" ] && touch "$STATE/installed" ;;
esac
EOF
# Fake toolchain at the pins: bun 1.4.2, node 24.11.1.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho 1.4.2\n' > "$WORK/bin/bun"
printf '#!/bin/sh\necho v24.11.1\n' > "$WORK/bin/node"
chmod +x "$WORK/build" "$WORK/bin/bun" "$WORK/bin/node"

run() {
  CALLS="$WORK/calls" STATE="$WORK/state" PATH="$WORK/bin:$PATH" \
    CMUX_WEB_BUNDLES_BUILD="$WORK/build" CMUX_WEB_BUNDLES_KEY=k1 CMUX_CI_CACHE_DIR="$WORK/cache" \
    bash scripts/ci/ensure-web-bundles.sh
}

# A miss builds into the cache under the source key and installs from it.
mkdir -p "$WORK/state"; : > "$WORK/calls"
run > "$WORK/out" 2>&1 || { cat "$WORK/out"; fail "a cache miss must build and install"; }
grep -q -- "^--out-root $WORK/cache/web-bundles/k1.tmp" "$WORK/calls" || fail "a miss must build with --out-root into the cache: $(cat "$WORK/calls")"
grep -qx -- "--from $WORK/cache/web-bundles/k1" "$WORK/calls" || fail "a miss must install the cached build with --from: $(cat "$WORK/calls")"
[ -f "$WORK/cache/web-bundles/k1/Packages/built" ] || fail "a miss must keep the build under its source key"

# A hit installs from the cache and builds nothing.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"; : > "$WORK/calls"
run > "$WORK/out" 2>&1 || { cat "$WORK/out"; fail "a cache hit must install"; }
grep -q -- "^--out-root" "$WORK/calls" && fail "a hit must not build: $(cat "$WORK/calls")"
grep -qx -- "--from $WORK/cache/web-bundles/k1" "$WORK/calls" || fail "a hit must install with --from: $(cat "$WORK/calls")"

# Current bundles: nothing to do.
: > "$WORK/calls"
run > "$WORK/out" 2>&1 || { cat "$WORK/out"; fail "current bundles must pass"; }
[ "$(cat "$WORK/calls")" = "--verify" ] || fail "current bundles must only be verified: $(cat "$WORK/calls")"

# A failed build is an error and caches nothing.
printf '#!/usr/bin/env bash\necho "$*" >> "$CALLS"\n[ "$1" = --verify ] && exit 1\n[ "$1" = --out-root ] && exit 7\nexit 0\n' > "$WORK/build"
rm -rf "$WORK/state" "$WORK/cache"; mkdir -p "$WORK/state"; : > "$WORK/calls"
if run > "$WORK/out" 2>&1; then fail "a failed bundle build must fail the lane"; fi
[ ! -e "$WORK/cache/web-bundles/k1" ] || fail "a failed build must not be cached"

# Two jobs on one host miss the same key at once (cx-t3e5 review of hq PR 1610): each
# builds into its own temp dir, and the loser of the publish discards its build
# instead of nesting it inside the winner's entry.
cat > "$WORK/build" <<'EOF2'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$1" in
  --verify) [ -f "$STATE/installed" ] ;;
  --out-root)
    mkdir -p "$2/Packages"; echo mine > "$2/Packages/built"
    # The other job published the same key while this build ran.
    mkdir -p "$CMUX_CI_CACHE_DIR/web-bundles/k1/Packages"; echo theirs > "$CMUX_CI_CACHE_DIR/web-bundles/k1/Packages/built" ;;
  --from) [ -f "$2/Packages/built" ] && touch "$STATE/installed" ;;
esac
EOF2
chmod +x "$WORK/build"
rm -rf "$WORK/state" "$WORK/cache"; mkdir -p "$WORK/state"; : > "$WORK/calls"
run > "$WORK/out" 2>&1 || { cat "$WORK/out"; fail "a lost publish race must still install the published build"; }
[ "$(cat "$WORK/cache/web-bundles/k1/Packages/built")" = theirs ] || fail "the published entry was overwritten"
leftovers=$(find "$WORK/cache/web-bundles" -name 'k1.tmp*' | wc -l | tr -d ' ')
[ "$leftovers" = 0 ] || fail "a lost race left $leftovers temp dir(s): $(find "$WORK/cache/web-bundles")"
[ ! -e "$WORK/cache/web-bundles/k1/k1.tmp" ] || fail "the build was nested inside the published entry"

# CMUX_WEB_BUNDLES_NO_INSTALL=1 (nx-remote): a missing pinned bun is an error, never a curl.
printf '#!/bin/sh\necho 1.0.0\n' > "$WORK/bin/bun"
printf '#!/bin/sh\necho "curl ran" >> "%s/curl"\nexit 1\n' "$WORK" > "$WORK/bin/curl"; chmod +x "$WORK/bin/curl"
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
if CMUX_WEB_BUNDLES_NO_INSTALL=1 run > "$WORK/out" 2>&1; then fail "NO_INSTALL with the wrong bun must fail"; fi
[ ! -e "$WORK/curl" ] || fail "NO_INSTALL must never run curl"
grep -q "CMUX_WEB_BUNDLES_NO_INSTALL" "$WORK/out" || fail "NO_INSTALL failure must say why: $(cat "$WORK/out")"
printf '#!/bin/sh\necho 1.4.2\n' > "$WORK/bin/bun"

# The Swift lane calls it before it builds a CmuxNext package.
for phase_fn in run_suite run_package_tests; do
  body=$(awk "/^$phase_fn\\(\\) \\{/,/^\\}/" scripts/ci/package-test-lane.sh)
  [ -n "$body" ] || { fail "package-test-lane.sh has no $phase_fn"; continue; }
  ensure_line=$(grep -n "ensure_web_bundles" <<<"$body" | head -1 | cut -d: -f1)
  build_line=$(grep -nE "swift build|prebuild_packages" <<<"$body" | head -1 | cut -d: -f1)
  if [ -z "$ensure_line" ] || [ -z "$build_line" ] || [ "$ensure_line" -gt "$build_line" ]; then
    fail "$phase_fn must call ensure_web_bundles before swift build"
  fi
done

if [ "$fails" -ne 0 ]; then exit 1; fi
echo "ensure-web-bundles: ok"
