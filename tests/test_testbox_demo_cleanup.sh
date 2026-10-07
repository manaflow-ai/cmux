#!/usr/bin/env bash
# Behavior tests for scripts/blacksmith-testbox-demo.sh with fake `blacksmith`,
# `gh` and hq wrapper. No network, no real Testbox.
#  1. A box the wrapper names (TBX=) is stopped and its warmup run is
#     cancelled in every exit path: wrapper failure after TBX=, a wrapper
#     that hangs past the warmup bound, and a later step that fails.
#     Ctrl-C (SIGINT to the demo's process group, as a terminal sends it)
#     ends a running bounded step at once, stops the box and exits 130.
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
mkdir -p "$repo/scripts" "$repo/.github/workflows" "$repo/ghostty"
cp "$bounded" "$repo/scripts/"
echo "name: stub" >"$repo/.github/workflows/cmux-tui-testbox-warmup.yml"
echo ".{}" >"$repo/ghostty/build.zig.zon"
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

# 1d. Ctrl-C while the wrapper runs after naming the box. The bounded step
#     sits in its own process group under GNU timeout, so only the demo's
#     trap can end it. Job control gives the demo its own group to signal.
: >"$work/calls"
rm -f "$work/state/"*
log="$work/ctrl-c.log"
set -m
(cd "$repo" && exec env PATH="$bin:$PATH" FAKE_STATE="$work/state" HQ_TOOLS="$work/hq" \
  FAKE_WARMUP=hang-after-tbx CMUX_TESTBOX_DEMO_WARMUP_TIMEOUT=50 "$demo") >"$log" 2>&1 &
demo_pid=$!
set +m
for _ in $(seq 1 100); do [[ -e "$work/state/named" ]] && break; sleep 0.1; done
[[ -e "$work/state/named" ]] || fail "1d: the fake wrapper never named its box"
started=$SECONDS
kill -INT -- "-$demo_pid"
set +e
wait "$demo_pid"
rc=$?
set -e
(( SECONDS - started < 20 )) || fail "1d: Ctrl-C took $((SECONDS - started)) s to end the demo"
[[ $rc -eq 130 ]] || fail "1d: expected exit 130 after Ctrl-C (rc=$rc)"
called "blacksmith testbox stop --id tbx_hung" || fail "1d: box tbx_hung was not stopped after Ctrl-C"
called "gh run cancel 777" || fail "1d: the warmup run of tbx_hung was not cancelled after Ctrl-C"
! kill -0 "$(cat "$work/state/wrapper-started")" 2>/dev/null || fail "1d: the wrapper still runs after Ctrl-C"

# 2. No hq checkout: start nothing, exit 65, name the public fallback.
run_demo no-hq -u HQ_TOOLS FAKE_WARMUP=ok
[[ $rc -eq 65 ]] || fail "2: expected exit 65 without HQ_TOOLS (rc=$rc)"
[[ ! -e "$work/state/wrapper-started" ]] || fail "2: the warmup wrapper ran without an hq checkout"
! called "testbox stop" || fail "2: the demo touched a box without the hq wrapper"
grep -q 'HQ_TOOLS' "$log" || fail "2: the message does not say how to point at an hq checkout"
grep -q 'cmux-tui/README.md' "$log" || fail "2: the message does not name the public fallback"

echo "ok: the demo stops its box and cancels its run on every failure, and needs no personal path"
