#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <url> <output>" >&2
  exit 2
fi

url="$1"
output="$2"
attempts="${CMUX_DOWNLOAD_ATTEMPTS:-8}"
max_time="${CMUX_DOWNLOAD_MAX_TIME:-300}"

mkdir -p "$(dirname "$output")"

attempt=1
while [ "$attempt" -le "$attempts" ]; do
  if curl -fSL \
    --connect-timeout 30 \
    --speed-limit 1024 \
    --speed-time 120 \
    --max-time "$max_time" \
    --continue-at - \
    -o "$output" \
    "$url"; then
    exit 0
  fi

  status="$?"
  if [ "$attempt" -ge "$attempts" ]; then
    echo "Download failed after $attempt attempts: $url" >&2
    exit "$status"
  fi

  sleep_seconds=$((attempt * 5))
  echo "Download failed with exit $status; retrying in ${sleep_seconds}s ($attempt/$attempts): $url" >&2
  sleep "$sleep_seconds"
  attempt=$((attempt + 1))
done
