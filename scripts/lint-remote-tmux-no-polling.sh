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
# Exit 0 when clean, 1 with the offending file:line otherwise.
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# Product sources only. Tests may need to drive time directly, and scripts are harnesses
# where polling an external process is often the only option available.
SCOPE=(Sources/RemoteTmux*.swift Sources/RemoteTmuxController+*.swift)

# Primitives that make a wait time-based rather than event-based.
# `\.asyncAfter\(` rather than a `DispatchQueue.…` prefix: the receiver can be any expression
# (`DispatchQueue.global(qos: .background)`, a stored queue), and every one of them is a
# time-based wait. Matching the call, not the queue, closes that gap.
PATTERN='Task\.sleep|Thread\.sleep|usleep\(|\.asyncAfter\(|DispatchSourceTimer|Timer\.scheduledTimer|ContinuousClock\(\)\.sleep'

# Waits that predate this guard, recorded so it blocks NEW ones without pretending the
# existing ones are all fine. Several are worth revisiting — the sizing debounces in
# particular, since sizing convergence is supposed to be driven by tmux's ordered
# %begin/%end acknowledgements rather than a wall clock. Removing an entry from this list
# is progress; adding one needs the reason to say why no edge exists.
BASELINE_FILE="scripts/remote-tmux-polling-baseline.txt"

# Exceptions introduced deliberately, with the reason no edge exists.
ALLOW=(
  "Sources/RemoteTmuxControlConnection.swift:startLivenessMonitorIfNeeded|A transport that reconnects internally emits NO EOF for a network drop: its process stays up and the stream pauses, so a wedged transport is indistinguishable from an idle one. There is no event for 'still carrying the protocol' — the only way to know is to ask, so this probes rather than waits."
  "Sources/RemoteTmuxControlConnection.swift:scheduleReconnectAttempt|Reconnect backoff for a host that is unreachable. The edge would be 'the host came back', which nothing local can observe; retrying IS the observation."
)

fail=0
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  file="${hit%%:*}"
  rest="${hit#*:}"
  line="${rest%%:*}"

  # Find the enclosing func by walking back to the nearest declaration.
  symbol="$(awk -v n="$line" 'NR<=n && /func [A-Za-z_]/ { s=$0 } END { print s }' "$file" \
    | sed -E 's/.*func ([A-Za-z_][A-Za-z0-9_]*).*/\1/')"

  allowed=0
  for entry in "${ALLOW[@]}"; do
    key="${entry%%|*}"
    if [ "$key" = "$file:$symbol" ]; then allowed=1; break; fi
  done
  # Pre-existing waits are matched by file+symbol, not line number, so unrelated edits above
  # them do not turn into lint failures.
  if [ "$allowed" -eq 0 ] && [ -f "$BASELINE_FILE" ] \
     && grep -qxF "$file:$symbol" "$BASELINE_FILE"; then
    allowed=1
  fi

  if [ "$allowed" -eq 0 ]; then
    echo "lint-remote-tmux-no-polling: $file:$line — time-based wait in '$symbol'" >&2
    echo "    $(sed -n "${line}p" "$file" | sed 's/^[[:space:]]*//')" >&2
    fail=1
  fi
done < <(grep -nE "$PATTERN" "${SCOPE[@]}" 2>/dev/null \
  | awk -F: '{ body = substr($0, index($0, $3)); sub(/^[[:space:]]+/, "", body); if (body !~ /^\/\//) print }' || true)

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'EOF'

Waiting on a timer means the event that ends the wait was not used. Find the edge first:
  - a control-mode reply            -> sendTracked / the %begin/%end correlation
  - a file or socket appearing      -> FileWatcher (watches the parent directory too, so
                                       creation is visible for a path that does not exist yet)
  - terminal output, e.g. a marker  -> the per-surface PTY tee detectors
  - a workspace closing             -> the TabManager close path calls the controller
An event-driven wait must also check its condition once up front: an edge that already
happened is never delivered.

If there is genuinely no edge, add the symbol to ALLOW in this script with the reason.
EOF
  exit 1
fi

echo "lint-remote-tmux-no-polling: ok (${#ALLOW[@]} documented, $(wc -l < "$BASELINE_FILE" 2>/dev/null | tr -d ' ') baselined)"
