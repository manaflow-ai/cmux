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
# CMUX_ZIG_FETCH_ATTEMPTS (default 4), CMUX_ZIG_FETCH_STALL_TIMEOUT (seconds
# without progress, default 180), CMUX_ZIG_FETCH_ATTEMPT_TIMEOUT (seconds an
# attempt may run, default 1800), CMUX_ZIG_FETCH_RETRY_DELAY (seconds, default
# 20, multiplied by the attempt number: 20, 40 and 60 s, so the retries span 2
# minutes of a package-host outage; 3 attempts 20 and 40 s apart all got the
# same 504 on 2026-11-08) and CMUX_ZIG_FETCH_SAMPLE (seconds
# between progress checks, default 5) bound the retries. CMUX_ZIG_SEED=0 skips
# the curl pre-download (scripts/ci/seed-zig-package-archives.sh).
#
# The seed puts every package of the source from our mirror
# (scripts/ci/zig-packages.lock) into Zig's cache first. With
# CMUX_ZIG_MIRROR_ONLY=1 (the default when CI=true; 0 turns it off) Zig then
# runs with no route to any other host (a proxy that refuses), so a package
# missing from the mirror fails here, named, instead of being fetched from a
# third-party host: codeberg.org's outage on 2026-11-11 failed every cold build.
set -euo pipefail
source_dir="${1:-ghostty-next}"
attempts="${CMUX_ZIG_FETCH_ATTEMPTS:-4}"
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
mirror_only="${CMUX_ZIG_MIRROR_ONLY:-}"
[[ -n "$mirror_only" ]] || { [[ "${CI:-}" == true ]] && mirror_only=1 || mirror_only=0; }
export CMUX_ZIG_MIRROR_ONLY="$mirror_only"
# Mirror only: Zig's HTTP client takes these proxies (std.http.Client
# initDefaultProxies), and nothing listens on port 9, so any fetch Zig itself
# makes fails at once. curl in the seed ran before, without them. An inherited
# NO_PROXY/no_proxy (`*`, or a host) would let Zig bypass that proxy, so both go.
zig_env=()
if [[ "$mirror_only" == 1 ]]; then
  zig_env=(-u NO_PROXY -u no_proxy)
  for name in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; do zig_env+=("$name=http://127.0.0.1:9"); done
fi
cd "$source_dir"

marker="$(mktemp "${TMPDIR:-/tmp}/zig-fetch-stopped.XXXXXX")"
# The running attempt's process group and watchdog, stopped if this script is.
fetch_pid="" watchdog_pid="" seed_pid=""

# Zig's global cache, where it keeps package archives (p/).
cache="${ZIG_GLOBAL_CACHE_DIR:-}"
if [[ -z "$cache" ]]; then
  # `zig env` prints ZON (0.15 and later: `.global_cache_dir = "..."`) or JSON (older).
  cache="$("$zig_bin" env 2>/dev/null | sed -n 's/.*global_cache_dir"\{0,1\} *[:=] *"\([^"]*\)".*/\1/p' | head -1)" || cache=""
fi
# Zig 0.16 writes a zip package to <cache>/tmp/ and does not make that directory
# ("failed to create temporary zip file: FileNotFound"): when every other package
# came from a restore or the curl seed, nothing else made it.
if [[ -n "$cache" ]]; then mkdir -p "$cache/p" "$cache/tmp"; fi

# A signature of what has been downloaded so far: it changes while bytes arrive.
progress() {
  local dirs=(zig-pkg)
  [[ -n "$cache" ]] && dirs+=("$cache/p" "$cache/tmp")
  { du -sk "${dirs[@]}" 2>/dev/null || true; find "${dirs[@]}" 2>/dev/null | wc -l || true; } | tr -s ' \t\n' ' '
}

# Whether an archive is whole. An unknown kind, or no tool to check it, counts
# as whole: only an archive shown to be cut short or not a tar with entries is
# removed (a gzipped error page passes gzip -t, GNU tar lists it as an empty
# archive, and Zig fails on it every attempt).
archive_ok() {
  case "$1" in
    # Through stdin: GNU tar reads a C:\... path (the Zig cache on a Windows
    # runner) as HOST:FILE, and every archive failed this check there.
    *.tar.gz|*.tgz) local entries; entries="$(tar -tzf - < "$1" 2>/dev/null | wc -l)" && (( entries > 0 )) ;;
    *.tar.xz) ! command -v xz >/dev/null 2>&1 || xz -t "$1" 2>/dev/null ;;
    *.tar.zst) ! command -v zstd >/dev/null 2>&1 || zstd -tq "$1" 2>/dev/null ;;
    *.zip) ! command -v unzip >/dev/null 2>&1 || unzip -tqq "$1" >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}

# Whether archive_ok passes a whole .tar.gz written under the cache's own path
# (tmp/, which Zig never takes a package from).
checks_work() {
  local probe="$cache/tmp/.cmux-check-$$.tar.gz" ok=1
  mkdir -p "$cache/tmp" 2>/dev/null || return 1
  if printf 'whole\n' > "$probe.f" && tar -czf - -C "$(dirname "$probe")" "$(basename "$probe").f" > "$probe" 2>/dev/null \
    && archive_ok "$probe"; then ok=0; fi
  rm -f "$probe" "$probe.f"
  return "$ok"
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
  # Only an archive's own fault removes it: when the check fails on an archive
  # this script just wrote whole, at the cache's own path, the check is broken
  # here (a tool, a path form), and every archive in p/ would go.
  if ! checks_work; then
    echo "warning: the archive check fails on a whole archive under $cache; no archive in p/ is removed" >&2
    return 0
  fi
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
  # The seed stops its own downloads on TERM (its EXIT trap signals their group).
  if [[ -n "$seed_pid" ]]; then kill -TERM "$seed_pid" 2>/dev/null || true; wait "$seed_pid" 2>/dev/null || true; fi
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
  env ${zig_env[@]+"${zig_env[@]}"} "$zig_bin" build --fetch=all &
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
# In the background with `wait`: Bash runs a trap only after a foreground command
# ends, so a TERM to this script would otherwise wait for the seed's deadline.
if [[ -n "$cache" && "${CMUX_ZIG_SEED:-1}" != 0 ]]; then
  "$script_dir/seed-zig-package-archives.sh" "$cache" . &
  seed_pid=$!
  wait "$seed_pid" || true
  seed_pid=""
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
    if [[ "$mirror_only" == 1 ]]; then
      echo "next: mirror only: a package above is not in scripts/ci/zig-packages.lock's mirror; run scripts/ci/zig_package_mirror.py check, and mirror it (its docstring)" >&2
    fi
    exit 1
  fi
  echo "Zig package fetch attempt $attempt of $attempts $why; retrying in $((delay * attempt))s" >&2
  sleep "$((delay * attempt))"
  attempt=$((attempt + 1))
done
