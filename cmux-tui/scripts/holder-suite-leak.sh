#!/usr/bin/env bash
# What a cmux-tui test run leaves behind with the terminal holder on or off
# (cmux#36853 stopped on 303 holder-only reds: "PTY capacity exhausted").
#
#   scripts/holder-suite-leak.sh MODEL [CARGO TEST ARGS...]
#
# MODEL is `holder` or `hosts` (CMUX_TUI_TERMINAL_HOST_MODEL for every test
# daemon). Runs `cargo test --no-fail-fast` with the args (default: the
# cmux-tui and cmux-tui-core packages), samples the PTYs in use every second
# (Linux /proc/sys/kernel/pty/nr), and at the end prints one HOLDER-SUITE
# line: tests passed and failed, PTYs before, peak and after, and the holder,
# terminal-host and shell processes still running. Reads only; it kills
# nothing.
set -uo pipefail
model=${1:?MODEL: holder or hosts}
shift
[ $# -gt 0 ] || set -- -p cmux-tui -p cmux-tui-core
cd "$(dirname "$0")/.."
out=${FAST_CHECKS_OUT:-$(mktemp -d)}
mkdir -p "$out"
log="$out/holder-suite-$model.log"

ptys() { cat /proc/sys/kernel/pty/nr 2>/dev/null || echo -1; }
count() { # processes whose command line matches $1, not this script's own
  local n=0 pid cmd
  for pid in /proc/[0-9]*; do
    cmd=$(tr '\0' ' ' <"$pid/cmdline" 2>/dev/null) || continue
    case $cmd in *holder-suite-leak*) continue ;; esac
    [[ $cmd =~ $1 ]] && n=$((n + 1))
  done
  echo "$n"
}

# Build first so the PTY peak is the tests'.
CMUX_TUI_TERMINAL_HOST_MODEL=$model cargo test --no-run "$@" >"$out/build-$model.log" 2>&1 ||
  { tail -60 "$out/build-$model.log"; exit 1; }

before=$(ptys)
peak_file=$(mktemp)
echo "$before" >"$peak_file"
(
  while :; do
    now=$(ptys)
    [ "$now" -gt "$(cat "$peak_file")" ] && echo "$now" >"$peak_file"
    sleep 1
  done
) &
sampler=$!

start=$(date +%s)
CMUX_TUI_TERMINAL_HOST_MODEL=$model cargo test --no-fail-fast "$@" -- --test-threads=8 >"$log" 2>&1
status=$?
elapsed=$(( $(date +%s) - start ))
kill "$sampler" 2>/dev/null
wait "$sampler" 2>/dev/null

after=$(ptys)
peak=$(cat "$peak_file")
passed=$(grep -E '^test result:' "$log" | awk '{s += $4} END {print s + 0}')
failed=$(grep -E '^test result:' "$log" | awk '{s += $6} END {print s + 0}')
holders=$(count '(__holder|cmux-holder) ')
hosts=$(count '__terminal-host')
openpty=$(grep -c -E 'openpty|PTY capacity' "$log")

echo "== failed tests ($model)"
grep -E '^test .* \.\.\. FAILED$|^    [a-z_:]+$' "$log" | head -400
echo "== openpty lines: $openpty"
grep -E 'openpty|PTY capacity' "$log" | sort | uniq -c | sort -rn | head -10
echo "== holders left"
for pid in /proc/[0-9]*; do
  cmd=$(tr '\0' ' ' <"$pid/cmdline" 2>/dev/null) || continue
  [[ $cmd =~ (__holder|cmux-holder)\  ]] || continue
  case $cmd in *holder-suite-leak*) continue ;; esac
  kids=$(grep -l "^PPid:[[:space:]]*${pid#/proc/}$" /proc/[0-9]*/status 2>/dev/null | wc -l)
  echo "${pid#/proc/} children=$kids $cmd" | cut -c1-240
done | head -40
echo "HOLDER-SUITE model=$model exit=$status passed=$passed failed=$failed seconds=$elapsed" \
  "ptys_before=$before ptys_peak=$peak ptys_after=$after holders_left=$holders" \
  "terminal_hosts_left=$hosts openpty_errors=$openpty"
exit "$status"
