#!/usr/bin/env bash
# zig-fetch-all.sh <zig project dir>: `zig build --fetch=all` with bounded retries.
#
# zig fetches every package of the tree in parallel and does not retry, so one
# reset connection fails the whole fetch. A package that arrived stays in
# ZIG_GLOBAL_CACHE_DIR, so each retry downloads only what is still missing.
# nightly-next run 40656489166 (2026-10-28) failed twice this way on Blacksmith:
# its zig package cache was evicted, and deps.files.ghostty.org reset the
# connections ("HTTP response read failure: ConnectionResetByPeer").
#
# CMUX_ZIG_FETCH_ATTEMPTS (default 4), CMUX_ZIG_FETCH_TIMEOUT_S per attempt
# (default 120; needs `timeout`, else unbounded) and CMUX_ZIG_FETCH_BACKOFF_S
# (default 5, times the attempt number) bound the total.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <zig project dir>" >&2; exit 2; }
dir="$1"
attempts="${CMUX_ZIG_FETCH_ATTEMPTS:-4}"
limit="${CMUX_ZIG_FETCH_TIMEOUT_S:-120}"
backoff="${CMUX_ZIG_FETCH_BACKOFF_S:-5}"
bound=()
command -v timeout >/dev/null 2>&1 && bound=(timeout "$limit")

for ((attempt = 1; attempt <= attempts; attempt++)); do
  if (cd "$dir" && ${bound[@]+"${bound[@]}"} zig build --fetch=all); then
    exit 0
  fi
  echo "zig build --fetch=all in $dir failed (attempt $attempt of $attempts)" >&2
  if ((attempt < attempts)); then
    # A bounded backoff between attempts, not a poll: the next attempt is the retry.
    sleep $((backoff * attempt))
  fi
done
echo "error: zig build --fetch=all in $dir failed $attempts times" >&2
exit 1
