#!/bin/bash
# ============================================================================
# Fails if remote-tmux gains a new sleep, timer, or poll loop.
#
# Remote-tmux waits on things constantly — a control-mode reply, a shared master, a person
# finishing a login — and every one of those has an event to wait on. A timer instead of the
# event is not a style preference: its interval is dead time a frozen mirror spends after the
# thing it was waiting for already happened, and it can miss the event entirely.
#
# This exists because knowing that is not enough. A reviewer caught a `Task.sleep` backoff in
# the login waiter that had shipped with a comment claiming "there is no event to subscribe
# to" — the event was the ControlMaster socket being created, and `FileWatcher` had been in
# the tree the whole time. Nothing failed when that went in, so nothing will fail the next
# time either, unless something checks.
#
# Adding a wait that genuinely has no edge is allowed, but it has to be listed below with the
# reason, which makes the exception visible in review instead of implicit in a diff.
#
# Usage: scripts/lint-remote-tmux-no-polling.sh
# Exit 0 when clean, 1 with the offending file:line otherwise, 2 when the scan itself failed.
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# Product sources only. Tests may need to drive time directly, and scripts are harnesses
# where polling an external process is often the only option available. One glob: it
# already covers every RemoteTmuxController+*.swift, and a second would scan them twice.
# LINT_SCOPE_DIR points the scan at a fixture tree; the self-test uses it.
SCOPE_DIR="${LINT_SCOPE_DIR:-Sources}"
SCOPE=("$SCOPE_DIR"/RemoteTmux*.swift)

# Primitives that make a wait time-based rather than event-based. `.sleep(` and `.asyncAfter(`
# are matched on their own so the receiver's shape does not matter: Task, Thread, a
# ContinuousClock built inline or a clock held in a property, DispatchQueue.main, .global(),
# a named queue, all count.
PATTERN='\.sleep[[:space:]]*\(|usleep\(|\.asyncAfter\(|DispatchSourceTimer|Timer\.scheduledTimer'

# Waits that predate this guard, recorded so it blocks NEW ones without pretending the
# existing ones are all fine. Several are worth revisiting — the sizing debounces in
# particular, since sizing convergence is supposed to be driven by tmux's ordered
# %begin/%end acknowledgements rather than a wall clock. Removing an entry from this list
# is progress; adding one needs the reason to say why no edge exists.
#
# Each entry names ONE wait: file, enclosing function, and the wait's own line with
# whitespace collapsed. A second sleep added to a baselined function is therefore new and
# fails; moving the existing one to another line number is not. Regenerate with
# --write-baseline after deliberately removing a wait.
BASELINE_FILE="${LINT_BASELINE_FILE:-scripts/remote-tmux-polling-baseline.txt}"

# Exceptions introduced deliberately, with the reason no edge exists. These are keyed by
# function on purpose: the reason covers the wait's role in that function, and a reviewer
# reads the reason. Only functions that exist in the tree belong here; a stale name would
# let a future wait in a function that happens to reuse it slip through.
ALLOW=(
  "Sources/RemoteTmuxControlConnection.swift:terminateProcessTree|SIGKILL escalation after SIGTERM. The edge would be 'the process handled the signal', and a process that IGNORES SIGTERM emits nothing at all — the absence of an exit is only observable by giving it a moment and looking again."
  "Sources/RemoteTmuxControlConnection.swift:scheduleReconnectAttempt|Reconnect backoff for a host that is unreachable. The edge would be 'the host came back', which nothing local can observe; retrying IS the observation."

  # Deadline arms, not polls: each of these races `await <edge>` against a sleep inside the same task
  # group, so the edge is what normally ends the wait and the sleep only bounds it. The lint cannot see
  # that shape, which is why they are listed rather than fixed — see the task note about making the rule
  # structural instead.
  "Sources/RemoteTmuxController+Attach.swift:mirrorsWithPublishedTopology|Deadline arm racing waitUntilInitialTopology() for the whole mirror set"
  "Sources/RemoteTmuxController+Attach.swift:dropMirrorIfTopologyNeverPublishes|Deadline arm racing waitUntilInitialTopology() for one late mirror"
  "Sources/RemoteTmuxViewConnection.swift:awaitFirstWorkspaces|Deadline arm racing the view's first workspace publication"
  "Sources/RemoteTmuxController.swift:awaitNewWorkspace|Deadline arm racing the new-workspace signal"
  "Sources/RemoteTmuxControlConnection+PaneSubscriptions.swift:queryWithTimeout|Deadline arm racing the reply for this command number"
  "Sources/RemoteTmuxControlConnection.swift:detachThenStop|Backstop for a stream that has stopped answering; tmux's own %exit ends the wait and cancels it"
  "Sources/RemoteTmuxSessionMirror+OutputRouting.swift:schedulePaneSeedDeliveryDeadline|Deadline arm on a pane's readiness wait: the task is cancelled when the surface becomes ready, and on expiry the seed is drained or gracefully deferred rather than retried"
  "Sources/RemoteTmuxViewConnection.swift:scheduleBringupRetry|Bounded backoff. The bringup it retries failed WITHOUT producing an edge to wait on, which is the whole reason it exists"
  "Sources/RemoteTmuxControlConnection.swift:detachAwaitingExit|Deadline arm racing the %exit observer registered beside it; the observer ends the wait and cancels the deadline"
  "Sources/RemoteTmuxControlConnection+PaneSubscriptions.swift:queryOutcomeWithTimeout|Deadline arm racing the reply for this command number; the reply removes the completion and the timeout task finds nothing to resume"
  "Sources/RemoteTmuxViewConnection.swift:wait|The one-shot timer behind RemoteTmuxRetryDelay, which only scheduleBringupRetry uses for its bounded backoff; cancelling the task releases it"
)

normalize() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g; s/[[:space:]]+$//' <<<"$1"; }

# Run the scan first and keep its status: 1 is "no matches" and fine, anything above 1 is a
# failure of the scan itself (an unreadable file, a bad pattern) and must not read as clean.
# A lint that cannot run must not look clean. mktemp failing leaves an empty path, the
# redirection below then fails, and grep's status reads as "no matches" -- a green run on
# a scan that never happened.
hits_file="$(mktemp)" || { echo "lint-remote-tmux-no-polling: mktemp failed" >&2; exit 2; }
used_file="$(mktemp)" || { echo "lint-remote-tmux-no-polling: mktemp failed" >&2; exit 2; }
trap 'rm -f "$hits_file" "$used_file"' EXIT
# grep's own diagnostics go straight to stderr. A scratch file for them would be one more
# redirect that can fail before grep runs, and that failure would read as "no matches".
grep -nHE "$PATTERN" "${SCOPE[@]}" > "$hits_file"   # -H: one file in scope must still prefix its name
scan_rc=$?
if [ "$scan_rc" -gt 1 ]; then
  echo "lint-remote-tmux-no-polling: the source scan failed (grep exit $scan_rc)" >&2
  exit 2
fi

write_baseline=0
[ "${1:-}" = "--write-baseline" ] && write_baseline=1
if [ "$write_baseline" -eq 1 ] && ! : > "$BASELINE_FILE"; then
  echo "lint-remote-tmux-no-polling: cannot write $BASELINE_FILE" >&2; exit 2
fi

fail=0
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  file="${hit%%:*}"
  rest="${hit#*:}"
  line="${rest%%:*}"
  body="$(normalize "${rest#*:}")"
  case "$body" in //*) continue ;; esac

  # Find the enclosing func by walking back to the nearest declaration.
  symbol="$(awk -v n="$line" 'NR<=n && /func [A-Za-z_]/ { s=$0 } END { print s }' "$file" \
    | sed -E 's/.*func ([A-Za-z_][A-Za-z0-9_]*).*/\1/')"
  key="$file:$symbol:$body"

  if [ "$write_baseline" -eq 1 ]; then
    allowed_by_list=0
    for entry in "${ALLOW[@]}"; do [ "${entry%%|*}" = "$file:$symbol" ] && allowed_by_list=1; done
    if [ "$allowed_by_list" -eq 0 ] && ! printf '%s\n' "$key" >> "$BASELINE_FILE"; then
      echo "lint-remote-tmux-no-polling: cannot append to $BASELINE_FILE" >&2; exit 2
    fi
    continue
  fi

  allowed=0
  for entry in "${ALLOW[@]}"; do
    if [ "${entry%%|*}" = "$file:$symbol" ]; then allowed=1; break; fi
  done
  # Count, do not just match. One baseline line authorises ONE wait: two identical waits in
  # the same function share a key, so a bare `grep -q` would let the second -- newly added --
  # one ride the first's entry. Each hit consumes an allowance.
  if [ "$allowed" -eq 0 ] && [ -f "$BASELINE_FILE" ]; then
    allowance="$(grep -cxF "$key" "$BASELINE_FILE" 2>/dev/null)" || allowance=0
    used="$(grep -cxF "$key" "$used_file" 2>/dev/null)" || used=0
    if [ "${allowance:-0}" -gt "${used:-0}" ]; then
      allowed=1
      if ! printf '%s\n' "$key" >> "$used_file"; then
        echo "lint-remote-tmux-no-polling: cannot record a used baseline allowance" >&2; exit 2
      fi
    fi
  fi

  if [ "$allowed" -eq 0 ]; then
    echo "lint-remote-tmux-no-polling: $file:$line — time-based wait in '$symbol'" >&2
    echo "    $body" >&2
    fail=1
  fi
done < "$hits_file"

if [ "$write_baseline" -eq 1 ]; then
  if ! sort -o "$BASELINE_FILE" "$BASELINE_FILE"; then
    echo "lint-remote-tmux-no-polling: could not sort $BASELINE_FILE" >&2; exit 2
  fi
  echo "lint-remote-tmux-no-polling: wrote $(wc -l < "$BASELINE_FILE" | tr -d ' ') baseline entries to $BASELINE_FILE"
  exit 0
fi

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'MSG'

Waiting on a timer means the event that ends the wait was not used. Find the edge first:
  - a control-mode reply            -> sendTracked / the %begin/%end correlation
  - a file or socket appearing      -> FileWatcher (watches the parent directory too, so
                                       creation is visible for a path that does not exist yet)
  - terminal output, e.g. a marker  -> the per-surface PTY tee detectors
  - a workspace closing             -> the TabManager close path calls the controller
An event-driven wait must also check its condition once up front: an edge that already
happened is never delivered.

If there is genuinely no edge, add the symbol to ALLOW in this script with the reason.
MSG
  exit 1
fi

echo "lint-remote-tmux-no-polling: ok (${#ALLOW[@]} documented, $(wc -l < "$BASELINE_FILE" 2>/dev/null | tr -d ' ') baselined)"
