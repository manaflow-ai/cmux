#!/usr/bin/env bash
# Austin's day: the P-AUSTIN load scenario on an exclusive fleet capture mini (README.md).
#
#   austins-day.sh --build JOB|SHA [--out DIR] [-- driver.py args]
#   austins-day.sh --base JOB|SHA --head JOB|SHA [--runs 5] [--out DIR] [-- driver.py args]
#   austins-day.sh --aa JOB|SHA [--runs 5] [--out DIR]       (A/A self-test: the same build in both arms)
#
# JOB is a done `cmux-ci build cmux` job; a 40-hex SHA names the newest done cmux build of that
# commit (`cmux-ci status --ref SHA`). Each run takes its own exclusive lease (capture-host acquire
# --slot --exclusive: no fleet step runs on the mini meanwhile), stages the build once per host,
# builds the pack fixture once per host (packs.py), launches the app in the slot, runs driver.py on
# the host for what the 10-minute lease leaves, quits the app (sessions ended), and releases the
# lease. With --base and --head the arms alternate (base, head, base, head, ...) on the host of the
# first run (--prefer), --runs times each. At the end summarize.py writes OUT/summary.json and
# OUT/summary.txt. Never run on a person's Mac; run from an agent VM or a workstation that reaches
# the capture minis (CAPTURE_HOST_HOSTS, see README.md).
set -euo pipefail
# The whole harness runs from a private copy made at the start (this script, driver.py, fake_claude.py,
# hog.py, packs.py, summarize.py, aa-failures.json, build_names.py and the acpmux test agent): an edit to
# the checkout during an A/B changes nothing in it, so every round runs the harness its arm.json names
# (the A/A of 2026-10-30 died when this file was edited mid-run; review of aa7c09ebaed, finding 2).
if [ -z "${AUSTINS_DAY_COPY:-}" ]; then
  src=$(cd "$(dirname "$0")" && pwd)
  src_repo=$(cd "$src/../../.." && pwd)
  # The harness commit (its tree must be clean: a result names the harness it came from).
  git -C "$src_repo" diff --quiet HEAD -- scripts/cmux-next/austins-day scripts/cmux-next/build_names.py \
    cmux-tui/crates/acpmux/tests/fake_agent.py || { echo "uncommitted harness edits: commit them first" >&2; exit 2; }
  copy=$(mktemp -d "${TMPDIR:-/tmp}/austins-day.XXXXXX")
  cp -p "$src"/*.py "$src"/*.sh "$src"/*.json "$src"/*.md "$copy"/ && cp -p "$src/../build_names.py" "$copy"/ &&
    cp -p "$src_repo/cmux-tui/crates/acpmux/tests/fake_agent.py" "$copy"/ || { rm -rf "$copy"; exit 2; }
  AUSTINS_DAY_COPY=$copy AUSTINS_DAY_REPO=$src_repo AUSTINS_DAY_SHA=$(git -C "$src_repo" rev-parse HEAD) \
    exec bash "$copy/austins-day.sh" "$@"
fi
here=$AUSTINS_DAY_COPY
# The copy is removed on every exit, from here on (usage errors and missing tools too).
remove_copy() { case "$here" in "${TMPDIR:-/tmp}"/austins-day.*) rm -rf "$here" ;; esac; }
trap remove_copy EXIT
repo=$AUSTINS_DAY_REPO
harness_sha=$AUSTINS_DAY_SHA
export AUSTINS_DAY_REPO
usage() { sed -n '2,16p' "$here/austins-day.sh" >&2; exit 2; }
build='' base='' head='' runs=5 out='' aa=0
while [ $# -gt 0 ]; do
  case "$1" in
    --build) build=${2:?}; shift 2 ;;
    --base) base=${2:?}; shift 2 ;;
    --aa) base=${2:?}; head=${2:?}; aa=1; shift 2 ;;
    --head) head=${2:?}; shift 2 ;;
    --runs) runs=${2:?}; shift 2 ;;
    --out) out=${2:?}; shift 2 ;;
    --) shift; break ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
driver_args=("$@")
# The lease bounds the driver: --seconds is set from what the lease leaves; never pass it.
for a in ${driver_args[@]+"${driver_args[@]}"}; do [ "$a" != "--seconds" ] || { echo "--seconds is set by the lease" >&2; exit 2; }; done
if [ -n "$build" ]; then [ -z "$base$head" ] || usage; elif [ -z "$base" ] || [ -z "$head" ]; then usage; fi
[[ $runs =~ ^[1-9][0-9]*$ ]] || usage
out=${out:-${TMPDIR:-/tmp}/austins-day-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$out"
# capture-host on PATH (the installed hq tools) and the ssh routes to the capture minis.
. "$repo/scripts/cmux-next/capture-host-env.sh"
command -v capture-host >/dev/null || { echo "capture-host not found (install the hq tools: cmux-ci capture)" >&2; exit 2; }
export CAPTURE_HOST_SLOT_HOSTS=${CAPTURE_HOST_SLOT_HOSTS:-${CAPTURE_HOST_HOSTS:-}}
export CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS=${CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS:-600}
lease_max=600
fixture=/Users/Shared/cmux-capture/austins-day/fixture-v1
stage_root=/Users/Shared/cmux-capture/austins-day/builds

# resolve JOB|SHA -> "JOB COMMIT"
resolve() {
  local query=("$1")
  [[ ! $1 =~ ^[0-9a-f]{40}$ ]] || query=(--ref "$1")
  cmux-ci status "${query[@]}" 2>/dev/null | python3 -I -c '
import json, sys
want = sys.argv[1]
data = json.load(sys.stdin)
jobs = data if isinstance(data, list) else [data]
jobs = [j for j in jobs if j.get("kind") == "cmux" and j.get("state") == "done" and len(j.get("ref", "")) == 40]
jobs.sort(key=lambda j: j.get("updated_at", ""), reverse=True)
if not jobs:
    sys.exit(f"no done cmux build for {want}: submit one with cmux-ci build cmux --ref SHA --tag TAG --backend-mode local --workspace KEY")
print(jobs[0]["id"], jobs[0]["ref"])' "$1"
}

preferred_host=
current_lease=
# A killed or failed script releases the lease it holds and removes its private copy.
current_acquire=
current_run=
current_host=
on_exit() {
  # A waiting lease request of ours is stopped (only while bash still has it as a running job: never a
  # reaped pid), the lease is released, and the remote run folder is removed.
  if [ -n "$current_acquire" ] && jobs -pr | grep -qx "$current_acquire"; then kill "$current_acquire" 2>/dev/null || true; fi
  if [ -n "$current_host" ] && [ -n "$current_run" ]; then ssh -o BatchMode=yes "$current_host" "rm -rf '$current_run'" >/dev/null 2>&1 || true; fi
  if [ -n "$current_lease" ]; then capture-host release "$current_lease" >/dev/null 2>&1 || true; fi
  remove_copy
}
trap on_exit EXIT
trap 'exit 130' INT TERM HUP
# run_arm ARM JOB COMMIT ROUND DIR POSITION (1: the round's first run, 2: its second)
run_arm() {
  local arm=$1 job=$2 commit=$3 round=$4 dir=$5 position=${6:-1}
  mkdir -p "$dir"
  local acquired lease_pid lease="" host="" slot="" run=""
  acquired=$(date +%s)
  local prefer=()
  [ -z "$preferred_host" ] || prefer=(--prefer "$preferred_host")
  capture-host acquire --slot --exclusive ${prefer[@]+"${prefer[@]}"} >"$dir/lease.txt" 2>"$dir/lease.err" &
  lease_pid=$!
  current_acquire=$lease_pid
  # shellcheck disable=SC2317
  # Runs when run_arm returns (bash keeps a function's RETURN trap after it; the variables it reads are
  # this call's locals, so a later return of another function finds them empty and does nothing).
  cleanup() {
    [ -n "${lease_pid:-}" ] || return 0  # another function's return: nothing of a run to clean
    if [ -n "$host" ] && [ -n "$run" ]; then ssh -o BatchMode=yes "$host" "rm -rf '$run'" >/dev/null 2>&1 || true; fi
    if [ -n "$lease" ]; then capture-host release "$lease" >/dev/null 2>&1 || true; fi
    # Only a still-running acquire of ours (in bash's job table: its pid is not yet reaped, so not reused).
    if jobs -pr | grep -qx "$lease_pid"; then kill "$lease_pid" 2>/dev/null || true; fi
    current_lease= current_acquire= current_run= current_host=
  }
  trap cleanup RETURN
  for _ in $(seq 1 400); do
    lease=$(grep -o 'slot-[A-Za-z0-9._-]*' "$dir/lease.txt" 2>/dev/null | head -1 || true)
    [ -n "$lease" ] && capture-host slot-info "$lease" >/dev/null 2>&1 && break
    kill -0 "$lease_pid" 2>/dev/null || { cat "$dir/lease.err" >&2; return 1; }
    sleep 2
  done
  [ -n "$lease" ] || { echo "no lease" >&2; return 1; }
  current_lease=$lease
  acquired=$(date +%s)  # the lease's 10 minutes start now
  local info
  info=$(capture-host slot-info "$lease")
  host=$(sed -n 's/.*host=\([^ ]*\).*/\1/p' <<<"$info")
  slot=$(sed -n 's/.*slot=\([^ ]*\).*/\1/p' <<<"$info")
  preferred_host=${preferred_host:-$host}
  echo "[$arm round $round] lease $lease host $host slot $slot (job $job, $commit)"
  printf '{"arm": "%s", "sha": "%s", "job": "%s", "round": %s, "position": %s, "host": "%s", "lease": "%s", "harness": "%s"}\n' \
    "$arm" "$commit" "$job" "$round" "$position" "$host" "$lease" "$harness_sha" >"$dir/arm.json"
  ssh -o BatchMode=yes "$host" "uptime; sysctl -n vm.swapusage kern.memorystatus_level hw.memsize" >"$dir/host-before.txt" 2>&1 || true
  local stage=$stage_root/$job
  run=/Users/Shared/cmux-capture/austins-day/runs/$arm-$round-$(date +%H%M%S)
  current_run=$run current_host=$host
  ssh -o BatchMode=yes "$host" "export PATH=\$HOME/.local/bin:\$PATH; set -e; mkdir -p '$stage' '$run/out'
    if ! find '$stage' -maxdepth 1 -name '*.app' | grep -q .; then
      tmp=\$(mktemp -d '$stage/unzip.XXXXXX') && cmux-ci artifact '$job' \"\$tmp/app.zip\" >/dev/null && ditto -x -k \"\$tmp/app.zip\" \"\$tmp\" &&
      for a in \"\$tmp\"/*.app; do mv \"\$a\" '$stage/'; done; rm -rf \"\$tmp\"
    fi
    echo '$commit' > '$stage/capture-commit'" || { echo "staging job $job on $host failed" >&2; return 1; }
  scp -q "$here/driver.py" "$here/fake_claude.py" "$here/hog.py" "$here/packs.py" "$here/build_names.py" \
    "$here/fake_agent.py" "$host:$run/" || { echo "copy to $host failed" >&2; return 1; }
  ssh -o BatchMode=yes "$host" "nice -n 5 python3 -I '$run/packs.py' build '$fixture'" | tee "$dir/fixture.txt"
  # set -e does not act inside run_arm (it is called in && and ||): each step that must work says so.
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "fixture build failed on $host" >&2; return 1; }
  local app name
  app=$(ssh -o BatchMode=yes "$host" "ls -d '$stage'/*.app | head -1")
  name=$(basename "$app" .app)
  [ -n "$app" ] || { echo "no staged app for job $job on $host" >&2; return 1; }
  capture-host launch --commit "$commit" "$lease" "$app" ad -- | tee "$dir/launch.txt"
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "the app did not launch in $lease" >&2; return 1; }
  local printed clone keyed sock=""
  printed=$(grep -o 'socket=[^ ]*' "$dir/launch.txt" | head -1 | cut -d= -f2- || true)
  clone=$(sed -n 's/.* app=\(.*\.app\)$/\1/p' "$dir/launch.txt" | head -1)
  keyed=
  [ -z "$clone" ] || keyed=$(ssh -o BatchMode=yes "$host" "python3 -I '$run/build_names.py' socket '$clone'" 2>/dev/null || true)
  for _ in $(seq 1 60); do
    for candidate in $keyed "/tmp/cmux-debug-${name#cmux DEV }-capslot$slot.sock" $printed; do
      if ssh -o BatchMode=yes "$host" "python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(2); s.connect(sys.argv[1])' '$candidate'" 2>/dev/null; then
        sock=$candidate; break 2
      fi
    done
    sleep 1
  done
  [ -n "$sock" ] || { echo "the app never opened its control socket" >&2; return 1; }
  # What the lease leaves: setup (~60 s for the terminals), the baseline, the end (~60 s for
  # stats, hangs and the log), and 40 s to quit and release.
  local left seconds
  left=$((lease_max - ($(date +%s) - acquired) - 40))
  seconds=$((left - 150))
  [ "$seconds" -ge 90 ] || { echo "only ${left}s left on the lease; not starting the load" >&2; return 1; }
  echo "[$arm round $round] load phase ${seconds}s"
  set +e
  local extra=
  [ ${#driver_args[@]} -eq 0 ] || extra=$(printf '%q ' "${driver_args[@]}")
  ssh -o BatchMode=yes "$host" "cd '$run' && python3 -I driver.py --socket '$sock' --app '${clone:-$app}' \
    --fixture '$fixture' --out '$run/out' --seconds $seconds --label '$arm-$round' $extra" 2>&1 | tee "$dir/driver.txt"
  local status=${PIPESTATUS[0]}
  set -e
  scp -q -r "$host:$run/out/." "$dir/" || true
  rm -rf "$dir/fakebin"
  ssh -o BatchMode=yes "$host" "uptime; sysctl -n vm.swapusage kern.memorystatus_level" >"$dir/host-after.txt" 2>&1 || true
  # Quit through the app's own action, ending its sessions (the agents end with their terminals).
  ssh -o BatchMode=yes "$host" "python3 -c 'import json,socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(sys.argv[1]); s.sendall((json.dumps({\"id\":1,\"method\":\"action.run\",\"params\":{\"action\":\"quitEndSessions\"}})+chr(10)).encode()); print(s.recv(4096)[:200])' '$sock'" || true
  ssh -o BatchMode=yes "$host" "rm -rf '$run'" || true
  echo "[$arm round $round] done (driver exit $status), results in $dir"
  return 0
}

dirs=()
if [ -n "$build" ]; then
  read -r job commit < <(resolve "$build")
  run_arm run "$job" "$commit" 1 "$out/run-1" && dirs+=("$out/run-1")
else
  read -r base_job base_commit < <(resolve "$base")
  read -r head_job head_commit < <(resolve "$head")
  for round in $(seq 1 "$runs"); do
    # ABBA: odd rounds run the base first, even rounds the head first, so a warm-up or drift effect of the
    # run position cancels out of the arm difference (and summarize.py estimates it apart).
    # A run that got no lease or no app is tried once more (a round needs both arms to count).
    order="base head"; [ $((round % 2)) = 1 ] || order="head base"
    position=0
    for arm in $order; do
      position=$((position + 1))
      if [ $arm = base ]; then j=$base_job c=$base_commit; else j=$head_job c=$head_commit; fi
      if run_arm $arm "$j" "$c" "$round" "$out/$arm-$round" $position || { rm -rf "$out/$arm-$round"; echo "$arm round $round: retry" >&2;
         run_arm $arm "$j" "$c" "$round" "$out/$arm-$round" $position; }; then
        dirs+=("$out/$arm-$round")
      else
        echo "$arm round $round failed" >&2
      fi
    done
  done
fi
[ ${#dirs[@]} -gt 0 ] || { echo "no run finished" >&2; exit 1; }
# summarize.py checks that the head does not change the harness (git diff base head): both commits must be here.
if [ -z "$build" ]; then git -C "$repo" fetch -q origin "$base_commit" "$head_commit" 2>/dev/null || true; fi
if [ "$aa" = 1 ]; then
  python3 -I "$here/summarize.py" --aa "$out/summary.json" "${dirs[@]}"
else
  python3 -I "$here/summarize.py" "$out/summary.json" "${dirs[@]}"
fi
echo "summary: $out/summary.json $out/summary.txt"
