#!/usr/bin/env bash
# Runs SwiftPM on the Linux tier of Packages/macOS/CmuxNext without writing to
# the checkout (p15-oracle-229).
#
# The checkout's Package.resolved pins the macOS graph (Sparkle, sentry-cocoa).
# The Linux mode of the manifest (CMUX_SWIFTPM_TARGET_LINUX=1) has a different
# graph, so its pins live in Package.linux.resolved. SwiftPM always writes the
# resolved file next to the root manifest, so every run uses a scratch copy:
#
#   <scratch>/src    rsync --link-dest copy of Packages/ and vendor/ (the
#                    manifest's path dependencies reach both; the Linux FFI
#                    headers of build-app-ffi.sh --linux are in
#                    CmuxNext/.build-linux). Package.resolved files are never
#                    linked: SwiftPM rewrites the root one in place, which
#                    would write through a hard link.
#   <scratch>/build  SwiftPM --scratch-path, outside src so rsync --delete
#                    keeps it and builds stay incremental.
#
# Every SwiftPM command gets --only-use-versions-from-resolved-file, so a
# manifest change that needs new pins fails instead of resolving silently.
# --update-resolved is the one way to change Package.linux.resolved.
#
# Usage:
#   swift-tier.sh [options] [--] [swift-args...]    (default swift-args: build)
#   swift-tier.sh --update-resolved
#   swift-tier.sh --print-paths
# Options:
#   --scratch DIR       scratch root (default $CMUX_SWIFT_TIER_SCRATCH, else
#                       /tmp/cmux-swift-tier/<hash of the checkout path>).
#                       Hard links need DIR on the checkout's filesystem;
#                       elsewhere the first run copies (about 120 MB) and
#                       later runs copy only changed files.
#   --update-resolved   resolve without the lock and write the result to
#                       Package.linux.resolved (seeded from it, or from the
#                       macOS Package.resolved the first time, so shared pins
#                       keep the macOS versions).
#   --print-paths       print the source copy, package path and scratch path.
# Environment:
#   SWIFT               swift executable (default: swift on PATH; install it
#                       with scripts/cmux-next/linux/setup-swift.sh).
#
# Examples:
#   swift-tier.sh build --target CmuxNextCompat -j 240
#   swift-tier.sh test --filter CmuxNextCompatTests --parallel
#   swift-tier.sh package dump-package
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
package_rel="Packages/macOS/CmuxNext"
# Top-level entries the manifest reaches through path dependencies
# (CmuxAuthRuntime depends on vendor/stack-auth-swift-sdk-prerelease).
copy_entries=(Packages vendor)
checkout_resolved="$repo_root/$package_rel/Package.resolved"
linux_resolved="$repo_root/$package_rel/Package.linux.resolved"

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

scratch_root="${CMUX_SWIFT_TIER_SCRATCH:-}"
mode=run
while (($#)); do
  case "$1" in
    --scratch) [[ $# -ge 2 ]] || { echo "error: --scratch needs a directory" >&2; exit 2; }
               scratch_root="$2"; shift 2 ;;
    --scratch=*) scratch_root="${1#--scratch=}"; shift ;;
    --update-resolved) mode=update; shift ;;
    --print-paths) mode=paths; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
if [[ "$mode" != run && $# -gt 0 ]]; then
  echo "error: --update-resolved and --print-paths take no swift arguments" >&2
  exit 2
fi
swift_args=("$@")
((${#swift_args[@]})) || swift_args=(build)

if [[ -z "$scratch_root" ]]; then
  checkout_key="$(printf '%s' "$repo_root" | sha256sum | cut -c1-12)"
  scratch_root="/tmp/cmux-swift-tier/$checkout_key"
fi
case "$scratch_root" in
  ""|"/") echo "error: the scratch root must name a directory" >&2; exit 2 ;;
  "$repo_root"|"$repo_root"/*) echo "error: the scratch root must be outside the checkout" >&2; exit 2 ;;
esac
src="$scratch_root/src"
build="$scratch_root/build"
package_path="$src/$package_rel"

if [[ "$mode" == paths ]]; then
  printf 'src=%s\npackage-path=%s\nscratch-path=%s\n' "$src" "$package_path" "$build"
  exit 0
fi

swift_bin="${SWIFT:-swift}"
command -v "$swift_bin" >/dev/null 2>&1 || {
  echo "error: $swift_bin not found; run scripts/cmux-next/linux/setup-swift.sh" >&2
  exit 1
}
command -v rsync >/dev/null 2>&1 || { echo "error: rsync is required" >&2; exit 1; }
if [[ "$mode" == run && ! -f "$linux_resolved" ]]; then
  echo "error: $package_rel/Package.linux.resolved is missing; run $0 --update-resolved" >&2
  exit 1
fi

mkdir -p "$src" "$build"
# One run per scratch root: two runs would rsync over each other's sources.
exec 9>"$scratch_root/lock"
flock 9

resolved_digest() { sha256sum "$checkout_resolved" 2>/dev/null || echo missing; }
checkout_resolved_before="$(resolved_digest)"

for entry in "${copy_entries[@]}"; do
  [[ -e "$repo_root/$entry" ]] || continue
  rsync -a --delete \
    --exclude='.build/' --exclude='.swiftpm/' --exclude='Package.resolved' \
    --link-dest="$repo_root/$entry" \
    "$repo_root/$entry/" "$src/$entry/"
done

scratch_resolved="$package_path/Package.resolved"
rm -f "$scratch_resolved"
export CMUX_SWIFTPM_TARGET_LINUX=1

# SwiftPM checks a forced resolved file against its workspace state, so a pin
# missing from the file passes on a scratch that already checked it out. Drop
# the state when the pins change; a warm scratch then fails like a cold one.
pins_marker="$build/cmux-linux-resolved.sha256"
pins_digest() { sha256sum <"$1" | cut -d' ' -f1; }

if [[ "$mode" == update ]]; then
  if [[ -f "$linux_resolved" ]]; then
    cp "$linux_resolved" "$scratch_resolved"
  elif [[ -f "$checkout_resolved" ]]; then
    cp "$checkout_resolved" "$scratch_resolved"
  fi
  "$swift_bin" package --package-path "$package_path" --scratch-path "$build" resolve
  cp "$scratch_resolved" "$linux_resolved.tmp"
  mv "$linux_resolved.tmp" "$linux_resolved"
  pins_digest "$linux_resolved" >"$pins_marker"
  echo "wrote $package_rel/Package.linux.resolved"
  status=0
else
  cp "$linux_resolved" "$scratch_resolved"
  digest="$(pins_digest "$linux_resolved")"
  if [[ "$(cat "$pins_marker" 2>/dev/null)" != "$digest" ]]; then
    rm -f "$pins_marker" "$build/workspace-state.json"
  fi
  status=0
  # swift package takes these options before its subcommand; build, test and
  # run take them anywhere.
  "$swift_bin" "${swift_args[0]}" --package-path "$package_path" --scratch-path "$build" \
    --only-use-versions-from-resolved-file "${swift_args[@]:1}" || status=$?
  ((status)) || echo "$digest" >"$pins_marker"
fi

if [[ "$(resolved_digest)" != "$checkout_resolved_before" ]]; then
  echo "error: $package_rel/Package.resolved changed during the run" >&2
  exit 1
fi
exit "$status"
