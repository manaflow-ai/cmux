#!/usr/bin/env bash
# tests/lib/fake-clock.sh: sleep advances the virtual clock without waiting, `date +%s` reads it,
# scheduled events run once when the clock passes them, and other date calls stay real.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
source "$ROOT/scripts/cmux-next/tests/lib/fake-clock.sh"
fake_clock_install "$TMP/clock"
fail() { echo "fake-clock: $1" >&2; exit 1; }

start=$(date +%s)
[[ "$start" == 1700000000 ]] || fail "starts at $start"
wall=$SECONDS
sleep 3600
sleep 0.5s
[[ "$(date +%s)" == 1700003600 ]] || fail "after 3600.5 s it reads $(date +%s)"
(( SECONDS - wall < 5 )) || fail "sleep waited for real"
[[ "$(date -u -r 0 +%Y)" == 1970 || "$(date -u -d @0 +%Y)" == 1970 ]] || fail "other date calls must run the real date"

fake_clock_at 2 "echo two >> '$TMP/log'"
fake_clock_at 5 "echo five >> '$TMP/log'"
sleep 1
[[ ! -e "$TMP/log" ]] || fail "an event ran early"
sleep 1
[[ "$(cat "$TMP/log")" == two ]] || fail "the 2 s event did not run once at 2 s"
sleep 10
[[ "$(cat "$TMP/log")" == $'two\nfive' ]] || fail "events did not each run once, in order"
sleep 10
[[ "$(cat "$TMP/log")" == $'two\nfive' ]] || fail "an event ran twice"

# A child script (the script under test) sees the same clock.
bash -c 'sleep 7'
[[ "$(bash -c 'date +%s')" == 1700003629 ]] || fail "a child process does not share the clock"

if sleep forever 2>/dev/null; then fail "accepted a bad duration"; fi
echo "fake-clock tests: ok"
