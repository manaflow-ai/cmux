#!/usr/bin/env bash
# Memory of one iOS simulator per SimSlim variant, then N at once stock vs slim, on this host.
# The receipt for a SimSlim bump or a profile change (README.md "Bumping SimSlim"). Fleet only:
# it boots simulators, in a device set of its own that it deletes at the end.
#
#   CMUX_SIMSLIM_BIN=... scripts/ci/simslim/measure-matrix.sh OUT_DIR [SETTLE_SECONDS] [DENSITY_N]
#
# Each variant: a new iPhone, slimmed before its first boot (except stock), booted, left to
# settle (default 120 s, the figure SimSlim's README uses), then `simslim measure` and `simslim
# doctor` for the fleet's required features plus the variant's kept ones. Writes OUT_DIR/matrix.jsonl
# (one line per variant) and OUT_DIR/density.jsonl (N stock, then N slim, all booted at once).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../../cmux-next/lib/fleet-only.sh
source "$here/../../cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet measure-matrix.sh "iOS simulators" "none (a receipt rig)"

out=${1:?OUT_DIR}; settle=${2:-120}; density=${3:-5}
bin=${CMUX_SIMSLIM_BIN:?point CMUX_SIMSLIM_BIN at the pinned simslim}
mkdir -p "$out"
set_dir="$(mktemp -d "${TMPDIR:-/tmp}/simslim-matrix.XXXXXX")"
trap 'xcrun simctl --set "$set_dir" shutdown all >/dev/null 2>&1 || true; xcrun simctl --set "$set_dir" delete all >/dev/null 2>&1 || true; rm -rf "$set_dir"' EXIT
sim_choice="$(xcrun simctl list -j runtimes devicetypes | python3 -I "$here/../ios_sim_runtime.py")"
read -r runtime device_type <<< "$sim_choice"
ss() { "$bin" --set "$set_dir" "$@"; }

# name | CMUX_SIM_KEEP | extra doctor features (the kept categories' own)
variants=(
  "stock|-|spotlight,photos,icloud,siri,widgets"
  "simslim-default|-|"
  "fleet||"
  "fleet+photos|photos|photos"
  "fleet+search|search|spotlight,files-recents"
  "fleet+icloud|icloud|icloud,keychain-sync"
  "fleet+siri|siri|siri"
  "fleet+widgets|widgets|widgets"
  "fleet+photos,search,icloud|photos,search,icloud|photos,spotlight,icloud"
)
required=push,storekit,universal-links

# apply NAME KEEP UDID: slim UDID (shut down) for the variant; echo the seconds it took.
apply() {
  local name=$1 keep=$2 udid=$3 t0=$SECONDS
  case "$name" in
    stock) ;;
    simslim-default) ss on "$udid" --preserve-boot-state >/dev/null ;;
    *) python3 -I "$here/profile.py" "$here/fleet.json" "$keep" >"$set_dir/$udid.json"
       ss on "$udid" --preserve-boot-state --profile "$set_dir/$udid.json" >/dev/null ;;
  esac
  echo $((SECONDS - t0))
}

: >"$out/matrix.jsonl"
for v in "${variants[@]}"; do
  IFS='|' read -r name keep extra <<< "$v"
  udid="$(xcrun simctl --set "$set_dir" create "matrix-$name" "$device_type" "$runtime")"
  slim_s="$(apply "$name" "$keep" "$udid")"
  t0=$SECONDS
  xcrun simctl --set "$set_dir" boot "$udid"
  xcrun simctl --set "$set_dir" bootstatus "$udid" -b >/dev/null
  boot_s=$((SECONDS - t0))
  # A fixed settle, the measurement's own definition (not synchronization): SimSlim's numbers
  # are "same device and settle time".
  sleep "$settle"
  ss measure "$udid" --json >"$set_dir/m.json"
  features="$required${extra:+,$extra}"
  ss doctor "$udid" --requires "$features" --json >"$set_dir/d.json" || true
  python3 -I - "$name" "$keep" "$slim_s" "$boot_s" "$settle" "$set_dir/m.json" "$set_dir/d.json" >>"$out/matrix.jsonl" <<'PY'
import json, sys
name, keep, slim_s, boot_s, settle, m, d = sys.argv[1:]
measure = json.load(open(m)); doctor = json.load(open(d))
print(json.dumps({"variant": name, "keep": keep if keep != "-" else "", "slim_seconds": int(slim_s),
                  "boot_seconds": int(boot_s), "settle_seconds": int(settle), **measure,
                  "doctor": {f["id"]: f["ok"] for f in doctor.get("features", [])}}))
PY
  tail -n 1 "$out/matrix.jsonl"
  xcrun simctl --set "$set_dir" shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl --set "$set_dir" delete "$udid" >/dev/null
done

# Density: N simulators booted at once, stock then fleet; the sum of their footprints and the
# host's own memory figures with them up.
host_mem() {
  vm_stat | python3 -I -c '
import re, sys
t = sys.stdin.read(); page = int(re.search(r"page size of (\d+)", t).group(1))
g = lambda k: int(re.search(k + r":\s+(\d+)", t).group(1)) * page
print(g("Pages active") + g("Pages wired down") + g("Pages occupied by compressor"))'
}
: >"$out/density.jsonl"
for kind in stock fleet; do
  base_used="$(host_mem)"
  udids=()
  for i in $(seq 1 "$density"); do
    u="$(xcrun simctl --set "$set_dir" create "density-$kind-$i" "$device_type" "$runtime")"
    [[ "$kind" == fleet ]] && apply fleet "" "$u" >/dev/null
    udids+=("$u")
  done
  for u in "${udids[@]}"; do xcrun simctl --set "$set_dir" boot "$u"; done
  for u in "${udids[@]}"; do xcrun simctl --set "$set_dir" bootstatus "$u" -b >/dev/null; done
  sleep "$settle"
  total=0 procs=0
  for u in "${udids[@]}"; do
    read -r p b < <(ss measure "$u" --json | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d["processes"], d["bytes"])')
    total=$((total + b)); procs=$((procs + p))
  done
  used="$(host_mem)"
  printf '{"kind":"%s","n":%d,"processes":%d,"bytes":%d,"host_used_before":%d,"host_used_after":%d,"memory_pressure":"%s"}\n' \
    "$kind" "$density" "$procs" "$total" "$base_used" "$used" "$(memory_pressure | tail -1 | sed 's/.*: //')" | tee -a "$out/density.jsonl"
  for u in "${udids[@]}"; do xcrun simctl --set "$set_dir" shutdown "$u" >/dev/null 2>&1 || true; xcrun simctl --set "$set_dir" delete "$u" >/dev/null; done
done
