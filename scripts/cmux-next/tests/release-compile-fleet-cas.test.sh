#!/usr/bin/env bash
# release-compile-fleet-cas.sh builds the Release compile from the host's canonical root through
# the fleet-cas node when it can, and the old way when it cannot; check-release-compile.sh passes
# the cache settings to xcodebuild and drops them after a cache failure.
# Stubs: fleet-cas-settings.sh (node up or down) and check-release-compile.sh (records how it ran)
# in a scratch git workspace; for check-release-compile.sh itself, a stub xcodebuild.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cmux-release-fleet-cas-test.XXXXXX")
SOCKDIR=$(mktemp -d /tmp/rcfc.XXXXXX)  # short: a Unix socket path has a length limit
trap 'rm -rf "$TMP" "$SOCKDIR"' EXIT
fail() { printf 'FAIL: %s\n' "$1"; cat "$TMP/out" 2>/dev/null || true; exit 1; }

# A workspace with the wrapper and its helpers, and a stub check-release-compile.sh.
WS="$TMP/ws"
mkdir -p "$WS/scripts/cmux-next" "$WS/scripts/ci"
cp "$ROOT/scripts/cmux-next/release-compile-fleet-cas.sh" "$ROOT/scripts/cmux-next/host_build_lock.py" "$WS/scripts/cmux-next/"
cp "$ROOT/scripts/ci/canonical-build-root.sh" "$ROOT/scripts/ci/apfs_clone.py" "$WS/scripts/ci/"
cat > "$WS/scripts/cmux-next/check-release-compile.sh" <<EOF
#!/bin/bash
{ echo "script=\$0"; echo "dd=\$1"; echo "fsmode=\${XCBUILD_FILE_SYSTEM_MODE-}"; echo "settings<<"; printf '%s\n' "\${CMUX_NEXT_RELEASE_XCODE_SETTINGS-UNSET}"; echo ">>"; } > "$TMP/called"
exit "\${STUB_STATUS:-0}"
EOF
chmod +x "$WS/scripts/cmux-next/check-release-compile.sh"
git -C "$WS" init -q && git -C "$WS" add -A && git -C "$WS" -c user.name=t -c user.email=t@t commit -qm ws
HEAD=$(git -C "$WS" rev-parse HEAD)

FLEET="$TMP/fleet"
mkdir -p "$FLEET/bin"
cat > "$FLEET/bin/fleet-cas-settings.sh" <<'EOF'
#!/bin/bash
[[ "${STUB_NODE:-up}" == up ]] || { echo "node down" >&2; exit 1; }
printf '%s\n' COMPILATION_CACHE_ENABLE_PLUGIN=YES "COMPILATION_CACHE_REMOTE_SERVICE_PATH=$1" \
  COMPILATION_CACHE_CAS_PATH=/helper/cas
EOF
chmod +x "$FLEET/bin/fleet-cas-settings.sh"
# The node's socket: a bound Unix socket (nothing listens; the stub helper answers for the node).
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SOCKDIR/s"
ln -s "$SOCKDIR/s" "$FLEET/fleet-cas.sock"
CROOT="$FLEET/next-release"

run() {  # MODE [VAR=VALUE...]
  local mode=$1; shift
  rm -f "$TMP/called" "$TMP/genv"; touch "$TMP/genv"
  env -i PATH=/usr/bin:/bin HOME="$TMP" TMPDIR="$TMP" FLEET_CAS_ROOT="$FLEET" GITHUB_ENV="$TMP/genv" \
    CMUX_NEXT_RELEASE_FLEET_CAS="$mode" "$@" \
    /bin/bash "$WS/scripts/cmux-next/release-compile-fleet-cas.sh" "$TMP/fallback-dd" >"$TMP/out" 2>&1
}
called() { sed -n "s/^$1=//p" "$TMP/called"; }
settings() { sed -n '/^settings<</,/^>>/p' "$TMP/called"; }

# 1. off: the checkout's own script into the fallback DerivedData, with no cache settings.
run off || fail "off exited $?"
[[ "$(called script)" == "$WS/scripts/cmux-next/check-release-compile.sh" ]] || fail "off ran $(called script)"
[[ "$(called dd)" == "$TMP/fallback-dd" ]] || fail "off built into $(called dd)"
settings | grep -q UNSET || fail "off passed cache settings"
grep -q "CMUX_NEXT_RELEASE_DERIVED_DATA=$TMP/fallback-dd" "$TMP/genv" || fail "off did not export its DerivedData"

# 2. read with the node up: the clone's script, the canonical DerivedData, the cache settings.
run read || fail "read exited $?"
[[ "$(called script)" == "$CROOT/src/scripts/cmux-next/check-release-compile.sh" ]] || fail "read ran $(called script)"
[[ "$(called dd)" == "$CROOT/DerivedData" ]] || fail "read built into $(called dd)"
[[ "$(git -C "$CROOT/src" rev-parse HEAD)" == "$HEAD" ]] || fail "the canonical tree is not at HEAD"
for want in COMPILATION_CACHE_ENABLE_CACHING=YES "COMPILATION_CACHE_CAS_PATH=$FLEET/cas" \
  COMPILATION_CACHE_ENABLE_PLUGIN=YES "COMPILATION_CACHE_REMOTE_SERVICE_PATH=$FLEET/fleet-cas.sock"; do
  settings | grep -qxF -- "$want" || fail "read did not pass $want"
done
! settings | grep -qxF COMPILATION_CACHE_CAS_PATH=/helper/cas || fail "read passed the helper's own CAS path"
grep -q "CMUX_NEXT_RELEASE_DERIVED_DATA=$CROOT/DerivedData" "$TMP/genv" || fail "read did not export the canonical DerivedData"
[[ "$(called fsmode)" == checksum-only ]] || fail "read did not judge changes by content"

# 3. read keeps the canonical DerivedData (incremental); write empties it but for SourcePackages.
mkdir -p "$CROOT/DerivedData/Build" "$CROOT/DerivedData/SourcePackages"
touch "$CROOT/DerivedData/Build/kept.o" "$CROOT/DerivedData/SourcePackages/pkg"
run read || fail "read (kept) exited $?"
[[ -e "$CROOT/DerivedData/Build/kept.o" ]] || fail "read removed the kept DerivedData"
run write || fail "write exited $?"
[[ "$(called dd)" == "$CROOT/DerivedData" ]] || fail "write built into $(called dd)"
[[ ! -e "$CROOT/DerivedData/Build" ]] || fail "write kept earlier build products"
[[ -e "$CROOT/DerivedData/SourcePackages/pkg" ]] || fail "write removed the package checkouts"

# 4. The node down: read builds the old way, write refuses with 3 and builds nothing.
run read STUB_NODE=down || fail "read (node down) exited $?"
[[ "$(called dd)" == "$TMP/fallback-dd" ]] || fail "read with the node down built into $(called dd)"
settings | grep -q UNSET || fail "read with the node down passed cache settings"
status=0; run write STUB_NODE=down || status=$?
[[ $status -eq 3 && ! -e "$TMP/called" ]] || fail "write with the node down exited $status or built"
# No socket (a helper that still answers): the node is not there, so read falls back at once.
mv "$FLEET/fleet-cas.sock" "$TMP/sock.away"
run read || fail "read (no socket) exited $?"
[[ "$(called dd)" == "$TMP/fallback-dd" ]] || fail "read with no socket built into $(called dd)"
mv "$TMP/sock.away" "$FLEET/fleet-cas.sock"

# 5. Another build holds the root: read builds the old way at once, write refuses with 75.
exec 8>>"$CROOT/lock"
python3 -I "$WS/scripts/cmux-next/host_build_lock.py" acquire "$CROOT/lock" --fd 8 || fail "test could not take the lock"
run read || fail "read (busy) exited $?"
[[ "$(called dd)" == "$TMP/fallback-dd" ]] || fail "read with a busy root built into $(called dd)"
status=0; run write || status=$?
[[ $status -eq 75 && ! -e "$TMP/called" ]] || fail "write with a busy root exited $status or built"
exec 8>&-
run read || fail "read after the lock went exited $?"
[[ "$(called dd)" == "$CROOT/DerivedData" ]] || fail "the root stayed locked after its holder closed it"

# 6. write is never a GitHub Actions job; an unknown mode is refused.
status=0; run write GITHUB_ACTIONS=true || status=$?
[[ $status -eq 2 && ! -e "$TMP/called" ]] || fail "write under GitHub Actions exited $status or built"
status=0; run maybe || status=$?
[[ $status -eq 2 && ! -e "$TMP/called" ]] || fail "an unknown mode exited $status or built"

# 7. The build's status comes back.
status=0; run read STUB_STATUS=65 || status=$?
[[ $status -eq 65 ]] || fail "read lost the build's status ($status)"

# 8. check-release-compile.sh: the settings reach xcodebuild; a malformed line is refused; a cache
#    failure builds once more without them, a code failure does not.
mkdir -p "$TMP/bin" "$TMP/dev" "$TMP/steptmp"
cat > "$TMP/bin/xcodebuild" <<EOF
#!/bin/bash
if [[ "\$1" == "-version" ]]; then echo "Xcode 26.6"; exit 0; fi
for arg in "\$@"; do [[ "\$arg" == -resolvePackageDependencies ]] && exit 0; done
n=\$(( \$(cat "$TMP/builds" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$TMP/builds"
printf '%s\n' "\$@" > "$TMP/argv.\$n"
if [[ -n "\${STUB_FAIL_WITH:-}" ]] && { [[ "\$n" == 1 ]] || [[ "\${STUB_FAIL_ALWAYS:-0}" == 1 ]]; }; then
  echo "\$STUB_FAIL_WITH"; exit 65
fi
exit 0
EOF
chmod +x "$TMP/bin/xcodebuild"
crc() {
  rm -f "$TMP/builds" "$TMP"/argv.*
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP/steptmp" CMUX_CI_STEP_KEY=test-step \
    DEVELOPER_DIR="$TMP/dev" CMUX_XCODEBUILD_HEARTBEAT_SECONDS=1 "$@" \
    /bin/bash "$ROOT/scripts/cmux-next/check-release-compile.sh" >"$TMP/out" 2>&1
}
SET=$'COMPILATION_CACHE_ENABLE_CACHING=YES\nCOMPILATION_CACHE_CAS_PATH=/x/cas'
crc CMUX_NEXT_RELEASE_XCODE_SETTINGS="$SET" || fail "check-release-compile with settings exited $?"
grep -qx COMPILATION_CACHE_ENABLE_CACHING=YES "$TMP/argv.1" && grep -qx COMPILATION_CACHE_CAS_PATH=/x/cas "$TMP/argv.1" \
  || fail "the settings did not reach xcodebuild"
status=0; crc CMUX_NEXT_RELEASE_XCODE_SETTINGS=$'A=1\nnot a setting' || status=$?
[[ $status -eq 2 && ! -e "$TMP/builds" ]] || fail "a malformed setting exited $status or built"
crc CMUX_NEXT_RELEASE_XCODE_SETTINGS="$SET" STUB_FAIL_WITH="error: CAS error encountered during compilation" \
  || fail "a cache failure was not rebuilt without the cache ($?)"
[[ "$(cat "$TMP/builds")" == 2 ]] || fail "a cache failure built $(cat "$TMP/builds") times"
! grep -q COMPILATION_CACHE "$TMP/argv.2" || fail "the rebuild after a cache failure kept the cache settings"
status=0; crc CMUX_NEXT_RELEASE_XCODE_SETTINGS="$SET" STUB_FAIL_ALWAYS=1 STUB_FAIL_WITH="Foo.swift:1:1: error: cannot find 'x' in scope" || status=$?
[[ $status -eq 65 && "$(cat "$TMP/builds")" == 1 ]] || fail "a code failure exited $status after $(cat "$TMP/builds") builds"
crc STUB_FAIL_ALWAYS=1 STUB_FAIL_WITH="error: CAS error encountered during compilation" && fail "no settings: a failure passed"
[[ "$(cat "$TMP/builds")" == 1 ]] || fail "without cache settings a cache-looking failure was retried"

# 9. The stale-module clear accepts the canonical root's DerivedData only when that root is exported.
#    Under /var/tmp: the guard accepts anything under /tmp already.
VT=$(mktemp -d /var/tmp/cmux-release-cas-root.XXXXXX); trap 'rm -rf "$TMP" "$SOCKDIR" "$VT"' EXIT
mkdir -p "$VT/DerivedData/Build" "$VT/DerivedData/SourcePackages" "$VT/other/Build"
touch "$VT/DerivedData/SourcePackages/pkg"
clear_dd() { env -i PATH=/usr/bin:/bin "$@" /bin/bash "$ROOT/scripts/cmux-next/clear-stale-scheme-build-state.sh" "$dd" >"$TMP/out" 2>&1; }
dd="$VT/DerivedData"; status=0; clear_dd || status=$?
[[ $status -eq 2 && -d "$VT/DerivedData/Build" ]] || fail "the canonical DerivedData was cleared without its root exported ($status)"
clear_dd CMUX_NEXT_RELEASE_CAS_ROOT="$VT" || fail "the canonical DerivedData was refused ($?)"
[[ ! -e "$VT/DerivedData/Build" && -e "$VT/DerivedData/SourcePackages/pkg" ]] || fail "the canonical DerivedData was not cleared to its packages"
dd="$VT/other"; status=0; clear_dd CMUX_NEXT_RELEASE_CAS_ROOT="$VT" || status=$?
[[ $status -eq 2 && -d "$VT/other/Build" ]] || fail "another directory under the root was cleared ($status)"
dd=/var/DerivedData; status=0; clear_dd CMUX_NEXT_RELEASE_CAS_ROOT=/var || status=$?
[[ $status -eq 2 ]] || fail "a shallow root was accepted ($status)"

echo "release-compile-fleet-cas: ok"
