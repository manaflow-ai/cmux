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
# whole process group is killed and Zig's scratch dir is cleared. Zig unpacks
# into $ZIG_GLOBAL_CACHE_DIR/tmp and moves a package into p/<hash> only after
# its hash checks, so a killed download never leaves a package that looks
# complete.
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
trap 'rm -f "$marker"' EXIT

# Zig's scratch dir for unfinished downloads (only what a killed attempt left).
clear_scratch() {
  local cache="${ZIG_GLOBAL_CACHE_DIR:-}"
  if [[ -z "$cache" ]]; then
    cache="$("$zig_bin" env 2>/dev/null | sed -n 's/.*"global_cache_dir": *"\([^"]*\)".*/\1/p' | head -1)" || cache=""
  fi
  if [[ -n "$cache" && -d "$cache/tmp" ]]; then
    find "$cache/tmp" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  fi
}

# One fetch under the deadline. Returns zig's status, or 124 on the deadline.
fetch_once() {
  rm -f "$marker"
  # Job control gives the background fetch a process group of its own, so the
  # deadline kills zig and every child it started (bash on Linux and macOS).
  set -m
  "$zig_bin" build --fetch=all &
  local pid=$!
  set +m
  (
    deadline=$((SECONDS + attempt_timeout))
    while kill -0 "$pid" 2>/dev/null; do
      if (( SECONDS >= deadline )); then
        : > "$marker"
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        # Up to 5 s for the group to exit on TERM, then KILL whatever is left.
        for _ in 1 2 3 4 5; do
          kill -0 -- "-$pid" 2>/dev/null || exit 0
          sleep 1
        done
        kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        exit 0
      fi
      sleep 1
    done
  ) &
  local watchdog=$!
  local status=0
  wait "$pid" || status=$?
  wait "$watchdog" 2>/dev/null || true
  if [[ -e "$marker" ]]; then
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
