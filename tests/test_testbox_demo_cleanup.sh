#!/usr/bin/env bash
# Behavior tests for scripts/blacksmith-testbox-demo.sh with fake `blacksmith`,
# `gh` and hq wrapper. No network, no real Testbox.
#  1. A box the wrapper names (TBX=) is stopped and its warmup run is
#     cancelled in every exit path: wrapper failure after TBX=, a wrapper
#     that hangs past the warmup bound, and a later step that fails.
#     Ctrl-C (SIGINT to the demo's process group, as a terminal sends it) or
#     TERM ends a running bounded step at once, stops the box and exits 130
#     or 143; a second Ctrl-C during that cleanup does not abort it.
#  2. Without an hq checkout the demo starts nothing and names the public
#     fallback instead of a personal default path.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
demo="$root/scripts/blacksmith-testbox-demo.sh"
bounded="$root/scripts/blacksmith-bounded-command.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
log=""
fail() { echo "FAIL: $*" >&2; if [[ -n "$log" && -f "$log" ]]; then cat "$log" >&2; fi; exit 1; }
git_q() { git -c user.name=t -c user.email=t@e -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

# A cmux-shaped checkout whose branch is pushed, as the demo requires.
git_q init --bare "$work/origin.git"
repo="$work/repo"
mkdir -p "$repo/scripts" "$repo/.github/workflows" "$repo/ghostty-next"
cp "$bounded" "$repo/scripts/"
echo "name: stub" >"$repo/.github/workflows/cmux-tui-testbox-warmup.yml"
echo ".{}" >"$repo/ghostty-next/build.zig.zon"
git_q -C "$repo" init -b demo-branch
git_q -C "$repo" add -A
git_q -C "$repo" commit -m base
git_q -C "$repo" remote add origin "$work/origin.git"
git_q -C "$repo" push origin demo-branch

# An hq checkout on main with a fake wrapper whose behavior FAKE_WARMUP picks.
git_q init --bare "$work/hq.git"
git_q clone "$work/hq.git" "$work/hq-seed"
mkdir -p "$work/hq-seed/scripts"
cat >"$work/hq-seed/scripts/testbox-warmup.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >"$FAKE_STATE/wrapper-started"
case "$FAKE_WARMUP" in
  ok) echo "TBX=tbx_ok"; echo "RUN=4242" ;;
  fail-after-tbx) echo "TBX=tbx_failed"; echo "no warmup run names tbx_failed" >&2; exit 3 ;;
  hang-after-tbx) echo "TBX=tbx_hung"; touch "$FAKE_STATE/named"; sleep 60 ;;
esac
SH
chmod +x "$work/hq-seed/scripts/testbox-warmup.sh"
git_q -C "$work/hq-seed" add -A
git_q -C "$work/hq-seed" commit -m wrapper
git_q -C "$work/hq-seed" push origin HEAD:main
git_q clone -b main "$work/hq.git" "$work/hq"

# Fakes record every call. `gh api` answers the run lookup by box title with 777.
bin="$work/bin"
mkdir -p "$bin" "$work/state"
cat >"$bin/blacksmith" <<SH
#!/usr/bin/env bash
echo "blacksmith \$*" >>"$work/calls"
case "\$*" in
  "testbox stop --id "*)
    touch "\$FAKE_STATE/stopping"
    # Longer than the 5 s kill-after of a bound, so a second Ctrl-C that
    # reached the bound would kill this stop before it finishes.
    [[ -z "\${FAKE_SLOW_STOP:-}" ]] || sleep 7
    echo "blacksmith testbox stopped \$4" >>"$work/calls" ;;
  --version) echo "blacksmith 0.0.0-fake" ;;
  "testbox status"*) exit "\${FAKE_STATUS_EXIT:-0}" ;;
esac
exit 0
SH
cat >"$bin/gh" <<SH
#!/usr/bin/env bash
echo "gh \$*" >>"$work/calls"
# Only a lookup that filters on this box's run title finds run 777.
case "\$*" in
  "api repos/manaflow-ai/cmux/actions/workflows/"*'"cmux-tui Rust Testbox setup tbx_'*) echo 777 ;;
esac
exit 0
SH
chmod +x "$bin/blacksmith" "$bin/gh"

rc=0
run_demo() { # <name> <env assignments or -u NAME>...
  local name="$1"; shift
  log="$work/$name.log"
  : >"$work/calls"
  rm -f "$work/state/"*
  set +e
  (cd "$repo" && env "$@" PATH="$bin:$PATH" FAKE_STATE="$work/state" CMUX_TESTBOX_DEMO_WARMUP_TIMEOUT=3 \
    "$bounded" 60 "$demo") >"$log" 2>&1
  rc=$?
  set -e
}
called() { grep -qF -- "$1" "$work/calls"; }

# 1a. The wrapper names the box, then fails before RUN=: stop it, find its run
#     by title, and cancel that run.
run_demo fail-after-tbx HQ_TOOLS="$work/hq" FAKE_WARMUP=fail-after-tbx
[[ $rc -ne 0 ]] || fail "1a: the demo succeeded after the wrapper failed"
called "blacksmith testbox stop --id tbx_failed" || fail "1a: box tbx_failed was not stopped"
called "gh run cancel 777" || fail "1a: the warmup run of tbx_failed was not cancelled"

# 1b. The wrapper hangs after naming the box: the warmup bound (3 s here) ends
#     it well before the outer 60 s bound, and the box is still stopped.
started=$SECONDS
run_demo hang-after-tbx HQ_TOOLS="$work/hq" FAKE_WARMUP=hang-after-tbx
(( SECONDS - started < 40 )) || fail "1b: the demo was not ended by its warmup bound ($((SECONDS - started)) s)"
[[ $rc -ne 0 ]] || fail "1b: the demo succeeded after the wrapper hung"
called "blacksmith testbox stop --id tbx_hung" || fail "1b: box tbx_hung was not stopped"
called "gh run cancel 777" || fail "1b: the warmup run of tbx_hung was not cancelled"

# 1c. The wrapper succeeds and a later step fails: stop the box, cancel RUN=.
run_demo later-failure HQ_TOOLS="$work/hq" FAKE_WARMUP=ok FAKE_STATUS_EXIT=7
[[ $rc -ne 0 ]] || fail "1c: the demo succeeded after hydration failed"
called "blacksmith testbox stop --id tbx_ok" || fail "1c: box tbx_ok was not stopped"
called "gh run cancel 4242" || fail "1c: run 4242 was not cancelled"

# 1d-1f. Signals while the wrapper runs after naming the box. The bounded
#     step sits in its own process group under GNU timeout, so only the
#     demo's trap can end it. Job control gives the demo its own group, which
#     is what a terminal signals on Ctrl-C.
signal_demo() { # <case> <signal> <expected rc> [second signal during cleanup]
  local name="$1" sig="$2" want="$3" second="${4:-}" target
  : >"$work/calls"
  rm -f "$work/state/"*
  log="$work/$name.log"
  set -m
  (cd "$repo" && exec env PATH="$bin:$PATH" FAKE_STATE="$work/state" HQ_TOOLS="$work/hq" \
    FAKE_WARMUP=hang-after-tbx FAKE_SLOW_STOP="${second:+1}" CMUX_TESTBOX_DEMO_WARMUP_TIMEOUT=50 "$demo") >"$log" 2>&1 &
  demo_pid=$!
  set +m
  for _ in $(seq 1 100); do [[ -e "$work/state/named" ]] && break; sleep 0.1; done
  [[ -e "$work/state/named" ]] || { kill -KILL -- "-$demo_pid" 2>/dev/null || true; fail "$name: the fake wrapper never named its box"; }
  target="-$demo_pid"
  [[ "$sig" == TERM ]] && target="$demo_pid"
  started=$SECONDS
  kill "-$sig" -- "$target"
  if [[ -n "$second" ]]; then
    # A second Ctrl-C while the box is being stopped must not abort cleanup.
    for _ in $(seq 1 100); do [[ -e "$work/state/stopping" ]] && break; sleep 0.1; done
    [[ -e "$work/state/stopping" ]] || fail "$name: cleanup never began to stop the box"
    kill "-$second" -- "-$demo_pid" 2>/dev/null || true
  fi
  set +e
  wait "$demo_pid"
  rc=$?
  set -e
  (( SECONDS - started < 20 )) || fail "$name: $sig took $((SECONDS - started)) s to end the demo"
  [[ $rc -eq $want ]] || fail "$name: expected exit $want after $sig (rc=$rc)"
  called "blacksmith testbox stopped tbx_hung" || fail "$name: box tbx_hung was not stopped"
  called "gh run cancel 777" || fail "$name: the warmup run of tbx_hung was not cancelled"
  ! kill -0 "$(cat "$work/state/wrapper-started")" 2>/dev/null || fail "$name: the wrapper still runs"
}
signal_demo 1d-ctrl-c INT 130
signal_demo 1e-term TERM 143
signal_demo 1f-double-ctrl-c INT 130 INT
# The same through the python fallback of the bound: a PATH with the tools
# the demo needs and no GNU timeout.
nognu="$work/nognu"
mkdir -p "$nognu"
for tool in bash env git python3 sed head cat rm mktemp seq sleep touch grep awk; do
  ln -sf "$(command -v "$tool")" "$nognu/$tool"
done
saved_path="$PATH"
PATH="$nognu"
signal_demo 1f-double-ctrl-c-python INT 130 INT
PATH="$saved_path"

# 2. No hq checkout: start nothing, exit 65, name the public fallback.
run_demo no-hq -u HQ_TOOLS FAKE_WARMUP=ok
[[ $rc -eq 65 ]] || fail "2: expected exit 65 without HQ_TOOLS (rc=$rc)"
[[ ! -e "$work/state/wrapper-started" ]] || fail "2: the warmup wrapper ran without an hq checkout"
! called "testbox stop" || fail "2: the demo touched a box without the hq wrapper"
grep -q 'HQ_TOOLS' "$log" || fail "2: the message does not say how to point at an hq checkout"
grep -q 'cmux-tui/README.md' "$log" || fail "2: the message does not name the public fallback"

echo "ok: the demo stops its box and cancels its run on every failure, and needs no personal path"
