#!/usr/bin/env bash
# Run check-release-compile.sh against the fleet's shared compile cache.
#
# usage: release-compile-fleet-cas.sh FALLBACK_DERIVED_DATA
#
# The fleet compile cache is glaeda's fleet-cas: Xcode's compilation cache,
# served on every owned mini by a local node (FLEET_CAS_ROOT/fleet-cas.sock)
# whose upstream is the one store on cmux-lawrence's external SSD. Only the
# trusted writer mini fills it: its node signs every entry, the store takes
# writes only from that host and only signed entries, and every reader node is
# read-only and drops an entry whose signature does not verify against the
# trusted key. An entry is keyed by the compile job's full inputs, so it is
# bound to the toolchain and the build flags.
#
# Those keys also hold the absolute source and DerivedData paths, so a hit
# needs the writer and the reader to build from the same paths. Both build from
# one canonical root per host, CMUX_NEXT_RELEASE_CAS_ROOT (default
# FLEET_CAS_ROOT/next-release): ROOT/src is an exact clone of the checkout
# (canonical-build-root.sh) and ROOT/DerivedData the DerivedData. A flock on
# ROOT/lock (host_build_lock.py, never waited for) keeps it to one build at a
# time; the lock goes with the last child holding it.
#
# CMUX_NEXT_RELEASE_FLEET_CAS:
#   off (default)  check-release-compile.sh FALLBACK_DERIVED_DATA, as before.
#   read           CI on an owned mini. With the node answering and the root
#                  free, build in the canonical root. Its DerivedData is kept,
#                  so the build is incremental from the host's last Release
#                  compile there (changes judged by content, not file times),
#                  and every task that has to run asks the cache first. A node that does not answer, a busy root or a
#                  failed clone builds the fallback way at once; nothing waits.
#   write          The trusted writer only (cmuxterm-hq build-fleet catch-up
#                  fill, under fleet-cas-writer-build.sh, which publishes the
#                  fill's marker). Refused in GitHub Actions. The DerivedData
#                  is emptied except SourcePackages, so every task runs and
#                  reaches the store. A down node or busy root is an error.
#
# Exit: check-release-compile.sh's status; 2 usage or refused write; 3 (write)
# the node is down; 75 (write) the root is busy or could not be set up.
set -euo pipefail

fallback_dd="${1:?usage: release-compile-fleet-cas.sh FALLBACK_DERIVED_DATA}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
workspace="$(cd "$here/../.." && pwd -P)"
mode="${CMUX_NEXT_RELEASE_FLEET_CAS:-off}"
fleet_root="${FLEET_CAS_ROOT:-/Users/Shared/cmux-build-fleet/xcode}"
cas_root="${CMUX_NEXT_RELEASE_CAS_ROOT:-$fleet_root/next-release}"

case "$mode" in
  off|read|write) ;;
  *) echo "release-compile-fleet-cas: CMUX_NEXT_RELEASE_FLEET_CAS must be off, read or write, not '$mode'" >&2; exit 2 ;;
esac
if [[ "$mode" == write && "${GITHUB_ACTIONS:-}" == true ]]; then
  echo "release-compile-fleet-cas: write is the trusted writer's fill only, never a GitHub Actions job" >&2
  exit 2
fi

note() {
  echo "release-compile-fleet-cas: $*"
  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "Release compile fleet cache: $*" >> "$GITHUB_STEP_SUMMARY" || true
}

# Build the old way, from this checkout into FALLBACK_DERIVED_DATA, with no fleet cache.
fallback() {
  note "$1; building without it in $fallback_dd"
  exec 9>&-
  [[ -z "${GITHUB_ENV:-}" ]] || echo "CMUX_NEXT_RELEASE_DERIVED_DATA=$fallback_dd" >> "$GITHUB_ENV" || true
  unset CMUX_NEXT_RELEASE_XCODE_SETTINGS
  exec "$workspace/scripts/cmux-next/check-release-compile.sh" "$fallback_dd"
}
# write fails instead of falling back: a fill that did not use the cache must not publish a marker.
refuse_or_fallback() {  # code reason
  if [[ "$mode" == write ]]; then
    echo "release-compile-fleet-cas: $2; no fill" >&2
    exit "$1"
  fi
  fallback "$2"
}

[[ "$mode" != off ]] || fallback "off (CMUX_NEXT_RELEASE_FLEET_CAS)"

settings_helper="$fleet_root/bin/fleet-cas-settings.sh"
socket="$fleet_root/fleet-cas.sock"
helper_output=""
if [[ -x "$settings_helper" && -S "$socket" ]]; then
  helper_output="$("$settings_helper" "$socket" 2>/dev/null | head -n 8)" || helper_output=""
fi
# Only the plugin and its socket come from the helper (as compile-app-host-test-product.sh takes
# them); the CAS path is the fleet root's fixed one below, whatever the helper prints.
plugin_settings="" plugin_ok=0 remote_ok=0
while IFS= read -r setting; do
  case "$setting" in
    COMPILATION_CACHE_ENABLE_PLUGIN=YES) plugin_ok=1 ;;
    COMPILATION_CACHE_REMOTE_SERVICE_PATH=/*) remote_ok=1 ;;
    *) continue ;;
  esac
  plugin_settings+="$setting"$'\n'
done <<< "$helper_output"
plugin_settings="${plugin_settings%$'\n'}"
(( plugin_ok && remote_ok )) || refuse_or_fallback 3 "the fleet-cas node does not answer on $socket"

# The lock, without waiting: busy means another Release compile owns the root right now.
lock_status=0
{ mkdir -p "$cas_root" && exec 9>>"$cas_root/lock" && python3 -I "$here/host_build_lock.py" acquire "$cas_root/lock" --fd 9; } \
  || lock_status=$?
case "$lock_status" in
  0) ;;
  1) refuse_or_fallback 75 "another build holds $cas_root" ;;
  *) refuse_or_fallback 75 "cannot lock $cas_root (status $lock_status)" ;;
esac

src="$cas_root/src"
derived_data="$cas_root/DerivedData"
head="$(git -C "$workspace" rev-parse HEAD)" || refuse_or_fallback 75 "cannot read this checkout's HEAD"
env -u GITHUB_ENV CMUX_CI_CANONICAL_ROOT="$cas_root" "$workspace/scripts/ci/canonical-build-root.sh" "$workspace" >&2 \
  || refuse_or_fallback 75 "could not clone this checkout into $src"
[[ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" == "$head" ]] \
  || refuse_or_fallback 75 "$src is not at $head after the clone"

if [[ "$mode" == write ]]; then
  # Every task must run so its result reaches the store: start from nothing but the packages.
  mkdir -p "$derived_data"
  for entry in "$derived_data"/* "$derived_data"/.[!.]*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ "${entry##*/}" == SourcePackages ]] || rm -rf -- "$entry"
  done
elif [[ -d "$derived_data" ]]; then
  # The same bound as the per-runner Release DerivedData (release-derived-data-path.sh).
  size_kib="$(du -sk "$derived_data" | cut -f1)"
  if (( size_kib > 12 * 1024 * 1024 )); then
    note "kept DerivedData over 12 GiB; starting it over"
    rm -rf -- "$derived_data"
  fi
fi

# The local CAS path is part of the keys too, so it is the fleet root's fixed one.
CMUX_NEXT_RELEASE_XCODE_SETTINGS="$(printf '%s\n' \
  COMPILATION_CACHE_ENABLE_CACHING=YES \
  "COMPILATION_CACHE_CAS_PATH=$fleet_root/cas" \
  COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES \
  "$plugin_settings")"
export CMUX_NEXT_RELEASE_XCODE_SETTINGS
# clear-stale-scheme-build-state.sh accepts this root's DerivedData (stale-module recovery).
export CMUX_NEXT_RELEASE_CAS_ROOT="$cas_root"
# Every runner on the host has its own checkout, with its own file times, and the clone keeps
# them: compare contents, so a file that did not change is not rebuilt from the kept DerivedData
# whichever runner cloned it (as compile-app-host-test-product.sh does).
export XCBUILD_FILE_SYSTEM_MODE=checksum-only
[[ -z "${GITHUB_ENV:-}" ]] || echo "CMUX_NEXT_RELEASE_DERIVED_DATA=$derived_data" >> "$GITHUB_ENV" || true
note "$mode: building $head in $src into $derived_data through the fleet-cas node"
# The clone's own script, so the build's paths are the canonical ones.
exec "$src/scripts/cmux-next/check-release-compile.sh" "$derived_data"
