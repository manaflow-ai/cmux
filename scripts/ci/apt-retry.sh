#!/usr/bin/env bash
# `apt-get update && apt-get install ARGS`, retried when the Debian mirror is mid-sync.
#
# A mirror that is syncing serves an index or package whose size or hash is not the one its Release file
# names: "E: Failed to fetch ... File has unexpected size (N != M). Mirror sync in progress?" or "Hash Sum
# mismatch". Nothing in our job is wrong and a fresh `apt-get update` a few seconds later is fine, but the
# step failed and the job went red (10 false reds in 24 h on "Swift packages on Linux", 2026-11-27).
#
# So: Acquire::Retries for a flaky fetch, and when update or install still fails with one of those
# mirror-sync messages, wait and run BOTH again (the lists are what went stale), APT_RETRY_TRIES times in all.
# Any other failure (package not found, dpkg error, no network at all) exits at once with apt's status: a real
# failure stays red.
#
# Usage: apt-retry.sh INSTALL_ARGS...   e.g. apt-retry.sh -y -qq --no-install-recommends python3 zlib1g-dev
# Runs as root directly, else through `sudo -n`.
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: apt-retry.sh INSTALL_ARGS..." >&2
  exit 2
fi

as_root=()
if [ "$(id -u)" -ne 0 ]; then as_root=(sudo -n); fi
tries="${APT_RETRY_TRIES:-4}"
pause="${APT_RETRY_PAUSE_S:-15}"
opts=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
mirror_sync='unexpected size|Mirror sync in progress|Hash Sum mismatch|File has unexpected size|Release file for .* is not valid yet|Some index files failed to download'
export DEBIAN_FRONTEND=noninteractive
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

for (( try = 1; try <= tries; try++ )); do
  rc=0
  {
    ${as_root[@]+"${as_root[@]}"} apt-get update -qq "${opts[@]}" &&
      ${as_root[@]+"${as_root[@]}"} apt-get install "${opts[@]}" "$@"
  } 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  (( rc == 0 )) && exit 0
  if (( try < tries )) && grep -Eq "$mirror_sync" "$log"; then
    echo "apt-retry: the mirror is mid-sync (try $try of $tries failed); updating again in ${pause}s" >&2
    sleep "$pause"
    continue
  fi
  exit "$rc"
done
exit "${rc:-1}"
