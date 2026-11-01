#!/usr/bin/env bash
# Run one reviewed measurement on a quiet host, and record what else used the CPU (cmux-ad 2026-10-31: mds_stores ran
# at 370 % on a perf mini during benches, very likely after a job mounted a volume).
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/quiet-host.sh --ref SHA \
#     --arg=instant-new-surfaces.sh --arg=--commands=new_tab ...
# The first argument names the measurement (a file in scripts/measure/ from the INNER list below, so this wrapper never
# runs a script that has no review); every other argument goes to it unchanged. Before the measurement:
#   - `.metadata_never_index` in the step's checkout, its artifacts/ directory and $TMPDIR, so Spotlight skips them;
#   - a watcher (a child of this script, stopped when the measurement ends) writes `.metadata_never_index` at the root of
#     every volume mounted while the measurement runs and asks `mdutil -i off` for it (that needs root on most volumes;
#     a refusal is printed, never fatal);
#   - one CPU record: `QUIET-HOST-CPU before: name=pct ...` for mds_stores, mds, mdworker*, fleet-cas* and any process
#     over 5 % (`ps -A -o %cpu=,comm=`).
# After it: the same record as `QUIET-HOST-CPU after:`, the volumes the watcher saw (`QUIET-HOST-VOLUME ...`), then the
# measurement's own exit code. It signals only its own watcher.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# The measurements this wrapper may run: each is on the controller's measure list (hq build-fleet ci_step.go). The hq
# controller admits this wrapper only with a listed inner measurement, and the hq worker pins the inner script's bytes
# to the reviewed branches exactly as it pins this wrapper's (cmd/worker step_reviewed.go checkWrappedScripts).
INNER=(instant-new-surfaces.sh split-spring.sh perf-bench.sh perf-idle-power.sh tab-switch.sh palette-open.sh chat-open.sh)

if [ "$#" -lt 1 ]; then
  echo "usage: quiet-host.sh MEASUREMENT.sh [ARG...] (MEASUREMENT one of: ${INNER[*]})" >&2; exit 2
fi
inner="$1"; shift
ok=0
for name in "${INNER[@]}"; do [ "$inner" = "$name" ] && ok=1; done
if [ "$ok" != 1 ] || [ ! -f "scripts/measure/$inner" ]; then
  echo "quiet-host.sh: '$inner' is not a measurement this wrapper runs (one of: ${INNER[*]})" >&2; exit 2
fi
if [ -z "${CMUX_CI_STEP_KEY:-}" ] && [ "${QUIET_HOST_DRY_RUN:-}" != 1 ]; then
  echo "quiet-host.sh runs only on the build fleet (cmux-ci run); QUIET_HOST_DRY_RUN=1 checks the arguments" >&2; exit 2
fi

# cpu_record LABEL: one line of the processes that skew a measurement.
cpu_record() {
  ps -A -o %cpu=,comm= 2>/dev/null | awk -v label="$1" '
    { pct = $1 + 0; $1 = ""; sub(/^ +/, ""); n = split($0, parts, "/"); name = parts[n]
      if (name ~ /^(mds_stores|mds|mdworker.*|fleet-cas.*)$/ || pct > 5) { gsub(/ /, "_", name); line = line " " name "=" pct } }
    END { print "QUIET-HOST-CPU " label ":" (line == "" ? " none" : line) }'
}

mark() { [ -d "$1" ] && [ -w "$1" ] && : > "$1/.metadata_never_index" 2>/dev/null || true; }

mkdir -p artifacts
for dir in "$PWD" "$PWD/artifacts" "${TMPDIR:-/tmp}"; do mark "$dir"; done

seen="$(mktemp)"
# A mount line is "DEVICE on MOUNTPOINT (OPTIONS)"; the mount point can hold spaces.
mount_points() { mount | sed -E 's/^.* on (.*) \([^()]*\)$/\1/'; }
mount_points | sort > "$seen.base"
watch_volumes() {
  while :; do
    # grep finds nothing on most hosts: that must not end the watcher (set -e and pipefail hold in this subshell)
    { mount_points | grep -E '^/Volumes/|^/private/var/folders/' || true; } | sort | comm -13 "$seen.base" - |
      while IFS= read -r vol; do
        grep -qxF "$vol" "$seen" 2>/dev/null && continue
        echo "$vol" >> "$seen"
        mark "$vol"
        if mdutil -i off "$vol" >/dev/null 2>&1; then echo "QUIET-HOST-VOLUME $vol: indexing off"
        else echo "QUIET-HOST-VOLUME $vol: .metadata_never_index written; mdutil -i off refused (needs root)"; fi
      done
    sleep 5
  done
}
watch_volumes &
watcher=$!
cleanup() { kill "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true; rm -f "$seen" "$seen.base"; }
trap cleanup EXIT

cpu_record before || true
if [ "${QUIET_HOST_DRY_RUN:-}" = 1 ]; then
  echo "quiet-host.sh: dry run: would run scripts/measure/$inner $*"; status=0
else
  set +e; bash "scripts/measure/$inner" "$@"; status=$?; set -e
fi
cpu_record after || true  # never lose the measurement's exit code to a failed ps
echo "quiet-host.sh: scripts/measure/$inner exited $status"
exit "$status"
