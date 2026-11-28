#!/usr/bin/env bash
# A job whose HOME it cannot write gets a HOME of its own under RUNNER_TEMP, and Bun gets its own temp dir.
#
# Why: a Linux pool runner k>=2 runs as user runnerK with HOME=/home/runner, which is meant to be its own home
# bind-mounted there (hq skills/infra/linux-runner-pool/pool.sh one_path). When that bind is missing, HOME is runner 1's
# home and every write under it fails. On 2026-11-27 that broke cmux-vm's production deploy path for hours:
#   run 46014738408 deploy-production (runner8): EACCES: permission denied, mkdir '/home/runner/.bun/bin' (setup-bun)
#   run 46058588655 check (runner7): moving "@jridgewell/trace-mapping" to cache dir failed: EACCES (bun install)
#   run 46020853039 deploy-staging (hetzner-2-3): EACCES accessing temporary directory. set $BUN_TMPDIR
# and production kept cmux-vm version 41d7b553cee2, without cmux#61044, while Cloud machines failed to start
# (probe cloud-chat-replies-production, "start-chat: cloud.machine_stuck").
#
# Usage (a workflow step, before any Bun or Node setup): bash "$GITHUB_WORKSPACE/scripts/ci/job-own-home.sh"
# Writes HOME and BUN_TMPDIR to GITHUB_ENV. Exits 0 always: the job then runs and fails on its own if it must.
set -uo pipefail

env_file="${GITHUB_ENV:-/dev/null}"
temp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
me="$(id -u)"

# One entry under PATH that this user does not own, or cannot write, is enough: setup-bun, bun install and the
# toolchain restore all write below ~/.bun and ~/.cache.
foreign() {
  local path="$1"
  [ -e "$path" ] || return 1
  [ -w "$path" ] || return 0
  [ -n "$(find "$path" -maxdepth 4 \( ! -user "$me" -o ! -writable \) -print -quit 2>/dev/null)" ]
}

home="${HOME:-}"
reason=""
if [ -z "$home" ] || [ ! -d "$home" ]; then
  reason="HOME '${home}' is not a directory"
elif [ ! -w "$home" ]; then
  reason="HOME $home is not writable by uid $me"
else
  for sub in .bun .cache/cmux-toolchains; do
    if foreign "$home/$sub"; then reason="$home/$sub holds files uid $me cannot write"; break; fi
  done
fi

if [ -n "$reason" ]; then
  own="$temp/home"
  mkdir -p "$own" || { echo "::warning title=job HOME::$reason, and $own cannot be made"; exit 0; }
  # Git identity and safe.directory settings jobs rely on come from the global config: carry it over if readable.
  [ -r "$home/.gitconfig" ] && cp "$home/.gitconfig" "$own/.gitconfig" 2>/dev/null
  echo "HOME=$own" >> "$env_file"
  echo "::warning title=job HOME::$reason; this job uses $own (the pool runner's own-home bind is missing)"
fi

bun_tmp="$temp/bun-tmp"
mkdir -p "$bun_tmp" && echo "BUN_TMPDIR=$bun_tmp" >> "$env_file"
exit 0
