#!/usr/bin/env bash
# tab-switch.sh runs each long step (the console preflight, the tools compile, the seeder and app builds, the bench)
# through tsw_step: both chat-long-return runs on #47553 (base and head, two fleet Macs, 2026-11-19) went silent
# after "TSW recorder ready" while the app build wrote only to its own log, and the controller stopped each after
# 45 silent minutes without a word on which step it was. Here the functions are sourced in a scratch repository
# and each case takes a few seconds: a step past its bound is stopped with every process under it and a TSW line
# that names it (exit 3); a long quiet step prints a line with its elapsed time and its log's last line; a step
# that ends keeps its own status; --stream shows the output as it comes.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../cmux-next/tests/lib/git-fixture.sh"  # drops inherited GIT_DIR/GIT_CONFIG redirects; turns off background maintenance
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../tab-switch.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tab-switch-step-bounds.XXXXXX")"
git_fixture_trap_exit 'rm -rf -- "$tmp"'

repo="$tmp/repo"
mkdir -p "$repo/scripts/measure"
cp "$script" "$repo/scripts/measure/tab-switch.sh"
git_fixture_init "$repo"
fail=0
check() { # NAME CONDITION...
  local name="$1"
  shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fail=1; fi
}

# 1. Past its bound: stopped, named, and nothing it started is left.
cat >"$tmp/hang.sh" <<'SH'
#!/usr/bin/env bash
echo "building the app"
sleep 300 &
echo $! >"$1"
wait
SH
chmod +x "$tmp/hang.sh"
set +e
out="$(cd "$repo" && source scripts/measure/tab-switch.sh && TSW_STEP_EVERY=1 tsw_step TSW app-build 3 "$tmp/hang.log" -- "$tmp/hang.sh" "$tmp/hang.pid" 2>&1)"
rc=$?
set -e
echo "$out" | sed 's/^/  | /'
check "a step past its bound exits 3" test "$rc" = 3
check "the line names the step and its bound" grep -q "^TSW step app-build ran past 3 s" <<<"$out"
check "the line shows the step's log" grep -q "building the app" <<<"$out"
sleep_pid="$(cat "$tmp/hang.pid" 2>/dev/null || echo 0)"
gone() { ! kill -0 "$sleep_pid" 2>/dev/null; }
check "a process the step started is stopped too" gone

# 2. A long quiet step says it is alive, with its log's last line.
set +e
# sleep-ok: the step stays quiet for 3 s on purpose so the 1 s heartbeat prints while it runs.
out="$(cd "$repo" && source scripts/measure/tab-switch.sh && TSW_STEP_EVERY=1 tsw_step TSW seeder 30 "$tmp/quiet.log" -- bash -c 'echo compiling scale_home; sleep 3; exit 0' 2>&1)"
rc=$?
set -e
echo "$out" | sed 's/^/  | /'
check "a quiet step that ends exits 0" test "$rc" = 0
check "a quiet step prints its elapsed time and last log line" grep -Eq "^TSW step seeder: [0-9]+ s, last: compiling scale_home" <<<"$out"

# 3. A step that fails keeps its own status, and --stream shows its output as it comes.
set +e
out="$(cd "$repo" && source scripts/measure/tab-switch.sh && tsw_step LCP bench 30 "$tmp/bench.log" --stream -- bash -c 'echo TSW-TABLE row; exit 1' 2>&1)"
rc=$?
set -e
echo "$out" | sed 's/^/  | /'
check "a failed step keeps its status" test "$rc" = 1
check "--stream shows the step's output" grep -q "^TSW-TABLE row" <<<"$out"
check "the log keeps the step's output" grep -q "TSW-TABLE row" "$tmp/bench.log"

# 4. No long step writes only to a file of its own: each goes through tsw_step.
silent="$(grep -nE '>"\$tmp/(build|seeder)\.log"' "$script" || true)"
check "no build step writes only to its own log" test -z "$silent"

exit "$fail"
