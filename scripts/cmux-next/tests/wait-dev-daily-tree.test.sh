#!/usr/bin/env bash
# wait-dev-daily-tree.sh: a cmux NEXT DEV daily run builds exactly the SHA the
# dispatcher asked for, so it cannot hand a cold cmux-tui tree to a later
# same-tree run: that run starts only while the branch tip is still this SHA
# (scripts/ci/cmux_next_tree_notify.py is_current), and feat-cmux-next moves
# every few minutes. From 01:59Z on 2026-10-14 every DEV daily run deferred and
# published nothing (source run 38549784378 at 55e171d0: routing jobs only).
# The run now waits for its own tree and builds it. No network: the probe is a stub.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/scripts/cmux-next/wait-dev-daily-tree.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf '%s\n' "$@" >&2; exit 1; }

# The stub probe answers from a queue: one state per call.
cat > "$TMP/probe" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == probe ]] || exit 9
[[ "${CMUX_TUI_TREE_RECHECK_SECONDS:-}" == 0 && "${CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS:-}" == 0 ]] || { echo "the waiter must not wait inside the probe" >&2; exit 9; }
echo "${CMUX_TUI_TREE_DISPATCH:-unset}" >> "$QUEUE.dispatch"
n=$(cat "$QUEUE.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$QUEUE.n"
state=$(sed -n "${n}p" "$QUEUE"); state=${state:-deferred}
{ echo "tree_state=$state"; echo "tree_key=abc"; echo "tree_fetch_key="; echo "tree_reason=stub $state"; } >> "$GITHUB_OUTPUT"
STUB
chmod +x "$TMP/probe"

run() { # <states...>
  printf '%s\n' "$@" > "$TMP/queue"; rm -f "$TMP/queue.n" "$TMP/queue.dispatch"; : > "$TMP/out"
  status=0
  out=$(CMUX_TUI_TREE_DISPATCH=1 QUEUE="$TMP/queue" GITHUB_OUTPUT="$TMP/out" CMUX_DEV_TREE_PROBE="$TMP/probe" \
    CMUX_DEV_TREE_POLL_SECONDS=0 CMUX_DEV_TREE_WAIT_SECONDS="${WAIT:-60}" bash "$SCRIPT" 2>&1) || status=$?
}
[[ -f "$SCRIPT" ]] || fail "missing $SCRIPT"

# Deferred twice, then published: ready, after three looks.
run deferred deferred ready
[[ "$status" == 0 ]] || fail "a tree that publishes while waiting must succeed (exit $status):" "$out"
grep -qx "tree_state=ready" "$TMP/out" || fail "the job output must say ready:" "$(cat "$TMP/out")"
[[ "$(cat "$TMP/queue.n")" == 3 ]] || fail "expected 3 probes, got $(cat "$TMP/queue.n")"
[[ "$(grep -c '^tree_state=' "$TMP/out")" == 1 ]] || fail "only the final probe's outputs are kept:" "$(cat "$TMP/out")"

# A probe that just re-dispatched the publisher says failed until GitHub
# lists the new run: a failed answer is looked at again before giving up.
run failed ready
[[ "$status" == 0 ]] && grep -qx "tree_state=ready" "$TMP/out" || fail "a failed answer followed by ready must succeed (exit $status):" "$out"

# The probe can say failed while a same-tree artifacts run is still active
# (DEV run 38562080086 gave up at 12:25Z while run 38561677744 was publishing
# its tree). Failed answers are polled like deferred ones until the deadline.
run failed failed failed failed ready
[[ "$status" == 0 ]] && grep -qx "tree_state=ready" "$TMP/out" || fail "repeated failed answers followed by ready must succeed (exit $status):" "$out"
[[ "$(cat "$TMP/queue.n")" == 5 ]] || fail "expected 5 probes, got $(cat "$TMP/queue.n")"
# Each probe may re-dispatch a heavy artifacts run: only the probes up to the
# first failed answer may, so a tree whose build keeps failing is not rebuilt
# for the whole wait.
[[ "$(tr '\n' ' ' < "$TMP/queue.dispatch")" == "1 0 0 0 0 " ]] || fail "dispatch must stop after the first failed answer: $(tr '\n' ' ' < "$TMP/queue.dispatch")"

# Nothing published it by the deadline: fail visibly with the last state.
WAIT=0 run failed failed
[[ "$status" != 0 ]] || fail "a failed tree must fail the wait at the deadline:" "$out"
grep -qx "tree_state=failed" "$TMP/out" || fail "the output must carry the failed state:" "$(cat "$TMP/out")"
grep -q "still not published" <<<"$out" || fail "the deadline must give a reason:" "$out"

# Still deferred at the deadline: fail, saying so.
WAIT=0 run deferred deferred deferred
[[ "$status" != 0 ]] && grep -q "still not published" <<<"$out" || fail "a deadline must fail with a reason (exit $status):" "$out"

echo "PASS: a DEV daily run waits for its own cmux-tui tree, then builds it"
