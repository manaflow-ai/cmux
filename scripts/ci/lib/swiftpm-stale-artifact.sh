# shellcheck shell=bash
# Sourced by scripts/ci/cmux-next-ios-sim.sh and scripts/ci/swiftpm-binary-module-guard.sh.
#
# swiftpm_clear_stale_artifacts LOG
#   A resolve or build that LOG shows failing with
#     failed downloading 'URL' ... /Users/cmux/Library/Caches/org.swift.swiftpm/artifacts/KEY already exists in file system
#   met a half-written entry in the host's shared SwiftPM artifact cache, left by an interrupted or concurrent
#   download of the same binary target. SwiftPM never repairs it, so every later resolve on that host fails the
#   same way. Removes exactly the entries LOG names (each one path directly under
#   .../Library/Caches/org.swift.swiftpm/artifacts/, never the cache itself) and returns 0 when it removed one,
#   1 when LOG names none. 2026-11-26: step 1e2f85289f8bcef6d2670377 on cmux13 waited 10 h for a simulator and
#   then lost its run to WebRTC-M154 and GhosttyNextKit entries like this.
swiftpm_clear_stale_artifacts() {
  local log="$1" path removed=1
  [ -f "$log" ] || return 1
  while IFS= read -r path; do
    [[ "$path" =~ /Library/Caches/org\.swift\.swiftpm/artifacts/[^/]+$ ]] || continue
    [[ "$path" != *..* ]] || continue
    rm -rf -- "$path"
    echo "swiftpm: removed the stale artifact cache entry $path (\"already exists in file system\")"
    removed=0
  done < <(grep -oE '/[^ ]*/Library/Caches/org\.swift\.swiftpm/artifacts/[^ /]+ already exists in file system' "$log" |
    sed 's/ already exists in file system$//' | sort -u)
  return "$removed"
}

# swiftpm_run_clearing_stale_artifacts LOG COMMAND...
#   Runs COMMAND with its output in LOG; when it fails on stale artifact cache entries
#   (swiftpm_clear_stale_artifacts), removes them and runs it once more. Returns COMMAND's last status.
swiftpm_run_clearing_stale_artifacts() {
  local log="$1" status=0
  shift
  "$@" >"$log" 2>&1 || status=$?
  [ "$status" -ne 0 ] || return 0
  swiftpm_clear_stale_artifacts "$log" || return "$status"
  status=0
  "$@" >"$log" 2>&1 || status=$?
  return "$status"
}
