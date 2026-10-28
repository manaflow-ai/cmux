#!/usr/bin/env bash
# Hydrates Zig's package cache for a Ghostty source (default ghostty-next)
# before cargo builds libghostty-vt, so a transient network failure is retried
# here instead of failing the build (cmux-tui-artifacts run 37401272899: the
# package host did not resolve, UnknownHostName). Zig verifies every package
# against the hash in its build.zig.zon, so a retry cannot accept other bytes.
#
# Each attempt has a deadline. A download that stalls instead of failing hung
# `zig build --fetch=all` for 58 minutes (cmux-tui publisher run 40630560459),
# past the job's timeout; a mid-stream read error failed cargo builds that
# fetch on their own (ReadFailed on pkg/highway). On the deadline the attempt's
# whole process group is killed, and so is anything zig leaves running when it
# exits. Zig stages an unpack (zig-pkg/.tmp-* on 0.16) and moves a package into
# place only after its hash checks, so a killed download never leaves a package
# that looks complete; its scratch and any archive it wrote are removed.
#
# usage: fetch-ghostty-zig-packages.sh [ghostty source dir]
# CMUX_ZIG_FETCH_ATTEMPTS (default 3), CMUX_ZIG_FETCH_ATTEMPT_TIMEOUT (seconds
# per attempt, default 180) and CMUX_ZIG_FETCH_RETRY_DELAY (seconds, default
# 20, multiplied by the attempt number) bound the retries: at the defaults a
# fetch gives up within about 11 minutes.
set -euo pipefail
source_dir="${1:-ghostty-next}"
attempts="${CMUX_ZIG_FETCH_ATTEMPTS:-3}"
attempt_timeout="${CMUX_ZIG_FETCH_ATTEMPT_TIMEOUT:-180}"
delay="${CMUX_ZIG_FETCH_RETRY_DELAY:-20}"
[[ "$attempts" =~ ^[1-9][0-9]*$ && "$attempt_timeout" =~ ^[1-9][0-9]*$ && "$delay" =~ ^[0-9]+$ ]] || {
  echo "error: CMUX_ZIG_FETCH_ATTEMPTS and CMUX_ZIG_FETCH_ATTEMPT_TIMEOUT must be positive whole numbers, CMUX_ZIG_FETCH_RETRY_DELAY a whole number" >&2; exit 2; }
[[ -f "$source_dir/build.zig.zon" ]] || { echo "error: $source_dir/build.zig.zon not found" >&2; exit 2; }
zig_bin="${CMUX_ZIG:-zig}"
cd "$source_dir"

marker="$(mktemp "${TMPDIR:-/tmp}/zig-fetch-timeout.XXXXXX")"
before="$(mktemp "${TMPDIR:-/tmp}/zig-fetch-before.XXXXXX")"
trap 'rm -f "$marker" "$before"' EXIT

# Zig's global cache, where it keeps package archives (p/).
cache="${ZIG_GLOBAL_CACHE_DIR:-}"
if [[ -z "$cache" ]]; then
  # `zig env` prints ZON (0.15 and later: `.global_cache_dir = "..."`) or JSON (older).
  cache="$("$zig_bin" env 2>/dev/null | sed -n 's/.*global_cache_dir"\{0,1\} *[:=] *"\([^"]*\)".*/\1/p' | head -1)" || cache=""
fi

# The archives in p/ before an attempt, one name a line.
list_archives() {
  local entry
  [[ -n "$cache" ]] || return 0
  for entry in "$cache"/p/*; do
    [[ -f "$entry" ]] && printf '%s\n' "${entry##*/}"
  done
  return 0
}

# What a killed attempt left in this checkout and from this attempt alone:
# unfinished unpacks (Zig 0.16 stages them in zig-pkg/.tmp-*) and any package
# archive that appeared in <global cache>/p during the attempt, which the kill
# may have cut short. A finished zig-pkg/<hash> was moved into place after its
# hash checked, and stays. The global cache's tmp/ is shared with other jobs on
# a reused machine, and Zig never takes anything there for a package: it is
# left alone.
clear_scratch() {
  local entry
  for entry in zig-pkg/.tmp-*; do
    if [[ -e "$entry" ]]; then rm -rf "$entry"; fi
  done
  [[ -n "$cache" ]] || return 0
  for entry in "$cache"/p/*; do
    if [[ -f "$entry" ]] && ! grep -qxF "${entry##*/}" "$before"; then rm -f "$entry"; fi
  done
}

# Signal the attempt's process group: TERM, up to 5 s to exit, then KILL.
stop_group() {
  local pgid=$1
  kill -0 -- "-$pgid" 2>/dev/null || return 0
  kill -TERM -- "-$pgid" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    kill -0 -- "-$pgid" 2>/dev/null || return 0
    sleep 1
  done
  kill -KILL -- "-$pgid" 2>/dev/null || true
}

# One fetch under the deadline. Returns zig's status, or 124 when the deadline
# stopped a fetch that had not succeeded. A fetch that exits 0 succeeded even
# at the deadline: Zig checked every package it moved into place.
fetch_once() {
  rm -f "$marker"; list_archives > "$before"
  # Job control gives the background fetch a process group of its own, so the
  # deadline reaches zig and every child it started (bash on Linux and macOS).
  set -m
  "$zig_bin" build --fetch=all &
  local pid=$!
  set +m
  (
    deadline=$((SECONDS + attempt_timeout))
    while kill -0 "$pid" 2>/dev/null; do
      if (( SECONDS >= deadline )); then
        : > "$marker"
        stop_group "$pid"
        exit 0
      fi
      sleep 1
    done
  ) &
  local watchdog=$!
  local status=0
  wait "$pid" || status=$?
  # The watchdog goes as soon as zig is reaped, so it never signals a reused pid.
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  # Anything zig left running in its group (a downloader that outlived it) would
  # hold the step's output open: stop it.
  stop_group "$pid"
  if (( status != 0 )) && [[ -e "$marker" ]]; then
    clear_scratch
    return 124
  fi
  return "$status"
}

attempt=1
while :; do
  status=0
  fetch_once || status=$?
  if (( status == 0 )); then
    echo "fetched the Zig packages of $source_dir (attempt $attempt)"
    exit 0
  fi
  if (( status == 124 )); then
    why="timed out after ${attempt_timeout}s"
  else
    why="failed (exit $status)"
  fi
  if (( attempt >= attempts )); then
    echo "error: could not fetch the Zig packages of $source_dir: attempt $attempt of $attempts $why; giving up" >&2
    exit 1
  fi
  echo "Zig package fetch $why (attempt $attempt of $attempts); retrying in $((delay * attempt))s" >&2
  sleep "$((delay * attempt))"
  attempt=$((attempt + 1))
done
