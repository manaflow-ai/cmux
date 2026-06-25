#!/usr/bin/env bash
#
# crash-recovery-e2e.sh — live re-validation harness for the agent-first
# crash/update recovery feature (plan U14 / R18).
#
# It scripts the *safe* force-quit → relaunch cycle this feature is validated
# against, and asserts the acceptance bar: a restored window recovers ITS OWN
# work (a verified binding resumes its exact session; a broken binding yields the
# honest recovery prompt) — never a guessed/mis-attributed session, never a
# filesystem meander.
#
# SAFETY — this harness ONLY ever acts on a TAGGED, bundle-isolated Debug build
# (its own bundle id `com.cmuxterm.app.debug.<tag>`, its own socket, its own
# `session-<bundleid>.json` snapshot). It NEVER touches the user's main cmux:
#   * It refuses to run without a --tag.
#   * It refuses any tag whose resolved bundle id is the main app
#     (`com.cmuxterm.app`) or any non-`*.debug.*` id.
#   * `forcequit` kills ONLY PIDs whose executable path is under this tag's
#     DerivedData Debug products dir. It never `killall`/`pkill`s "cmux", and it
#     aborts if a resolved PID is the main app.
#
# Usage:
#   scripts/crash-recovery-e2e.sh --tag <tag> <command>
#
# Commands:
#   build           Build the tagged Debug app (delegates to reload.sh --tag).
#   launch          Launch the tagged app (delegates to reload.sh --tag --launch).
#   bindings        Dump the persisted window↔session bindings from the snapshot.
#   snapshot        Print the path + mtime of this tag's session snapshot JSON.
#   forcequit       GUARDED kill -9 of ONLY this tag's app PIDs (simulated crash).
#   relaunch        forcequit, then launch — the crash→restore cycle.
#   verify          Post-relaunch checks against the acceptance bar (R18).
#   guard-selftest  Prove the main-app guard refuses to target the main app.
#
# The `verify` command prints the full acceptance checklist to run interactively
# while observing the restored UI.

set -euo pipefail

# ----------------------------------------------------------------------------
# Arg parsing
# ----------------------------------------------------------------------------
TAG=""
CMD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    --tag=*)
      TAG="${1#--tag=}"
      shift
      ;;
    build|launch|bindings|snapshot|forcequit|relaunch|verify|guard-selftest)
      CMD="$1"
      shift
      ;;
    -h|--help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "error: --tag <tag> is REQUIRED. This harness never acts on the main app." >&2
  exit 2
fi
if [[ ! "$TAG" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: invalid tag: $TAG" >&2
  exit 2
fi
if [[ -z "$CMD" ]]; then
  echo "error: a command is required (build|launch|bindings|snapshot|forcequit|relaunch|verify|guard-selftest)." >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ----------------------------------------------------------------------------
# Tag → identity derivation (mirrors reload.sh / cmux-debug-cli.sh)
# ----------------------------------------------------------------------------
sanitize_path() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
sanitize_bundle() { printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '-'; }

TAG_SLUG="$(sanitize_path "$TAG")"
TAG_ID="$(sanitize_bundle "$TAG")"
BUNDLE_ID="com.cmuxterm.app.debug.${TAG_ID}"
DERIVED_DATA="${HOME}/Library/Developer/Xcode/DerivedData/cmux-${TAG_SLUG}"
DEBUG_PRODUCTS="${DERIVED_DATA}/Build/Products/Debug"
APP_PATH="${DEBUG_PRODUCTS}/cmux DEV ${TAG_SLUG}.app"
APP_EXEC="${APP_PATH}/Contents/MacOS/cmux"
SOCKET_PATH="/tmp/cmux-debug-${TAG_SLUG}.sock"

# session-<safeBundleId>.json — SessionSnapshotRepository replaces any char not
# in [A-Za-z0-9._-] with '_'. Our bundle id already only uses safe chars.
SAFE_BUNDLE_ID="$(printf '%s' "$BUNDLE_ID" | sed 's/[^A-Za-z0-9._-]/_/g')"
SNAPSHOT_DIR="${HOME}/Library/Application Support/cmux"
SNAPSHOT_JSON="${SNAPSHOT_DIR}/session-${SAFE_BUNDLE_ID}.json"

# ----------------------------------------------------------------------------
# The main-app guard — the whole reason this harness exists
# ----------------------------------------------------------------------------
MAIN_BUNDLE_ID="com.cmuxterm.app"

assert_not_main_app() {
  if [[ "$BUNDLE_ID" == "$MAIN_BUNDLE_ID" ]]; then
    echo "REFUSING: resolved bundle id is the MAIN app ($MAIN_BUNDLE_ID)." >&2
    exit 3
  fi
  case "$BUNDLE_ID" in
    com.cmuxterm.app.debug.*) : ;; # ok: tagged debug build
    *)
      echo "REFUSING: bundle id '$BUNDLE_ID' is not a tagged debug build (com.cmuxterm.app.debug.*)." >&2
      exit 3
      ;;
  esac
}

# The absolute exec path of THIS tag's app — the single source of truth every
# guard compares against.
TAGGED_EXEC_MARKER="/cmux-${TAG_SLUG}/Build/Products/Debug/cmux DEV ${TAG_SLUG}.app/Contents/MacOS/cmux"

# Resolve a PID's running executable path via lsof. `lsof -Fn` prints one field
# per line; file paths are the `n`-prefixed lines (`sed -n 's/^n//p'` extracts
# them cleanly — no fragile `txt`-substring filtering). Returns the first
# resolved path, or empty.
resolve_exec_path() {
  local pid="$1"
  lsof -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | grep -F "$TAGGED_EXEC_MARKER" | head -1
}

# True iff `path` is THIS tag's tagged Debug exec and not an installed app.
is_tagged_exec_path() {
  local path="$1"
  [[ -n "$path" ]] \
    && [[ "$path" == *"$TAGGED_EXEC_MARKER"* ]] \
    && [[ "$path" != *"/Applications/"* ]]
}

# Echo the PIDs whose executable path is THIS tag's app exec, and nothing else.
# Cross-checks each PID's resolved exec path so a coincidental command-line match
# can never select the main app.
tagged_pids() {
  assert_not_main_app
  local pid path
  for pid in $(pgrep -f "$TAGGED_EXEC_MARKER" 2>/dev/null || true); do
    path="$(resolve_exec_path "$pid")"
    if is_tagged_exec_path "$path"; then
      echo "$pid"
    fi
  done
}

# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------
cmd_build() {
  assert_not_main_app
  echo "[build] reload.sh --tag $TAG"
  CMUX_SKIP_ZIG_BUILD=1 "${REPO_ROOT}/scripts/reload.sh" --tag "$TAG"
}

cmd_launch() {
  assert_not_main_app
  echo "[launch] reload.sh --tag $TAG --launch"
  CMUX_SKIP_ZIG_BUILD=1 "${REPO_ROOT}/scripts/reload.sh" --tag "$TAG" --launch
}

cmd_snapshot() {
  assert_not_main_app
  echo "bundle id : $BUNDLE_ID"
  echo "snapshot  : $SNAPSHOT_JSON"
  if [[ -f "$SNAPSHOT_JSON" ]]; then
    echo "mtime     : $(stat -f '%Sm' "$SNAPSHOT_JSON")"
    echo "size      : $(stat -f '%z' "$SNAPSHOT_JSON") bytes"
  else
    echo "mtime     : (no snapshot yet — launch the tagged app and start an agent)"
  fi
}

# Surface the persisted window↔session bindings so a human (or a follow-up
# assertion) can see, per restored panel: its name, agent kind, session id, cwd,
# and transcript path. Reads the snapshot JSON; falls back to the live debug CLI.
cmd_bindings() {
  assert_not_main_app
  if [[ ! -f "$SNAPSHOT_JSON" ]]; then
    echo "no snapshot at $SNAPSHOT_JSON — launch the tagged app and start an agent first." >&2
    exit 1
  fi
  echo "== bindings from $SNAPSHOT_JSON =="
  # Pull the fields most diagnostic of the U9 binding-coverage defect: how many
  # panels carry a session id vs. came up '[no agent]'.
  python3 - "$SNAPSHOT_JSON" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
def walk(node, found):
    if isinstance(node, dict):
        keys = node.keys()
        if any(k in keys for k in ("sessionId", "customTitle", "transcriptPath", "customTitleSource")):
            found.append({
                "title": node.get("customTitle"),
                "titleSource": node.get("customTitleSource"),
                "sessionId": node.get("sessionId"),
                "transcriptPath": node.get("transcriptPath"),
                "cwd": node.get("cwd") or node.get("workingDirectory"),
            })
        for v in node.values():
            walk(v, found)
    elif isinstance(node, list):
        for v in node:
            walk(v, found)
found = []
walk(data, found)
withsess = [f for f in found if f.get("sessionId")]
print(f"records with session-relevant fields: {len(found)}; with sessionId: {len(withsess)}")
for f in found:
    print(json.dumps(f, ensure_ascii=False))
PY
}

cmd_forcequit() {
  assert_not_main_app
  local pids
  pids="$(tagged_pids || true)"
  if [[ -z "$pids" ]]; then
    echo "[forcequit] no running tagged PIDs for '$TAG' (nothing to crash)."
    return 0
  fi
  echo "[forcequit] simulating a crash — kill -9 of tagged PIDs: $pids"
  local pid path
  for pid in $pids; do
    # Re-assert per-PID right before the kill: the PID's CURRENT exec path must
    # still be this tag's tagged Debug exec. Guards against a PID recycled to an
    # unrelated process between resolution and kill — never the main app.
    path="$(resolve_exec_path "$pid")"
    if ! is_tagged_exec_path "$path"; then
      echo "  SKIP $pid (no longer this tag's exec: '${path:-unresolved}')"
      continue
    fi
    kill -9 "$pid" && echo "  killed $pid"
  done
}

wait_for_tagged_exit() {
  local pids pid
  while true; do
    pids="$(tagged_pids || true)"
    if [[ -z "$pids" ]]; then
      return 0
    fi

    local pid_args=()
    for pid in $pids; do
      pid_args+=("$pid")
    done

    # macOS kqueue gives us a process-exit event for arbitrary PIDs. This waits
    # on the lifecycle signal itself while still bounding a stuck exit.
    if ! python3 - "${pid_args[@]}" <<'PY'
import errno
import os
import select
import sys
import time

deadline = time.monotonic() + 10.0
remaining = set()
kqueue = select.kqueue()

for raw_pid in sys.argv[1:]:
    pid = int(raw_pid)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        continue
    remaining.add(pid)
    try:
        event = select.kevent(
            pid,
            filter=select.KQ_FILTER_PROC,
            flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
            fflags=select.KQ_NOTE_EXIT,
        )
        kqueue.control([event], 0, 0)
    except OSError as exc:
        if exc.errno == errno.ESRCH:
            remaining.discard(pid)
            continue
        raise

while remaining:
    timeout = deadline - time.monotonic()
    if timeout <= 0:
        print(" ".join(str(pid) for pid in sorted(remaining)), file=sys.stderr)
        sys.exit(1)
    for event in kqueue.control(None, len(remaining), timeout):
        remaining.discard(event.ident)
PY
    then
      echo "[relaunch] timed out waiting for tagged PIDs to exit: $pids" >&2
      return 1
    fi
  done
}

cmd_relaunch() {
  cmd_forcequit
  wait_for_tagged_exit
  cmd_launch
}

cmd_verify() {
  assert_not_main_app
  echo "== R18 acceptance checks (tag: $TAG) =="
  echo "Snapshot bindings BEFORE you read the restored windows:"
  cmd_bindings || true
  cat <<EOF

Manual acceptance (observe the relaunched tagged app):
  [ ] A window with a verified binding resumed ITS OWN session (continues the
      specific task without exposing transcript paths or session filenames).
  [ ] A window whose binding could NOT be verified showed the HONEST recovery
      prompt (cwd-scoped, names no session) — not a confident wrong guess, not a
      filesystem meander, not a session picker.
  [ ] Two agent windows each recovered their OWN session — no cross-bleed.
  [ ] Restored window names reflect verified work; no window wears another
      session's name.
Record evidence (screenshots / transcript excerpts) in
plans/feat-crash-session-resume/U14-acceptance.md.
EOF
}

# Prove the guard: a tag that (hypothetically) resolved to the main app is
# refused. We can't actually make TAG resolve to the bare main id, so we assert
# the guard logic directly.
cmd_guard_selftest() {
  echo "== guard self-test =="
  echo "this tag's bundle id: $BUNDLE_ID"
  ( BUNDLE_ID="$MAIN_BUNDLE_ID"; assert_not_main_app ) \
    && { echo "FAIL: guard allowed the main app"; exit 1; } \
    || echo "PASS: guard refuses the main app bundle id"
  ( BUNDLE_ID="com.cmuxterm.app.nightly"; assert_not_main_app ) \
    && { echo "FAIL: guard allowed a non-debug id"; exit 1; } \
    || echo "PASS: guard refuses a non-debug bundle id"
  assert_not_main_app && echo "PASS: this tagged bundle id is allowed"
}

case "$CMD" in
  build) cmd_build ;;
  launch) cmd_launch ;;
  bindings) cmd_bindings ;;
  snapshot) cmd_snapshot ;;
  forcequit) cmd_forcequit ;;
  relaunch) cmd_relaunch ;;
  verify) cmd_verify ;;
  guard-selftest) cmd_guard_selftest ;;
  *) echo "error: unknown command: $CMD" >&2; exit 2 ;;
esac
