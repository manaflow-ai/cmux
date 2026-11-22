#!/usr/bin/env bash
# Hydrates Zig's package cache for a Ghostty source (default ghostty-next)
# before cargo builds libghostty-vt, so a transient network failure is retried
# here instead of failing the build (cmux-tui-artifacts run 37401272899: the
# package host did not resolve, UnknownHostName). Zig verifies every package
# against the hash in its build.zig.zon, so a retry cannot accept other bytes.
#
# usage: fetch-ghostty-zig-packages.sh [ghostty source dir]
# CMUX_ZIG_FETCH_ATTEMPTS (default 4) and CMUX_ZIG_FETCH_RETRY_DELAY (seconds,
# default 20, multiplied by the attempt number) bound the retries.
set -euo pipefail
source_dir="${1:-ghostty-next}"
attempts="${CMUX_ZIG_FETCH_ATTEMPTS:-4}"
delay="${CMUX_ZIG_FETCH_RETRY_DELAY:-20}"
[[ "$attempts" =~ ^[1-9][0-9]*$ && "$delay" =~ ^[0-9]+$ ]] || {
  echo "error: CMUX_ZIG_FETCH_ATTEMPTS and CMUX_ZIG_FETCH_RETRY_DELAY must be whole numbers" >&2; exit 2; }
[[ -f "$source_dir/build.zig.zon" ]] || { echo "error: $source_dir/build.zig.zon not found" >&2; exit 2; }
zig_bin="${CMUX_ZIG:-zig}"
cd "$source_dir"
attempt=1
while :; do
  if "$zig_bin" build --fetch=all; then
    echo "fetched the Zig packages of $source_dir (attempt $attempt)"
    exit 0
  fi
  if (( attempt >= attempts )); then
    echo "error: could not fetch the Zig packages of $source_dir after $attempts attempts" >&2
    exit 1
  fi
  echo "Zig package fetch failed (attempt $attempt of $attempts); retrying in $((delay * attempt))s" >&2
  sleep "$((delay * attempt))"
  attempt=$((attempt + 1))
done
