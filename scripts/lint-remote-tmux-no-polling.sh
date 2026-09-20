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
# where polling an external process is often the only option available. The scope is every
# Swift file with RemoteTmux in its path under the product roots, so an extension file such
# as TerminalController+RemoteTmux.swift and a package directory named RemoteTmux are scanned
# as well as the files whose name starts with it. Symlinks are followed, so a linked file or
# directory is scanned like any other.
# LINT_SCOPE_DIR points the scan at a fixture tree; the self-test uses it.
if [ -n "${LINT_SCOPE_DIR:-}" ]; then SCOPE_ROOTS=("$LINT_SCOPE_DIR"); else SCOPE_ROOTS=(Sources Packages); fi
# A find that fails, or finds nothing, is a scan that did not happen. Neither may read as clean.
if ! scope_list="$(find -L "${SCOPE_ROOTS[@]}" -type f -name '*.swift' -path '*RemoteTmux*' ! -path '*/Tests/*' | LC_ALL=C sort)"; then
  echo "lint-remote-tmux-no-polling: could not list sources under ${SCOPE_ROOTS[*]}" >&2; exit 2
fi
SCOPE=()
while IFS= read -r scoped; do [ -n "$scoped" ] && SCOPE+=("$scoped"); done <<<"$scope_list"
if [ "${#SCOPE[@]}" -eq 0 ]; then
  echo "lint-remote-tmux-no-polling: no remote-tmux sources found under ${SCOPE_ROOTS[*]}" >&2; exit 2
fi

# Primitives that make a wait time-based rather than event-based. `.sleep` and `.asyncAfter`
# are matched on their own so the receiver's shape does not matter: Task, Thread, a
# ContinuousClock built inline or a clock held in a property, DispatchQueue.main, .global(),
# a named queue, all count. The opening parenthesis is part of the match, with any spaces
# before it, because `usleep (5)` is the same call as `usleep(5)`. It has to be on the same
# line: Swift does not read a parenthesis at the start of the next line as a call (the compiler
# reports the function as unused), so that shape cannot hide a wait. Requiring the parenthesis
# also keeps an enum case `.sleep` and an injected `self.sleep = sleep` from reading as waits.
PATTERN='(\.sleep|(^|[^A-Za-z0-9_])usleep|\.asyncAfter)[[:space:]]*\(|DispatchSourceTimer|Timer\.scheduledTimer'

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

# Exceptions introduced deliberately, with the reason no edge exists. Each exception is two
# lines: the wait, written as a baseline key (file, enclosing function, the wait's own line
# with whitespace collapsed), then the reason. Like a baseline entry it covers ONE wait. A
# second wait added to the same function is new and fails, so every exception shows up in
# review with its own reason. Only waits that exist in the tree belong here.
# LINT_ALLOW_FILE replaces this list with a file in the same two-line form; the self-test uses it.
ALLOW=(
  "Sources/RemoteTmuxControlConnection.swift:scheduleReconnectAttempt:try await ContinuousClock().sleep(for: .seconds(delay))"
  "Reconnect backoff for a host that is unreachable. The edge would be 'the host came back', which nothing local can observe; retrying IS the observation."
  "Sources/RemoteTmuxSessionMirror+OutputRouting.swift:schedulePaneSeedDeliveryDeadline:try await ContinuousClock().sleep(for: .seconds(5))"
  "Deadline arm on a pane's readiness wait: the task is cancelled when the surface becomes ready, and on expiry the seed is drained or gracefully deferred rather than retried"
  "Sources/RemoteTmuxControlConnection+PaneSubscriptions.swift:queryOutcomeWithTimeout:try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))"
  "Deadline arm racing the reply for this command number; the reply removes the completion and the timeout task finds nothing to resume"
  "Sources/RemoteTmuxControlConnection.swift:detachAwaitingExit:DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)"
  "Deadline arm racing the %exit observer registered beside it; the observer ends the wait and cancels the deadline"
  "Sources/RemoteTmuxControlConnection.swift:detachThenStop:DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: backstop)"
  "Backstop for a stream that has stopped answering; tmux's own %exit ends the wait and cancels it"
  "Sources/RemoteTmuxControlConnection.swift:terminateProcessTree:try? await Task.sleep(nanoseconds: 2_000_000_000)"
  "SIGKILL escalation after SIGTERM. The edge would be 'the process handled the signal', and a process that IGNORES SIGTERM emits nothing at all — the absence of an exit is only observable by giving it a moment and looking again."
  "Sources/RemoteTmuxController.swift:awaitNewWorkspace:try? await Task.sleep(for: deadline)"
  "Deadline arm racing the new-workspace signal"
  "Sources/RemoteTmuxViewConnection.swift:wait:private var timer: DispatchSourceTimer?"
  "The one-shot timer behind RemoteTmuxRetryDelay, which only scheduleBringupRetry uses for its bounded backoff; cancelling the task releases it"
)
if [ -n "${LINT_ALLOW_FILE:-}" ]; then
  ALLOW=()
  while IFS= read -r allow_line; do ALLOW+=("$allow_line"); done < "$LINT_ALLOW_FILE" || {
    echo "lint-remote-tmux-no-polling: cannot read $LINT_ALLOW_FILE" >&2; exit 2; }
fi
if [ $(( ${#ALLOW[@]} % 2 )) -ne 0 ]; then
  echo "lint-remote-tmux-no-polling: ALLOW must hold a wait line and a reason line per exception" >&2; exit 2
fi
ALLOW_KEYS=()
for (( allow_i = 0; allow_i < ${#ALLOW[@]}; allow_i += 2 )); do ALLOW_KEYS+=("${ALLOW[$allow_i]}"); done
# How many documented exceptions name this exact wait.
documented_count() {
  local wanted="$1" n=0 k
  for k in ${ALLOW_KEYS[@]+"${ALLOW_KEYS[@]}"}; do [ "$k" = "$wanted" ] && n=$((n+1)); done
  echo "$n"
}

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

  # Count, do not just match. One documented exception or one baseline line authorises ONE
  # wait: two identical waits in the same function share a key, so a bare match would let the
  # second -- newly added -- one ride the first's entry. Each hit consumes an allowance,
  # documented exceptions first.
  documented="$(documented_count "$key")"
  used="$(grep -cxF "$key" "$used_file" 2>/dev/null)" || used=0
  allowed=0
  if [ "$write_baseline" -eq 1 ]; then
    if [ "${documented:-0}" -gt "${used:-0}" ]; then
      allowed=1
    elif ! printf '%s\n' "$key" >> "$BASELINE_FILE"; then
      echo "lint-remote-tmux-no-polling: cannot append to $BASELINE_FILE" >&2; exit 2
    fi
  else
    baselined=0
    if [ -f "$BASELINE_FILE" ]; then baselined="$(grep -cxF "$key" "$BASELINE_FILE" 2>/dev/null)" || baselined=0; fi
    [ $(( ${documented:-0} + ${baselined:-0} )) -gt "${used:-0}" ] && allowed=1
  fi
  if [ "$allowed" -eq 1 ] && ! printf '%s\n' "$key" >> "$used_file"; then
    echo "lint-remote-tmux-no-polling: cannot record a used allowance" >&2; exit 2
  fi
  [ "$write_baseline" -eq 1 ] && continue

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

If there is genuinely no edge, add the wait to ALLOW in this script: its key line, then the reason.
MSG
  exit 1
fi

echo "lint-remote-tmux-no-polling: ok (${#ALLOW_KEYS[@]} documented, $(wc -l < "$BASELINE_FILE" 2>/dev/null | tr -d ' ') baselined)"
