#!/usr/bin/env bash
# The kept-DerivedData binary-module guard (scripts/ci/swiftpm-binary-module-guard.sh,
# xcode_binary_module_guard) resolves from the kept packages first, with no fetch
# (-skipPackageUpdates), and check-release-compile.sh then builds with
# -skipPackageUpdates too. On 2026-11-26 00:00-08:00Z GitHub answered the plain
# resolve's update fetches from the fleet's shared address with 403, about 430
# Release compiles failed in 1-2 min, and each emptied its kept DerivedData.
# A stub xcodebuild records every call's arguments; STUB_OFFLINE_STATUS fails
# the -skipPackageUpdates resolve (a pin the kept packages lack).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d /tmp/cmux-release-offline-test.XXXXXX); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/steptmp" "$TMP/dev"
cat > "$TMP/bin/xcodebuild" <<EOF
#!/bin/bash
if [[ "\$1" == "-version" ]]; then echo "Xcode 26.6"; exit 0; fi
printf '%s\n' "\$*" >> "$TMP/calls"
env | grep -E '^(GIT_CONFIG_|CMUX_GITHUB_GIT_TOKEN)' | sort > "$TMP/env.\$\$" 2>/dev/null; mv "$TMP/env.\$\$" "$TMP/env"
resolve=0 offline=0
for arg in "\$@"; do
  [[ "\$arg" == -resolvePackageDependencies ]] && resolve=1
  [[ "\$arg" == -skipPackageUpdates ]] && offline=1
done
if (( resolve )); then
  (( offline )) && exit "\${STUB_OFFLINE_STATUS:-0}"
  if [[ -n "\${STUB_RESOLVE_403:-}" ]]; then
    echo "fatal: unable to access 'https://github.com/getsentry/sentry-cocoa.git/': The requested URL returned error: 403"
    exit 1
  fi
  exit "\${STUB_RESOLVE_STATUS:-0}"
fi
exit 0
EOF
chmod +x "$TMP/bin/xcodebuild"

run() {  # DERIVED_DATA [ENV...]
  local dd="$1"; shift
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP/steptmp" \
    CMUX_CI_STEP_KEY=test-step DEVELOPER_DIR="$TMP/dev" \
    CMUX_XCODEBUILD_HEARTBEAT_SECONDS=1 "$@" \
    /bin/bash "$ROOT/scripts/cmux-next/check-release-compile.sh" "$dd" >"$TMP/out" 2>&1
}
fail() { printf 'FAIL: %s\n' "$1"; cat "$TMP/out"; [[ ! -f "$TMP/calls" ]] || cat "$TMP/calls"; exit 1; }
resolves() { grep -c -- '-resolvePackageDependencies' "$TMP/calls" || true; }
builds() { grep -v -- '-resolvePackageDependencies' "$TMP/calls" || true; }

# 1. Kept packages hold the pins: one resolve, offline; the build skips package updates too.
dd="$TMP/kept"; mkdir -p "$dd/SourcePackages/repositories" "$dd/Build/Products"; touch "$dd/Build/Products/kept.o"
rm -f "$TMP/calls"
run "$dd" || fail "offline run exited $?"
[[ $(resolves) -eq 1 ]] || fail "want 1 resolve, got $(resolves)"
grep -- '-resolvePackageDependencies' "$TMP/calls" | grep -q -- '-skipPackageUpdates' || fail "the resolve fetched updates"
builds | grep -q -- '-skipPackageUpdates' || fail "the build fetched package updates after an offline resolve"
grep -q 'resolved the packages from the kept SourcePackages' "$TMP/out" || fail "no offline resolve note"

# 2. A pin the kept packages lack: the offline resolve fails, the plain resolve fetches, the build may fetch.
rm -f "$TMP/calls"
run "$dd" STUB_OFFLINE_STATUS=74 || fail "fallback run exited $?"
[[ $(resolves) -eq 2 ]] || fail "want 2 resolves (offline then plain), got $(resolves)"
grep -- '-resolvePackageDependencies' "$TMP/calls" | sed -n 2p | grep -q -- '-skipPackageUpdates' \
  && fail "the fallback resolve skipped package updates"
builds | grep -q -- '-skipPackageUpdates' && fail "the build skipped package updates after a fetched resolve"

# 3. No kept packages: one plain resolve, no offline try.
dd="$TMP/fresh"; mkdir -p "$dd"
rm -f "$TMP/calls"
run "$dd" || fail "fresh run exited $?"
[[ $(resolves) -eq 1 ]] || fail "want 1 resolve with no kept packages, got $(resolves)"
grep -q -- '-skipPackageUpdates' "$TMP/calls" && fail "skipped package updates with no kept packages"

# 4. CMUX_XCODE_RESOLVE_OFFLINE_FIRST=0 turns the offline try off.
dd="$TMP/kept"
rm -f "$TMP/calls"
run "$dd" CMUX_XCODE_RESOLVE_OFFLINE_FIRST=0 || fail "opt-out run exited $?"
grep -q -- '-skipPackageUpdates' "$TMP/calls" && fail "offline resolve ran with CMUX_XCODE_RESOLVE_OFFLINE_FIRST=0"

# 5. GitHub refuses every fetch (403): tried again, then 75 with no build, and the kept
#    outputs and header digest stay for the next resolve that succeeds.
dd="$TMP/refused"; mkdir -p "$dd/SourcePackages/repositories" "$dd/Build/Products"
run "$dd" || fail "seed run exited $?"
mkdir -p "$dd/Build/Products"; touch "$dd/Build/Products/kept.o"; stamp_before=$(cat "$dd/.cmux-binary-module-inputs")
rm -f "$TMP/calls"
code=0; run "$dd" STUB_OFFLINE_STATUS=74 STUB_RESOLVE_403=1 CMUX_SWIFTPM_RESOLVE_RETRY_DELAYS="0 0" || code=$?
[[ $code -eq 75 ]] || fail "want exit 75 when every fetch is refused, got $code"
[[ $(resolves) -eq 4 ]] || fail "want 4 resolves (offline, then 3 tries), got $(resolves)"
[[ -z "$(builds)" ]] || fail "a build ran on unresolved packages"
[[ -f "$dd/Build/Products/kept.o" ]] || fail "the kept build outputs were removed after a refused fetch"
[[ "$(cat "$dd/.cmux-binary-module-inputs" 2>/dev/null)" == "$stamp_before" ]] || fail "the header digest changed after a refused fetch"
grep -q 'fetch failed, no build ran' "$TMP/out" || fail "no fetch-failed note"

# 6. CMUX_GITHUB_GIT_TOKEN: every xcodebuild sees the token as a github.com header in
#    GIT_CONFIG_*, never the variable itself; one config the caller passed is kept.
dd="$TMP/kept"
rm -f "$TMP/calls"
run "$dd" CMUX_GITHUB_GIT_TOKEN=tok123 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.x GIT_CONFIG_VALUE_0=y || fail "token run exited $?"
want="AUTHORIZATION: basic $(printf 'x-access-token:tok123' | base64 | tr -d '\n')"
grep -qx 'GIT_CONFIG_COUNT=2' "$TMP/env" || fail "want GIT_CONFIG_COUNT=2: $(cat "$TMP/env")"
grep -qx 'GIT_CONFIG_KEY_0=core.x' "$TMP/env" || fail "the caller's git config was dropped"
grep -qx 'GIT_CONFIG_KEY_1=http.https://github.com/.extraheader' "$TMP/env" || fail "no github.com header key"
grep -qxF "GIT_CONFIG_VALUE_1=$want" "$TMP/env" || fail "wrong github.com header"
grep -q '^CMUX_GITHUB_GIT_TOKEN=' "$TMP/env" && fail "the raw token reached xcodebuild"
grep -q tok123 "$TMP/out" && fail "the token was printed"

# 7. No token: no header.
rm -f "$TMP/calls"
run "$dd" || fail "no-token run exited $?"
grep -q GIT_CONFIG "$TMP/env" && fail "a git header without a token: $(cat "$TMP/env")"

echo "release-compile-offline-resolve: ok"
