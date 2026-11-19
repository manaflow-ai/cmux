#!/bin/bash
# fanout.sh RUN_NAME HOST... [-- macos_bench.py run args]
#
# Runs one benchmark iteration on several Mac hosts at once, each with 2 VMs
# (Apple's license allows two macOS VMs per Mac), so N hosts finish about N
# times sooner. Every host gets the same golden VM (copied from the first host
# over the LAN when missing or older) and runs its shard of the tasks; both
# arms of a task always run on the same host. Results come back to
# runs/RUN_NAME/<host>/ here; `macos_bench.py report --out runs/RUN_NAME`
# merges them.
set -euo pipefail
run=$1; shift
hosts=(); while [[ $# -gt 0 && $1 != -- ]]; do hosts+=("$1"); shift; done
[[ ${1:-} == -- ]] && shift
here=$(cd "$(dirname "$0")" && pwd)
seed=${hosts[0]}
n=${#hosts[@]}
golden=${CUBENCH_GOLDEN:-cu-golden}
remote=cu-bench

stamp() { ssh "$1" "stat -f %m ~/.tart/vms/$golden/disk.img 2>/dev/null || echo 0"; }
seed_stamp=$(stamp "$seed")
[[ $seed_stamp != 0 ]] || { echo "fanout: $seed has no golden VM $golden" >&2; exit 1; }

pids=()
for i in "${!hosts[@]}"; do
  h=${hosts[$i]}
  (
    set -e
    ssh "$h" "mkdir -p ~/$remote/runs ~/$remote/bin"
    rsync -a "$here/" "$h:$remote/public/"
    if [[ $h != "$seed" && $(stamp "$h") -lt $seed_stamp ]]; then
      # Host to host over the LAN, not through this laptop.
      # The minis need SSH trust between them for this; without it, set
      # CUBENCH_RELAY=1 to copy through this machine (slower).
      target="$(ssh -G "$h" | awk '/^user /{u=$2} /^hostname /{n=$2} END{print u "@" n}')"
      if [[ ${CUBENCH_RELAY:-0} == 1 ]]; then
        rsync -a --sparse "$seed:.tart/vms/$golden/" "/tmp/fanout-$golden/" && rsync -a --sparse "/tmp/fanout-$golden/" "$h:.tart/vms/$golden/"
        rsync -a "$seed:$remote/bin" "$seed:$remote/assets" "$seed:$remote/MacAgentBench" "$seed:$remote/macosworld" "/tmp/fanout-assets/" && rsync -a "/tmp/fanout-assets/" "$h:$remote/"
        ssh "$h" "cd ~/$remote && /opt/homebrew/bin/python3 -m venv venv && venv/bin/pip -q install paramiko pyyaml requests beautifulsoup4 python-dateutil pytz numpy"
      else
        ssh "$seed" "rsync -a --sparse ~/.tart/vms/$golden/ $target:.tart/vms/$golden/ && rsync -a ~/$remote/bin ~/$remote/assets ~/$remote/MacAgentBench ~/$remote/macosworld ~/$remote/venv $target:$remote/"
      fi || { echo "fanout: copy to $h failed" >&2; exit 1; }
    fi
    ssh "$h" "cd ~/$remote/public && ~/$remote/venv/bin/python -u macos_bench.py run --shard $i/$n --out ~/$remote/runs/$run $*" \
      > "/tmp/fanout-$run-$h.log" 2>&1
  ) &
  pids+=($!)
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
mkdir -p "$here/runs/$run"
for h in "${hosts[@]}"; do rsync -a "$h:$remote/runs/$run/" "$here/runs/$run/$h/" || rc=1; done
python3 "$here/macos_bench.py" report --out "$here/runs/$run"
exit $rc
