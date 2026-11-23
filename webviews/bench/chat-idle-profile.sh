#!/usr/bin/env bash
# CPU profiles of a long chat's idle and settle (chat-100k-flat.bench.ts with PROFILE): the running case (one chat whose
# open turn grows to about ROWS records) and the long-many case (CHATS long chats opened at once), each launch's log and
# .cpuprofile files under $FAST_CHECKS_OUT (a cmux-ci test run), else a new temp dir.
#   bench/chat-idle-profile.sh [rows=100000] [chats=20] [cases="running long-many"]
set -euo pipefail
cd "$(dirname "$0")/.."
rows=${1:-100000}
chats=${2:-20}
cases=${3:-running long-many}
out=${FAST_CHECKS_OUT:-$(mktemp -d)}
status=0
for case in $cases; do
  mkdir -p "$out/$case"
  echo "chat-idle-profile: $case"
  CASES=$case PROFILE="$out/$case" RESIZE=0 bun bench/chat-100k-flat.bench.ts "$rows" "$chats" >"$out/$case.log" 2>&1 || {
    status=$?
    echo "chat-idle-profile: $case failed ($status)"
  }
  tail -150 "$out/$case.log"
done
exit "$status"
