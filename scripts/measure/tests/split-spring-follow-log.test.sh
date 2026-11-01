#!/bin/bash
# split-spring.sh follows reload.sh's own log into the step output (FC-1: a 45 min silent reload named no step).
# Runs split-spring's follow_log/unfollow_log on a temp file: each new line shows once, prefixed "reload-log: ",
# the old content of the file does not, and unfollow_log leaves no `tail` behind. No build, no app.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/split-spring-follow-log.XXXXXX")"
trap 'rm -rf "$work"' EXIT
sed -n '/^# >>> follow-log/,/^# <<< follow-log/p' "$root/scripts/measure/split-spring.sh" > "$work/follow.sh"
grep -q '^follow_log()' "$work/follow.sh" || { echo "FAIL: split-spring.sh has no follow-log block"; exit 1; }
log="$work/reload.log"
printf 'old run line\n' > "$log"
(
  # shellcheck disable=SC1091
  source "$work/follow.sh"
  follow_log "$log"
  pid="$follow_pid"
  printf 'first line\n' >> "$log"
  printf 'second line\n' >> "$log"
  for _ in $(seq 50); do grep -q 'reload-log: second line' "$work/out" 2>/dev/null && break; sleep 0.1; done
  unfollow_log
  if kill -0 "$pid" 2>/dev/null; then echo "FAIL: the tail $pid still runs"; exit 1; fi
  [[ -z "$follow_pid" ]] || { echo "FAIL: follow_pid not cleared"; exit 1; }
) > "$work/out" 2>&1
sleep 0.2  # the awk ends once its tail did; its last flushed lines are in the file
out="$(cat "$work/out")"
grep -qx 'reload-log: first line' <<<"$out" || { echo "FAIL: no first line: $out"; exit 1; }
grep -qx 'reload-log: second line' <<<"$out" || { echo "FAIL: no second line: $out"; exit 1; }
if grep -q 'old run line' <<<"$out"; then echo "FAIL: an earlier run's line showed: $out"; exit 1; fi
[[ "$(grep -c '^reload-log: ' <<<"$out")" == 2 ]] || { echo "FAIL: lines shown more than once: $out"; exit 1; }
echo "PASS split-spring follow-log: this run's lines stream prefixed, once; the tail ends with unfollow_log"
