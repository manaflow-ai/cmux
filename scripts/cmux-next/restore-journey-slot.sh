#!/usr/bin/env bash
# Run scripts/cmux-next/restore-journey.py on a fleet capture slot against a fleet DEV build.
#
#   scripts/cmux-next/restore-journey-slot.sh JOB [--update-to JOB_B] [OUT_DIR] [-- restore-journey args...]
#
# --update-to JOB_B: a relaunch after an update to another build. JOB_B (a done `cmux-ci build cmux`
# job, its commit from the controller or RJ_UPDATE_COMMIT) is staged beside JOB, and the journey's
# update variant installs it in place of the slot's copy of JOB before it relaunches
# (restore-journey.py --update-to, rj_update.py): the state seeded on JOB must come back on JOB_B.
#   scripts/cmux-next/restore-journey-slot.sh JOB_A --update-to JOB_B OUT -- --variants update
# JOB is a done `cmux-ci build cmux` job. The build is staged once per host under
# /Users/Shared/cmux-capture/restore-journey/<JOB> (outside the lease root, so a re-acquire only
# relaunches), launched in the slot with `capture-host launch`, and the journey runs on the host
# against the slot's socket. The journey's own relaunches reuse the app's launch environment. At
# the end the app quits through its quit action (sessions kept) and the lease is released, which
# stops every process of the slot by exact PID. A lease lasts at most 10 minutes; the journey
# takes about 4. Results land in OUT_DIR (default /tmp/restore-journey-<JOB>-<time>).
# Pin a host with CAPTURE_HOST_SLOT_HOSTS (one with free disk; see `capture-host status`).
# The lease is exclusive (`capture-host acquire --slot --exclusive`): the fleet controller places no
# step on the mini and no other capture shares it, so its timings are evidence. A run beside other
# agents' steps (a 1-minute load of 14-24, 2026-10-29) is not. Acquire first waits up to
# CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS (300) for the steps already running there.
set -euo pipefail
job=${1:?usage: restore-journey-slot.sh JOB [OUT_DIR] [-- args]}
shift
[[ $job =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad JOB: $job" >&2; exit 2; }
update_job=
if [ "${1:-}" = "--update-to" ]; then
  update_job=${2:?--update-to needs JOB_B}
  shift 2
  [[ $update_job =~ ^[A-Za-z0-9._-]+$ ]] && [ "$update_job" != "$job" ] || { echo "bad --update-to JOB_B: $update_job" >&2; exit 2; }
fi
out=/tmp/restore-journey-$job-$(date +%H%M%S)
if [ "${1:-}" = "--" ]; then
  shift
elif [ $# -gt 0 ]; then
  out=$1
  shift
  if [ "${1:-}" = "--" ]; then shift; fi
fi
# No args: nothing (printf '%q ' with no arguments prints '' and passed restore-journey.py an empty argument).
args=
[ $# -eq 0 ] || args=$(printf '%q ' "$@")
here=$(cd "$(dirname "$0")" && pwd)
# capture-host and the ssh routes to the capture minis (capture-host-env.sh).
. "$here/capture-host-env.sh"
mkdir -p "$out"
stage=/Users/Shared/cmux-capture/restore-journey/$job
run=$stage/run-$(date +%H%M%S)

# RJ_DRIVER: another driver in this checkout that takes restore-journey.py's slot arguments (--max-seconds,
# --socket, --out, --fake-agent, --src), such as scripts/fuzz/restore/restore_fuzz.py; RJ_DRIVER_FILES: files it
# needs beside it (space-separated, in this checkout).
driver=${RJ_DRIVER:-$here/restore-journey.py}
root=$(cd "$here/../.." && pwd -P)
for f in "$driver" ${RJ_DRIVER_FILES:-}; do  # checked before the lease, so a typo costs no lease
  case "$(cd "$(dirname "$f")" && pwd -P)/" in "$root"/*) [ -f "$f" ] || { echo "no file $f" >&2; exit 2; } ;; *) echo "RJ_DRIVER files must be in this checkout: $f" >&2; exit 2 ;; esac
done
# Room for the exclusive drain: acquire's deadline bounds it (120 s by default; a step on the mini may run 5).
export CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS="${CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS:-600}"
capture-host acquire --slot --exclusive >"$out/lease.txt" 2>"$out/lease.err" &
lease_pid=$!
release() {
  if [ -n "${host:-}" ]; then ssh -o BatchMode=yes "$host" "rm -rf '$run'" >/dev/null 2>&1 || true; fi
  # Stop acquire (it ends the reservation of a lease it has not granted), then release a lease it printed
  # that this script had not read yet: a stop between the print and the read held the mini for the lease.
  kill "$lease_pid" 2>/dev/null || true
  for _ in $(seq 1 50); do kill -0 "$lease_pid" 2>/dev/null || break; sleep 0.2; done
  [ -n "${lease:-}" ] || lease=$(grep -o 'slot-[A-Za-z0-9._-]*' "$out/lease.txt" 2>/dev/null | head -1 || true)
  if [ -n "${lease:-}" ]; then capture-host release "$lease" >/dev/null 2>&1 || true; fi
}
trap release EXIT
# Until acquire prints a lease or exits: it bounds itself (its timeout, plus an exclusive drain of up to
# CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS per busy host), so a fixed wait here would stop it mid-drain.
lease=
while :; do
  lease=$(grep -o 'slot-[A-Za-z0-9._-]*' "$out/lease.txt" 2>/dev/null | head -1 || true)
  [ -n "$lease" ] && capture-host slot-info "$lease" >/dev/null 2>&1 && break
  if ! kill -0 "$lease_pid" 2>/dev/null; then
    # It may have printed the lease just before it exited.
    lease=$(grep -o 'slot-[A-Za-z0-9._-]*' "$out/lease.txt" 2>/dev/null | head -1 || true)
    [ -n "$lease" ] && break
    echo "no exclusive capture slot: $(tail -3 "$out/lease.err" 2>/dev/null)" >&2
    exit 1
  fi
  sleep 2
done
# The lease's 10 minutes start when it is granted, after the exclusive drain.
acquired=$(date +%s)
info=$(capture-host slot-info "$lease")
host=$(sed -n 's/.*host=\([^ ]*\).*/\1/p' <<<"$info")
slot=$(sed -n 's/.*slot=\([^ ]*\).*/\1/p' <<<"$info")
echo "lease $lease host $host slot $slot"

# capture-host launches only the build it is told (--commit, checked against the bundle): the
# job's commit, or RJ_COMMIT for a job the controller no longer lists.
job_commit() { cmux-ci status "$1" 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("ref", ""))' 2>/dev/null || true; }
commit=${RJ_COMMIT:-$(job_commit "$job")}
[[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo "no 40-hex commit for job $job (set RJ_COMMIT)" >&2; exit 2; }
# stage_build JOB DIR COMMIT: the job's app unzipped once into DIR on the host, its commit beside it.
stage_build() {
  ssh -o BatchMode=yes "$host" "export PATH=\$HOME/.local/bin:\$PATH; set -e; mkdir -p '$2' '$run'
  if ! find '$2' -maxdepth 1 -name '*.app' | grep -q .; then
    tmp=\$(mktemp -d '$2/unzip.XXXXXX') && cmux-ci artifact '$1' \"\$tmp/app.zip\" >/dev/null && ditto -x -k \"\$tmp/app.zip\" \"\$tmp\" &&
    for a in \"\$tmp\"/*.app; do mv \"\$a\" '$2/'; done; rm -rf \"\$tmp\"
  fi
  # The commit the staged build was made from, beside it, for capture-host's launch check.
  echo '$3' > '$2/capture-commit'"
}
stage_build "$job" "$stage" "$commit"
update_args=
if [ -n "$update_job" ]; then
  update_commit=${RJ_UPDATE_COMMIT:-$(job_commit "$update_job")}
  [[ $update_commit =~ ^[0-9a-f]{40}$ ]] || { echo "no 40-hex commit for job $update_job (set RJ_UPDATE_COMMIT)" >&2; exit 2; }
  update_stage=/Users/Shared/cmux-capture/restore-journey/$update_job
  stage_build "$update_job" "$update_stage" "$update_commit"
  update_app=$(ssh -o BatchMode=yes "$host" "ls -d '$update_stage'/*.app | head -1")
  [ -n "$update_app" ] || { echo "job $update_job staged no app" >&2; exit 1; }
  update_args="--update-to $(printf '%q' "$update_app")"
  echo "update: $commit -> $update_commit ($update_app)"
fi
scp -q "$driver" ${RJ_DRIVER_FILES:-} "$here/restore-journey.py" "$here/build_names.py" "$here/rj_rows.py" "$here/rj_update.py" "$here/rj_fake_cli_agent.py" "$here/../../cmux-tui/crates/acpmux/tests/fake_agent.py" "$host:$run/"
app=$(ssh -o BatchMode=yes "$host" "ls -d '$stage'/*.app | head -1")
name=$(basename "$app" .app)
build_tag=${name#cmux DEV }
capture-host launch --commit "$commit" "$lease" "$app" rj -- | tee "$out/launch.txt"
# The app's control socket: the build's own (build_names.py: a slot clone, whose bundle id does
# not end in its tag, gets cmux-debug--<key hash>.sock in ~/.local/state/cmux, then its /tmp
# link); before per-build isolation it was
# named from the build tag; capture-host also prints the one it set.
printed=$(grep -o 'socket=[^ ]*' "$out/launch.txt" | head -1 | cut -d= -f2- || true)
clone=$(sed -n 's/.* app=\(.*\.app\)$/\1/p' "$out/launch.txt" | head -1)
keyed=
if [ -n "$clone" ]; then
  keyed=$(ssh -o BatchMode=yes "$host" "python3 -I '$run/build_names.py' socket '$clone'" 2>/dev/null || true)
fi
sock=
for _ in $(seq 1 60); do
  for candidate in $keyed "/tmp/cmux-debug-$build_tag-capslot$slot.sock" $printed; do
    # A socket that accepts a connection (an earlier lease can leave a dead socket file behind).
    if ssh -o BatchMode=yes "$host" "python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(2); s.connect(sys.argv[1])' '$candidate'" 2>/dev/null; then
      sock=$candidate; break 2
    fi
  done
  sleep 1
done
up=$sock
[ -n "$up" ] || { echo "the app never opened its control socket" >&2; exit 1; }

set +e
# Bounded by the lease (10 minutes from acquire, less a margin to quit): the journey must not outlive the slot.
left=$((600 - ($(date +%s) - acquired) - 40))
[ "$left" -gt 120 ] || { echo "only ${left}s left on the lease; not starting the journey" >&2; exit 1; }
ssh -o BatchMode=yes "$host" "cd '$run' && python3 $(printf '%q' "$(basename "$driver")") --max-seconds $left --socket '$sock' --out '$run/out' \
  --fake-agent '$run/fake_agent.py' --src '$app' $update_args $args" 2>&1 | tee "$out/journey.txt"
status=${PIPESTATUS[0]}
set -e
scp -q -r "$host:$run/out/." "$out/" || true
# Quit through the app's own action (sessions kept, as a person's quit); release stops the rest.
ssh -o BatchMode=yes "$host" "python3 -c 'import json,socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sys.argv[1]); s.sendall((json.dumps({\"id\":1,\"method\":\"action.run\",\"params\":{\"action\":\"quitKeepSessions\"}})+chr(10)).encode()); print(s.recv(4096)[:200])' '$sock'" || true
echo "results in $out (exit $status)"
exit "$status"
