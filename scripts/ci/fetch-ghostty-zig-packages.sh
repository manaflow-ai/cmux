#!/usr/bin/env bash
# Hydrates Zig's package cache for a Ghostty source (default ghostty-next)
# before cargo builds libghostty-vt, so a transient network failure is retried
# here instead of failing the build (cmux-tui-artifacts run 37401272899: the
# package host did not resolve, UnknownHostName). Zig verifies every package
# against the hash in its build.zig.zon, so a retry cannot accept other bytes.
#
# An attempt that stops making progress is stopped. A stalled download hung
# `zig build --fetch=all` for 58 minutes (cmux-tui publisher run 40630560459),
# past the job's timeout, while a healthy fetch on a slow runner takes up to
# 20 minutes (the same run's attempt 3), so the deadline is on progress: an
# attempt whose download (zig-pkg/ and the global cache's p/ and tmp/) has not
# grown for CMUX_ZIG_FETCH_STALL_TIMEOUT is stopped, as is one that runs past
# CMUX_ZIG_FETCH_ATTEMPT_TIMEOUT (a backstop well above the slowest healthy
# fetch). A stopped attempt's whole process group is killed, and so is anything
# zig leaves running when it exits or when this script is cancelled.
#
# Zig stages an unpack (zig-pkg/.tmp-* on 0.16) and moves a package into place
# only after its hash checks. But it keeps a copy of each download in
# <global cache>/p/<hash>.tar.gz and unpacks from it without checking it: one
# cut short (a cache restored or copied in part) makes every later fetch fail
# with "unable to unpack tarball to temporary directory: ReadFailed". After a
# failed attempt, the staging dirs of this checkout and every archive in p/ that
# fails its integrity check are removed before the retry; a whole archive,
# whoever wrote it, stays. Zig writes p/ archives atomically (a temp file in p/
# renamed into place, src/Package/Fetch.zig), so another job's archive is never
# partial under its final name, and a temp file has no archive suffix and stays.
#
# usage: fetch-ghostty-zig-packages.sh [ghostty source dir]
# CMUX_ZIG_FETCH_ATTEMPTS (default 3), CMUX_ZIG_FETCH_STALL_TIMEOUT (seconds
# without progress, default 180), CMUX_ZIG_FETCH_ATTEMPT_TIMEOUT (seconds an
# attempt may run, default 1800), CMUX_ZIG_FETCH_RETRY_DELAY (seconds, default
# 20, multiplied by the attempt number) and CMUX_ZIG_FETCH_SAMPLE (seconds
# between progress checks, default 5) bound the retries. CMUX_ZIG_SEED=0 skips
# the curl pre-download (scripts/ci/seed-zig-package-archives.sh).
set -euo pipefail
source_dir="${1:-ghostty-next}"
attempts="${CMUX_ZIG_FETCH_ATTEMPTS:-3}"
stall_timeout="${CMUX_ZIG_FETCH_STALL_TIMEOUT:-180}"
attempt_timeout="${CMUX_ZIG_FETCH_ATTEMPT_TIMEOUT:-1800}"
delay="${CMUX_ZIG_FETCH_RETRY_DELAY:-20}"
sample="${CMUX_ZIG_FETCH_SAMPLE:-5}"
for value in "$attempts" "$stall_timeout" "$attempt_timeout" "$sample"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: CMUX_ZIG_FETCH_ATTEMPTS, _STALL_TIMEOUT, _ATTEMPT_TIMEOUT and _SAMPLE must be positive whole numbers" >&2; exit 2; }
done
[[ "$delay" =~ ^[0-9]+$ ]] || { echo "error: CMUX_ZIG_FETCH_RETRY_DELAY must be a whole number" >&2; exit 2; }
[[ -f "$source_dir/build.zig.zon" ]] || { echo "error: $source_dir/build.zig.zon not found" >&2; exit 2; }
zig_bin="${CMUX_ZIG:-zig}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$source_dir"

marker="$(mktemp "${TMPDIR:-/tmp}/zig-fetch-stopped.XXXXXX")"
# The running attempt's process group and watchdog, stopped if this script is.
fetch_pid="" watchdog_pid=""

# Zig's global cache, where it keeps package archives (p/).
cache="${ZIG_GLOBAL_CACHE_DIR:-}"
if [[ -z "$cache" ]]; then
  # `zig env` prints ZON (0.15 and later: `.global_cache_dir = "..."`) or JSON (older).
  cache="$("$zig_bin" env 2>/dev/null | sed -n 's/.*global_cache_dir"\{0,1\} *[:=] *"\([^"]*\)".*/\1/p' | head -1)" || cache=""
fi

# A signature of what has been downloaded so far: it changes while bytes arrive.
progress() {
  local dirs=(zig-pkg)
  [[ -n "$cache" ]] && dirs+=("$cache/p" "$cache/tmp")
  { du -sk "${dirs[@]}" 2>/dev/null || true; find "${dirs[@]}" 2>/dev/null | wc -l || true; } | tr -s ' \t\n' ' '
}

# Whether an archive is whole. An unknown kind, or no tool to check it, counts
# as whole: only an archive shown to be cut short is removed.
archive_ok() {
  case "$1" in
    *.tar.gz|*.tgz) gzip -t "$1" 2>/dev/null ;;
    *.tar.xz) ! command -v xz >/dev/null 2>&1 || xz -t "$1" 2>/dev/null ;;
    *.tar.zst) ! command -v zstd >/dev/null 2>&1 || zstd -tq "$1" 2>/dev/null ;;
    *.zip) ! command -v unzip >/dev/null 2>&1 || unzip -tqq "$1" >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}

# After a failed attempt: this checkout's unfinished unpacks, and any archive in
# p/ that is cut short (one a killed download left, here or in another job).
# The global cache's tmp/ is shared with other jobs on a reused machine, and
# Zig never takes anything there for a package: it is left alone.
clear_scratch() {
  local entry
  for entry in zig-pkg/.tmp-*; do
    if [[ -e "$entry" ]]; then rm -rf "$entry"; fi
  done
  [[ -n "$cache" ]] || return 0
  for entry in "$cache"/p/*; do
    if [[ -f "$entry" ]] && ! archive_ok "$entry"; then
      echo "removing a cut-short Zig package archive: $entry" >&2
      rm -f "$entry"
    fi
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

# Cancelled (the job timed out or was cancelled): the fetch runs in a process
# group of its own, which a signal to this script's group does not reach.
on_exit() {
  if [[ -n "$watchdog_pid" ]]; then kill "$watchdog_pid" 2>/dev/null || true; fi
  if [[ -n "$fetch_pid" ]]; then stop_group "$fetch_pid"; fi
  rm -f "$marker"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# One fetch under the deadlines. Returns zig's status, or 124 when a deadline
# stopped a fetch that had not succeeded (the reason is in $marker). A fetch
# that exits 0 succeeded even at a deadline: Zig checked what it moved in.
fetch_once() {
  : > "$marker"
  # Job control gives the background fetch a process group of its own, so a
  # deadline reaches zig and every child it started (bash on Linux and macOS).
  set -m
  "$zig_bin" build --fetch=all &
  local pid=$!
  fetch_pid=$pid
  set +m
  (
    start=$SECONDS last_change=$SECONDS next_sample=$SECONDS last=""
    while kill -0 "$pid" 2>/dev/null; do
      now=$SECONDS
      if (( now >= next_sample )); then
        current="$(progress)"
        if [[ "$current" != "$last" ]]; then last=$current last_change=$now; fi
        next_sample=$((now + sample))
      fi
      if (( now - last_change >= stall_timeout )); then
        echo "made no download progress for ${stall_timeout}s" > "$marker"
      elif (( now - start >= attempt_timeout )); then
        echo "ran past its ${attempt_timeout}s limit" > "$marker"
      fi
      if [[ -s "$marker" ]]; then
        stop_group "$pid"
        exit 0
      fi
      sleep 1
    done
  ) &
  local watchdog=$!
  watchdog_pid=$watchdog
  local status=0
  wait "$pid" || status=$?
  # The watchdog goes as soon as zig is reaped, so it never signals a reused pid.
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  watchdog_pid=""
  # Anything zig left running in its group (a downloader that outlived it) would
  # hold the step's output open: stop it.
  stop_group "$pid"
  fetch_pid=""
  if (( status != 0 )) && [[ -s "$marker" ]]; then
    return 124
  fi
  return "$status"
}

# Download what curl can first, with retries and a speed floor that
# Zig's own HTTP read lacks; Zig then unpacks those from the cache offline.
if [[ -n "$cache" && "${CMUX_ZIG_SEED:-1}" != 0 ]]; then
  "$script_dir/seed-zig-package-archives.sh" "$cache" . || true
fi

attempt=1
while :; do
  status=0
  fetch_once || status=$?
  if (( status == 0 )); then
    echo "fetched the Zig packages of $source_dir (attempt $attempt)"
    exit 0
  fi
  if (( status == 124 )); then
    why="was stopped: it $(cat "$marker")"
  else
    why="failed (exit $status)"
  fi
  clear_scratch
  if (( attempt >= attempts )); then
    echo "error: could not fetch the Zig packages of $source_dir: attempt $attempt of $attempts $why; giving up" >&2
    exit 1
  fi
  echo "Zig package fetch attempt $attempt of $attempts $why; retrying in $((delay * attempt))s" >&2
  sleep "$((delay * attempt))"
  attempt=$((attempt + 1))
done
