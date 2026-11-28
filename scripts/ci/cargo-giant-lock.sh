#!/usr/bin/env bash
# rustc wrapper for scripts/ci/cargo-groups.sh (GIANTS_ONE_AT_A_TIME): cargo runs `RUSTC_WRAPPER rustc ARGS`.
# A crate named in CARGO_GROUPS_GIANTS (crate names, space separated) compiles only while it holds an flock on
# CARGO_GROUPS_GIANT_LOCK, so two giants never compile at once; every other crate runs at once as before.
# CARGO_GROUPS_INNER_WRAPPER, when set, is a wrapper the caller had in RUSTC_WRAPPER: it still runs.
set -uo pipefail

inner=()
[[ -n "${CARGO_GROUPS_INNER_WRAPPER:-}" ]] && inner=("$CARGO_GROUPS_INNER_WRAPPER")

crate="" prev=""
for a in "$@"; do
  [[ "$prev" == --crate-name ]] && { crate=$a; break; }
  prev=$a
done

if [[ -n "$crate" && -n "${CARGO_GROUPS_GIANT_LOCK:-}" && " ${CARGO_GROUPS_GIANTS:-} " == *" $crate "* ]]; then
  exec 9>>"$CARGO_GROUPS_GIANT_LOCK"
  start=$(date +%s)
  flock 9
  waited=$(($(date +%s) - start))
  ((waited < 1)) || echo "cargo groups: $crate waited ${waited} s for the other giant (GIANTS_ONE_AT_A_TIME)" >&2
  # Peak RSS: each giant's rustc runs as a child and the wrapper prints its peak resident memory and wall time, so
  # a leg says how much a giant holds (the 16 GiB CARGO_GROUPS_GIANT_GIB reserve and the thin legs' incremental-off
  # choice, cmux#65225, are both sized from that peak; no leg printed it). The child holds the lock fd (9), so
  # the lock is released when rustc exits, as before. Without python3 the wrapper execs rustc as it did.
  if command -v python3 >/dev/null; then
    exec python3 -c '
import os, resource, signal, subprocess, sys, time
crate, cmd = sys.argv[1], sys.argv[2:]
t = time.monotonic()
rc = subprocess.call(cmd, pass_fds=(9,))
peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss // 1024
print(f"cargo groups: {crate} rustc peak RSS {peak} MiB, {time.monotonic() - t:.0f} s (exit {rc})", file=sys.stderr)
if rc < 0:
    # Die by the same signal: cargo then reports "signal: 9, SIGKILL" and OOM_RERUN_ALONE still matches.
    if -rc not in (signal.SIGKILL, signal.SIGSTOP):
        signal.signal(-rc, signal.SIG_DFL)
    os.kill(os.getpid(), -rc)
sys.exit(rc)
' "$crate" ${inner[@]+"${inner[@]}"} "$@"
  fi
  # The lock is released when this process, the one rustc runs in, exits.
  exec ${inner[@]+"${inner[@]}"} "$@"
fi
exec ${inner[@]+"${inner[@]}"} "$@"
