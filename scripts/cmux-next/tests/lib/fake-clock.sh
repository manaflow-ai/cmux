# A virtual clock for tests of scripts that poll: `sleep N` advances it instead of waiting, and
# `date +%s` reads it. A test asserts how long a script would have waited ("failed fast", "waited
# up to the cap") exactly and instantly, with no wall-clock bound a busy runner can miss.
#
#   source scripts/cmux-next/tests/lib/fake-clock.sh
#   fake_clock_install "$TMP/clock"        # puts sleep and date first on PATH for this shell
#   fake_clock_at 2 "printf x > $TMP/f"    # runs once the clock is 2 s past now
#
# Every other `date` call runs the real date. Not safe for sleeps in concurrent processes.
# `sleep` takes one duration in seconds (whole or decimal, optional "s"); anything else exits 2.
# An event is one line of the events file, split on a tab: its command holds no tab or newline.

fake_clock_install() {
  local dir="$1" real_date
  real_date="$(command -v date)"
  mkdir -p "$dir"
  export FAKE_CLOCK_FILE="$dir/now" FAKE_CLOCK_EVENTS="$dir/events"
  printf '1700000000\n' > "$FAKE_CLOCK_FILE"
  : > "$FAKE_CLOCK_EVENTS"
  cat > "$dir/sleep" <<'SLEEP'
#!/usr/bin/env bash
set -euo pipefail
by="${1:-0}"
by="${by%s}"
[[ "$by" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "fake sleep: unsupported duration '$1'" >&2; exit 2; }
now="$(awk -v now="$(cat "$FAKE_CLOCK_FILE")" -v by="$by" 'BEGIN { printf "%.3f\n", now + by }')"
printf '%s\n' "$now" > "$FAKE_CLOCK_FILE"
# Run each due event once, in order; keep the rest.
[[ -s "$FAKE_CLOCK_EVENTS" ]] || exit 0
due="$(mktemp)" left="$(mktemp)"
awk -F '\t' -v now="$now" -v due="$due" -v left="$left" \
  '{ if ($1 + 0 <= now + 0) print $2 > due; else print > left }' "$FAKE_CLOCK_EVENTS"
mv "$left" "$FAKE_CLOCK_EVENTS"
while IFS= read -r event; do bash -c "$event"; done < "$due"
rm -f "$due"
SLEEP
  cat > "$dir/date" <<DATE
#!/usr/bin/env bash
if [[ "\$#" == 1 && "\$1" == +%s ]]; then
  awk '{ printf "%d\n", \$1 }' "\$FAKE_CLOCK_FILE"
else
  exec "$real_date" "\$@"
fi
DATE
  chmod +x "$dir/sleep" "$dir/date"
  export PATH="$dir:$PATH"
}

# fake_clock_at <seconds from now> <bash command>
fake_clock_at() {
  local at
  at="$(awk -v now="$(cat "$FAKE_CLOCK_FILE")" -v by="$1" 'BEGIN { printf "%.3f\n", now + by }')"
  printf '%s\t%s\n' "$at" "$2" >> "$FAKE_CLOCK_EVENTS"
}
