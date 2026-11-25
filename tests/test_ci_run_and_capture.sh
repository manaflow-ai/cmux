#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
cleanup() {
  if [ "${startup_fifo_open:-0}" -eq 1 ]; then
    printf x >&9 || true
  fi
  if [ -n "${startup_capture_pid:-}" ]; then
    kill "$startup_capture_pid" 2>/dev/null || true
    wait "$startup_capture_pid" 2>/dev/null || true
  fi
  if [ -r "$TMP_DIR/startup/child.pid" ]; then
    kill -TERM -- "-$(cat "$TMP_DIR/startup/child.pid")" 2>/dev/null || true
  fi
  if [ -r "$TMP_DIR/child.pid" ]; then
    kill "$(cat "$TMP_DIR/child.pid")" 2>/dev/null || true
  fi
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

if grep -Eq '^[[:space:]]*sleep[[:space:]]' "$ROOT_DIR/scripts/ci/run-and-capture.sh"; then
  echo "FAIL: capture cancellation must not use fixed sleep polling"
  exit 1
fi
if ! grep -Fq 'proc.wait(timeout=5)' "$ROOT_DIR/scripts/ci/run-and-capture.sh"; then
  echo "FAIL: capture cancellation must use the owned bounded process wait"
  exit 1
fi

set +e
SECONDS=0
/bin/bash "$ROOT_DIR/scripts/ci/run-and-capture.sh" "$TMP_DIR/capture.log" \
  /bin/bash -c '
    echo "command-started"
    sleep 60 >>"$1" 2>&1 &
    echo $! >"$2"
    echo "detached-child=$!"
    exit 7
  ' _ "$TMP_DIR/capture.log" "$TMP_DIR/child.pid" \
  >"$TMP_DIR/streamed.log" 2>&1
status=$?
elapsed=$SECONDS
set -e

if [ "$status" -ne 7 ]; then
  cat "$TMP_DIR/streamed.log"
  echo "FAIL: capture wrapper changed command status to $status"
  exit 1
fi
if [ "$elapsed" -ge 5 ]; then
  cat "$TMP_DIR/streamed.log"
  echo "FAIL: detached child held the capture wrapper open for ${elapsed}s"
  exit 1
fi
if ! grep -Fq "command-started" "$TMP_DIR/capture.log" \
  || ! grep -Fq "detached-child=" "$TMP_DIR/capture.log"; then
  cat "$TMP_DIR/capture.log"
  echo "FAIL: capture file did not retain command output"
  exit 1
fi
if ! kill -0 "$(cat "$TMP_DIR/child.pid")" 2>/dev/null; then
  echo "FAIL: detached child did not survive long enough to prove pipe independence"
  exit 1
fi

# The live stream must contain every byte the command produced before exit,
# including a final burst that can land between tail polling intervals.
{
  for i in $(seq 1 200); do
    printf 'line-%03d\n' "$i"
  done
  printf 'final-marker-without-sleep\n'
} >"$TMP_DIR/expected.log"
/bin/bash "$ROOT_DIR/scripts/ci/run-and-capture.sh" "$TMP_DIR/exact-capture.log" \
  /bin/cat "$TMP_DIR/expected.log" >"$TMP_DIR/exact-streamed.log" 2>&1
if ! cmp -s "$TMP_DIR/expected.log" "$TMP_DIR/exact-capture.log"; then
  echo "FAIL: authoritative capture differs from command output"
  exit 1
fi
if ! cmp -s "$TMP_DIR/expected.log" "$TMP_DIR/exact-streamed.log"; then
  diff -u "$TMP_DIR/expected.log" "$TMP_DIR/exact-streamed.log" || true
  echo "FAIL: live stream omitted or duplicated final command output"
  exit 1
fi

# Cancellation must interrupt the owned command tree as well as the capture
# wrapper. GitHub sends TERM during job cancellation; swallowing it here would
# leave a long-running xcodebuild alive until its own timeout.
cancel_dir="$TMP_DIR/cancel"
mkdir -p "$cancel_dir"
SECONDS=0
/bin/bash "$ROOT_DIR/scripts/ci/run-and-capture.sh" "$cancel_dir/capture.log" \
  /bin/bash -c '
    trap "echo term-forwarded >\"$1/term\"; exit 42" TERM
    echo $$ >"$1/command.pid"
    sleep 60 &
    echo $! >"$1/grandchild.pid"
    wait
  ' _ "$cancel_dir" \
  >"$cancel_dir/streamed.log" 2>&1 &
capture_pid=$!

ready=0
for _ in $(seq 1 100); do
  if [ -s "$cancel_dir/command.pid" ] && [ -s "$cancel_dir/grandchild.pid" ]; then
    ready=1
    break
  fi
  sleep 0.05
done
if [ "$ready" -ne 1 ]; then
  cat "$cancel_dir/streamed.log" 2>/dev/null || true
  echo "FAIL: cancellation fixture did not start"
  exit 1
fi

kill -TERM "$capture_pid"
set +e
wait "$capture_pid"
cancel_status=$?
set -e
cancel_elapsed=$SECONDS

if [ "$cancel_status" -ne 143 ]; then
  cat "$cancel_dir/streamed.log"
  echo "FAIL: TERM must make capture exit 143, got $cancel_status"
  exit 1
fi
if [ "$cancel_elapsed" -ge 8 ]; then
  cat "$cancel_dir/streamed.log"
  echo "FAIL: TERM took ${cancel_elapsed}s to stop the capture command group"
  exit 1
fi
if [ ! -f "$cancel_dir/term" ]; then
  cat "$cancel_dir/streamed.log"
  echo "FAIL: TERM was not forwarded to the captured command"
  exit 1
fi

command_pid="$(cat "$cancel_dir/command.pid")"
grandchild_pid="$(cat "$cancel_dir/grandchild.pid")"
for _ in $(seq 1 40); do
  if ! kill -0 "$command_pid" 2>/dev/null \
    && ! kill -0 "$grandchild_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if kill -0 "$command_pid" 2>/dev/null || kill -0 "$grandchild_pid" 2>/dev/null; then
  ps -o pid,ppid,pgid,stat,command -p "$command_pid","$grandchild_pid" 2>/dev/null || true
  echo "FAIL: cancellation left the captured command group alive"
  exit 1
fi

# Hold Popen after the child starts, before the supervisor can return from it.
# Cancellation in this window must reach the child once its handle is known.
startup_dir="$TMP_DIR/startup"
mkdir -p "$startup_dir"
mkfifo "$startup_dir/resume"
exec 9<>"$startup_dir/resume"
startup_fifo_open=1
cat >"$startup_dir/sitecustomize.py" <<'PY'
import os
import pathlib
import subprocess

original_popen = subprocess.Popen

def pause_after_spawn(*args, **kwargs):
    child = original_popen(*args, **kwargs)
    directory = pathlib.Path(os.environ["CMUX_CAPTURE_STARTUP_DIR"])
    (directory / "child.pid").write_text(str(child.pid))
    (directory / "supervisor.pid").write_text(str(os.getpid()))
    with (directory / "resume").open("rb", buffering=0) as resume:
        resume.read(1)
    return child

subprocess.Popen = pause_after_spawn
PY
PYTHONPATH="$startup_dir" CMUX_CAPTURE_STARTUP_DIR="$startup_dir" \
  /bin/bash "$ROOT_DIR/scripts/ci/run-and-capture.sh" "$startup_dir/capture.log" \
    /bin/bash -c '
      trap "echo term-forwarded >\"$1/term\"; exit 42" TERM
      sleep 60 &
      echo ready >"$1/ready"
      wait
    ' _ "$startup_dir" >"$startup_dir/streamed.log" 2>&1 &
startup_capture_pid=$!
ready=0
for _ in $(seq 1 100); do
  if [ -s "$startup_dir/supervisor.pid" ] && [ -s "$startup_dir/ready" ]; then
    ready=1
    break
  fi
  sleep 0.05
done
if [ "$ready" -ne 1 ]; then
  cat "$startup_dir/streamed.log"
  echo "FAIL: startup cancellation fixture did not start"
  exit 1
fi
kill -TERM "$(cat "$startup_dir/supervisor.pid")"
printf x >&9
set +e
wait "$startup_capture_pid"
startup_status=$?
set -e
startup_capture_pid=""
exec 9>&-
startup_fifo_open=0
if [ "$startup_status" -ne 143 ] || [ ! -f "$startup_dir/term" ]; then
  cat "$startup_dir/streamed.log"
  echo "FAIL: cancellation during supervisor startup did not reach the command (status $startup_status)"
  exit 1
fi

echo "PASS: file-backed capture returns promptly, drains final output, and forwards cancellation"
