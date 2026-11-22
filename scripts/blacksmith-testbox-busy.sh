#!/usr/bin/env bash
# Usage: blacksmith-testbox-busy.sh <checkout> <exclude-pid>
# Exits 0 when a process other than <exclude-pid>, its children and its
# ancestors has its working directory inside <checkout>: a command the agent
# runs on the Testbox (cargo test, a build), even after the SSH session that
# started it is gone. The keepalive passes its own pid. Linux /proc only; with
# no /proc it reports not busy.
set -euo pipefail
checkout="$(cd "${1:?checkout}" && pwd -P)"
exclude="${2:?exclude pid}"
[[ -d /proc/self ]] || exit 1

ppid_of() { awk '{print $4}' "/proc/$1/stat" 2>/dev/null || echo 0; }

# Ancestors of the excluded process (the runner that runs the keepalive).
declare -A skip=()
pid="$exclude"
while [[ -n "$pid" && "$pid" != 0 ]]; do
  skip[$pid]=1
  pid="$(ppid_of "$pid")"
  [[ -n "${skip[$pid]:-}" ]] && break
done

for dir in /proc/[0-9]*; do
  pid="${dir#/proc/}"
  [[ -n "${skip[$pid]:-}" ]] && continue
  [[ "$(ppid_of "$pid")" == "$exclude" ]] && continue   # the keepalive's sleep
  cwd="$(readlink "$dir/cwd" 2>/dev/null)" || continue
  if [[ "$cwd" == "$checkout" || "$cwd" == "$checkout"/* ]]; then
    exit 0
  fi
done
exit 1
