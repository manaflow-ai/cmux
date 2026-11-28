#!/usr/bin/env bash
# Run the cmux-tui tree's cargo invocations at the same time and gather their
# binaries into one target directory.
#
# usage: scripts/ci/cargo-groups.sh TARGET_DIR TRIPLE BINS COMMAND [BINS COMMAND ...]
#
# Each BINS COMMAND pair is one group. COMMAND is a bash command line (it may
# cd or set variables first); BINS names the binaries it makes, space separated,
# and a name starting with '?' is optional. Group 1 builds in TARGET_DIR; group
# N builds in TARGET_DIR/groups/N, and its binaries are copied to
# TARGET_DIR/TRIPLE/release afterwards, where the staging steps read them.
#
# Why: the published binaries each need their own cargo invocation, because
# building them together would unify features across packages and change what
# each binary links (cargo tree, 2026-10-20: every pair differs). Run one after
# another, the tail of each invocation (its fat-LTO link, one core) left the
# runner idle: a Linux leg took 20-46 min. One target directory admits one
# cargo at a time, hence a directory per group.
#
# Every group runs to the end. Its output is printed whole, in group order,
# with its time; the script fails when any group failed or a required binary
# is missing.
#
# Each group gets CARGO_BUILD_JOBS = ceil(2 * cores / groups) unless the caller
# set it: all groups at full -j would start cores x groups rustc processes and
# as many fat-LTO links at once, which can run a small runner out of memory.
# Group 1 gets every core instead. It is the longest group in every caller (the
# cmux-tui group), and builds alone for its last minutes after the others are
# done: on a 16 vCPU Linux musl leg the other groups ended after 17-296 s and
# group 1 after 358-461 s (runs 42653261844 to 42654596743, 2026-11-09), with
# its rustc and ThinLTO workers held to 7 jobserver tokens on 16 cores. Every
# core for group 1 adds cores - ceil(2 * cores / groups) tokens at the start
# (16 + 5 x 6 = 46 instead of 36 for the six groups of a Linux musl leg), and the
# extra ones all go to it once the short groups end. A caller's CARGO_BUILD_JOBS
# still applies to every group.
set -euo pipefail
set -o noglob # BINS entries like '?name' are names, not patterns

if (($# < 4 || ($# - 2) % 2 != 0)); then
  echo "usage: $0 TARGET_DIR TRIPLE BINS COMMAND [BINS COMMAND ...]" >&2
  exit 2
fi
target_dir=$1 triple=$2
shift 2
mkdir -p "$target_dir"
target_dir="$(cd "$target_dir" && pwd)"
logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT

bins=() commands=() dirs=() pids=() starts=() failed=() missing=() pending_reruns=() heavy_serial=""
while (($#)); do
  bins+=("$1") commands+=("$2")
  shift 2
done

grouped() { [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::$1::${2:-}" || true; }

# cgroup_mem_gib: the smallest memory.max (GiB) on this process's cgroup v2 path, or nothing when none is set.
# CARGO_GROUPS_CGROUP_ROOT moves /sys/fs/cgroup for tests.
cgroup_mem_gib() {
  local root="${CARGO_GROUPS_CGROUP_ROOT:-/sys/fs/cgroup}" rel p v min=""
  rel=$(awk -F: '$1 == "0" { print $3; exit }' "${CARGO_GROUPS_PROC_CGROUP:-/proc/self/cgroup}" 2>/dev/null) || return 0
  [[ -n "$rel" ]] || return 0
  p="$root${rel%/}"
  while :; do
    v=$(cat "$p/memory.max" 2>/dev/null) || v=""
    if [[ "$v" =~ ^[0-9]+$ ]] && { [[ -z "$min" ]] || ((v < min)); }; then min=$v; fi
    [[ "$p" == "$root" || "$p" != */* ]] && break
    p="${p%/*}"; [[ -n "$p" ]] || p=/
    [[ "$p" == "$root"* ]] || break
  done
  [[ -z "$min" ]] || echo $((min / 1073741824))
}

# meminfo_gib FIELD: /proc/meminfo's FIELD (MemTotal, MemAvailable) in GiB, or nothing off Linux.
# CARGO_GROUPS_MEMINFO moves /proc/meminfo for tests.
meminfo_gib() {
  awk -v f="$1:" '$1 == f { print int($2 / 1048576); exit }' "${CARGO_GROUPS_MEMINFO:-/proc/meminfo}" 2>/dev/null || true
}

# oom_kills: the kernel's OOM kill count (/proc/vmstat oom_kill, every cgroup on the host), or nothing off Linux.
# CARGO_GROUPS_VMSTAT moves /proc/vmstat for tests.
oom_kills() {
  awk '$1 == "oom_kill" { print $2; exit }' "${CARGO_GROUPS_VMSTAT:-/proc/vmstat}" 2>/dev/null || true
}

if [[ -z "${CARGO_BUILD_JOBS:-}" ]]; then
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
  # A runner whose memory is capped below its CPU count (a pool slot: every host thread visible, MemoryMax 24G)
  # counts one core per CARGO_GROUPS_GIB_PER_CORE (3) GiB of its cgroup's memory.max. The tokens below come to
  # about 3 x cores, and on a 96-thread host 96 + 9 x 20 of them in a 24 GiB slot had the kernel SIGKILL the
  # fat-LTO cmux-tui rustc (cmux-tui job 140826310692, 2026-11-28: groups 2 6 7 10 failed). A runner with no cap,
  # or with memory to spare (a 16 vCPU / 64 GiB VM), keeps every core.
  #
  # The budget is also the host's MemAvailable at the start, whichever is less: a GCE pool VM's slots had no
  # MemoryMax until hq#36694 (2026-11-28 11:58Z, at each runner unit's next start), and a slot shares the VM's RAM
  # with its sibling's job. Sized by cores alone, a cold fat-LTO aarch64 musl leg on cmux-runner-pool-w2a-0201
  # (16 threads, no memory.max) ran 16 + 6 x 5 = 46 jobserver tokens, two fat-LTO acpmux compiles among them, and
  # the kernel SIGKILLed the cmux-tui-core and acpmux rustc (cmux-tui-artifacts run 46139971718, job 140972969989,
  # 2026-11-28: groups 1 5 failed). MemAvailable counts what the sibling already holds; a sibling that starts later
  # reads ours the same way.
  mem_gib=$(cgroup_mem_gib) avail_gib=$(meminfo_gib MemAvailable) total_gib=$(meminfo_gib MemTotal)
  echo "cargo groups: memory: memory.max ${mem_gib:-none} GiB, MemTotal ${total_gib:-?} GiB, MemAvailable ${avail_gib:-?} GiB, ${cores} cores"
  budget=$mem_gib source="memory.max"
  if [[ -n "$avail_gib" ]] && { [[ -z "$budget" ]] || ((avail_gib < budget)); }; then
    budget=$avail_gib source="MemAvailable"
  fi
  capped="" max_par=0
  if [[ -n "$budget" ]]; then
    per=${CARGO_GROUPS_GIB_PER_CORE:-3}
    fit=$((budget / per)); ((fit >= 1)) || fit=1
    if ((fit < cores)); then
      echo "cargo groups: $source ${budget} GiB holds ${fit} of ${cores} cores at ${per} GiB each"
      cores=$fit capped=1
    fi
  fi
  groups=${#commands[@]}
  jobs=$(((2 * cores + groups - 1) / groups))
  ((jobs >= 1)) || jobs=1
  lead_jobs=$((cores > jobs ? cores : jobs))
  # Capped by memory, every group's tokens run at once, so their sum has to fit the budget, not each group's: the
  # split above hands out about 3 x cores tokens. In a 14 GiB pool slot (4 cores) it ran 4 + 4 x 2 = 12 rustc
  # and the kernel SIGKILLed the acpmux and cmux-tui-core rustc (cmux-machine-channel run 46144424122, job
  # 140980982077, cmux-runner-pool-w1c-0258, 2026-11-28), so no Cloud machine channel point for 62 min. The sum
  # is budget / CARGO_GROUPS_GIB_PER_TOKEN (2) tokens, at least one per group; a third (or more) goes to group 1.
  if [[ -n "$capped" ]]; then
    per_token=${CARGO_GROUPS_GIB_PER_TOKEN:-2}
    # One token per group is a floor, not a fit: the acpmux and cmux-tui-core rustc (release, one codegen unit, LTO
    # bitcode) hold more than one token's 2 GiB each, so seven one-token groups still had the kernel SIGKILL them in
    # a 14 GiB slot (cmux-tui artifacts run 46151055767 at 9be5a10bbb, which has #64759). Capped by memory, only
    # budget / CARGO_GROUPS_GIB_PER_GROUP (4) groups run at once; the rest start as one ends (group 1 first).
    per_group=${CARGO_GROUPS_GIB_PER_GROUP:-4}
    max_par=$((budget / per_group)); ((max_par >= 1)) || max_par=1; ((max_par <= groups)) || max_par=$groups
    total=$((budget / per_token)); ((total >= max_par)) || total=$max_par
    if ((max_par > 1)); then
      jobs=$(((total - (total + 2) / 3) / (max_par - 1))); ((jobs >= 1)) || jobs=1
      lead_jobs=$((total - jobs * (max_par - 1))); ((lead_jobs >= 1)) || lead_jobs=1
    else
      jobs=$total lead_jobs=$total
    fi
    echo "cargo groups: $source ${budget} GiB holds ${total} tokens across ${max_par} of ${groups} groups at once, ${per_token} GiB a token, ${per_group} GiB a group"
  fi
  # HEAVY_GROUPS_ONE_AT_A_TIME: CARGO_GROUPS_HEAVY names the groups (numbers, space separated) that compile a
  # release fat-LTO giant: the shipped musl legs' group 1 (cmux-tui, with acpmux and cmux-tui-core) and group 5
  # (acpmux-standalone, acpmux again with its own features). One such rustc holds far more than a token: group 5's
  # rerun, the acpmux lib its only unit, still lost it to the kernel under memory.max 14 GiB (cmux-tui-artifacts
  # runs 46161165035 and 46161772976, both musl legs, 2026-11-28, after #64863), and on an uncapped 30 GiB VM
  # groups 1 and 5 at once ended in a runner shutdown (run 46157448774 attempt 2). Unless the budget holds
  # CARGO_GROUPS_HEAVY_GIB (16) per heavy group, they run one after another; light groups start meanwhile.
  heavy_gib=${CARGO_GROUPS_HEAVY_GIB:-16} heavy_n=$(wc -w <<<"${CARGO_GROUPS_HEAVY:-}")
  if ((heavy_n > 1)) && [[ -n "$budget" ]] && ((budget < heavy_n * heavy_gib)); then
    heavy_serial=1
    echo "cargo groups: $source ${budget} GiB holds fewer than ${heavy_n} heavy groups (${CARGO_GROUPS_HEAVY}) at ${heavy_gib} GiB each: one at a time"
  fi
  export CARGO_BUILD_JOBS=$jobs
  echo "cargo groups: ${#commands[@]}, CARGO_BUILD_JOBS=$lead_jobs for group 1, $CARGO_BUILD_JOBS each for the others"
else
  lead_jobs=$CARGO_BUILD_JOBS
  echo "cargo groups: ${#commands[@]}, CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS each"
fi

# timings_summary REPORT START: the slowest units of a cargo --timings report
# written since START (epoch seconds), and the units that ended last. Prints
# nothing without a fresh report; a report it cannot read is one line, never a
# failure.
timings_summary() {
  [[ -f "$1" ]] || return 0
  python3 - "$1" "$2" <<'PY' || echo "cargo timings: could not read $1"
import json, os, re, sys

path, start = sys.argv[1], int(sys.argv[2])
if os.path.getmtime(path) < start:
    sys.exit(0)
text = open(path, encoding="utf-8").read()
m = re.search(r"\bUNIT_DATA\s*=\s*", text)
if not m:
    raise SystemExit(1)
units, _ = json.JSONDecoder().raw_decode(text, m.end())
def row(u):
    end = u["start"] + u["duration"]
    what = f'{u["name"]} {u.get("target", "").strip()}'.strip()
    return f'  {u["duration"]:7.1f} s  {u["start"]:6.1f}-{end:6.1f}  {what}'
print(f"cargo timings: {len(units)} units; slowest:")
for u in sorted(units, key=lambda u: -u["duration"])[:12]:
    print(row(u))
print("cargo timings: last to end:")
for u in sorted(units, key=lambda u: -(u["start"] + u["duration"]))[:6]:
    print(row(u))
PY
}

# run_group I DIR: group I+1's command in DIR, its output in $logs/N.log and "status end" in $logs/N.done.
run_group() {
  local i=$1 n=$(($1 + 1)) status=0
  export CARGO_TARGET_DIR="$2"
  if ((n == 1)); then export CARGO_BUILD_JOBS="$lead_jobs"; fi
  bash -c "set -euo pipefail; ${commands[i]}" > "$logs/$n.log" 2>&1 || status=$?
  echo "$status $(date +%s)" > "$logs/$n.done"
  return "$status"
}

# oom_killed N: group N's log has a rustc or linker "signal: 9, SIGKILL" and the kernel's oom_kill count rose since
# the groups started, so the runner ran out of memory; not a compile error.
oom_killed() {
  local now
  grep -q 'signal: 9, SIGKILL' "$logs/$1.log" 2>/dev/null || return 1
  now=$(oom_kills)
  [[ -n "$oom_before" && -n "$now" ]] && ((now > oom_before))
}

# is_heavy N: group N is in CARGO_GROUPS_HEAVY.
is_heavy() { [[ " ${CARGO_GROUPS_HEAVY:-} " == *" $1 "* ]]; }

# Start order: every group in turn, except that with HEAVY_GROUPS_ONE_AT_A_TIME each heavy group after the first
# goes last, so the light groups never wait behind it.
order=() deferred=() first_heavy=""
for i in "${!commands[@]}"; do
  n=$((i + 1))
  if [[ -n "$heavy_serial" ]] && is_heavy "$n"; then
    if [[ -n "$first_heavy" ]]; then deferred+=("$i"); continue; fi
    first_heavy=$n
  fi
  order+=("$i")
done
order+=(${deferred[@]+"${deferred[@]}"})

oom_before=$(oom_kills)
for i in "${order[@]}"; do
  n=$((i + 1))
  dir="$target_dir"
  ((n == 1)) || dir="$target_dir/groups/$n"
  dirs[i]=$dir
  # An optional binary must not survive from an earlier build: the copy would
  # stand in for one this run failed to make.
  for b in ${bins[i]}; do
    [[ "$b" == \?* ]] && rm -f "$dir/$triple/release/${b#\?}" "$target_dir/$triple/release/${b#\?}"
  done
  # Capped by memory: hold this group back until fewer than max_par are running.
  while ((${max_par:-0} > 0)); do
    running=0
    for pid in "${pids[@]:-}"; do [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && running=$((running + 1)); done
    ((running < max_par)) && break
    wait -n || true
  done
  # HEAVY_GROUPS_ONE_AT_A_TIME (above): a heavy group starts once no other heavy group is running.
  while [[ -n "$heavy_serial" ]] && is_heavy "$n"; do
    running=0
    for j in "${!pids[@]}"; do
      is_heavy $((j + 1)) && kill -0 "${pids[j]}" 2>/dev/null && running=1
    done
    ((running == 0)) && break
    wait -n || true
  done
  starts[i]=$(date +%s)
  run_group "$i" "$dir" &
  pids[i]=$!
done

for i in "${!pids[@]}"; do
  n=$((i + 1))
  wait "${pids[i]}" || true
  # A group killed before it wrote its .done file still counts as failed, and
  # the other groups' logs still print.
  status=255 end=$(date +%s)
  [[ -f "$logs/$n.done" ]] && read -r status end < "$logs/$n.done"
  label="cargo group $n (${bins[i]//\?/})"
  grouped group "$label"
  cat "$logs/$n.log"
  grouped endgroup
  if ((status != 0)) && oom_killed "$n"; then
    # OOM_RERUN_ALONE: two giant crates of one group (acpmux 936k lines and cmux-tui-core 674k in the cmux-tui
    # group) compile at once when neither depends on the other, and on a 14 GiB pool slot their two rustc
    # processes outgrow memory.max at any token count that still builds in time: 7 tokens, 3 for group 1, lost
    # the acpmux rustc to the kernel (Cloud machine channel runs 46151055654 and 46154021183, 2026-11-28; channel
    # stuck at f3ac175f, lag 138 min against 60). cargo lets the survivor finish ("waiting for other jobs to
    # finish"), so a rerun keeps every finished unit in the target directory and the killed crate compiles without
    # its twin. Once, after every other group ended; a second kill fails the group as before.
    echo "$label: the kernel OOM-killed a process (exit $status); rerunning it once alone, its finished units kept" >&2
    pending_reruns+=("$i")
    continue
  fi
  if ((status != 0)); then
    echo "$label failed (exit $status)" >&2
    failed+=("$n")
    continue
  fi
  echo "$label: $((end - starts[i])) s"
  # A group run with `cargo --timings` (the Cloud machine channel's legs) names
  # its slowest units and its last ones, so a slow leg says where its time went.
  # Under release LTO thin the last unit of the cmux-tui and acpmux groups was
  # their "bin" (107-175 s, every crate's machine code made in the link), so
  # the channel builds with LTO off (cmux-tui-build-package.yml).
  # Groups under 2 min never set a leg's pace: their units would only be noise.
  if ((end - starts[i] >= 120)); then
    timings_summary "${dirs[i]}/cargo-timings/cargo-timing.html" "${starts[i]}"
  fi
done

# OOM_RERUN_ALONE (above): each OOM-killed group again, one at a time, with nothing else building, and with one
# job: alone at its own CARGO_BUILD_JOBS (3 for group 1) the cmux-tui group's rerun still compiled the cmux_tui
# and acpmux rustc at once and lost both to the kernel under memory.max 14 GiB (cmux-tui-artifacts run
# 46161772976, job 141030618742, 2026-11-28). Its finished units are kept, so what is left is mostly the giants,
# and one rustc at a time is the most a rerun can do to fit.
for i in ${pending_reruns[@]+"${pending_reruns[@]}"}; do
  n=$((i + 1))
  label="cargo group $n (${bins[i]//\?/}) rerun"
  echo "$label: CARGO_BUILD_JOBS=1"
  starts[i]=$(date +%s)
  (CARGO_BUILD_JOBS=1 lead_jobs=1 run_group "$i" "${dirs[i]}") || true
  status=255 end=$(date +%s)
  [[ -f "$logs/$n.done" ]] && read -r status end < "$logs/$n.done"
  grouped group "$label"
  cat "$logs/$n.log"
  grouped endgroup
  if ((status != 0)); then
    echo "$label failed (exit $status)" >&2
    failed+=("$n")
    continue
  fi
  echo "$label: $((end - starts[i])) s"
  if ((end - starts[i] >= 120)); then
    timings_summary "${dirs[i]}/cargo-timings/cargo-timing.html" "${starts[i]}"
  fi
done

for i in "${!bins[@]}"; do
  n=$((i + 1))
  [[ " ${failed[*]:-} " == *" $n "* ]] && continue
  for b in ${bins[i]}; do
    name=${b#\?}
    src="${dirs[i]}/$triple/release/$name"
    if [[ ! -f "$src" ]]; then
      [[ "$b" == \?* ]] || missing+=("$name (group $n)")
      continue
    fi
    if ((n > 1)); then
      mkdir -p "$target_dir/$triple/release"
      cp -p "$src" "$target_dir/$triple/release/$name"
    fi
  done
done

if [[ -n "${failed[*]:-}" ]]; then
  # The OOM detector: a group whose rustc or linker died "signal: 9, SIGKILL" while the kernel's oom_kill count rose
  # ran the runner out of memory; it is not a compile error. It names the memory the sizing above read, so the leg
  # says why (handbook ci-build-oom-killed-by-parallel-cargo-groups).
  oom_after=$(oom_kills) killed=()
  for n in "${failed[@]}"; do
    grep -q 'signal: 9, SIGKILL' "$logs/$n.log" 2>/dev/null && killed+=("$n")
  done
  if [[ -n "${killed[*]:-}" ]]; then
    if [[ -n "$oom_before" && -n "$oom_after" ]] && ((oom_after > oom_before)); then
      why="the kernel OOM-killed $((oom_after - oom_before)) process(es) during the build"
    else
      why="SIGKILL without a counted kernel OOM kill (oom_kill ${oom_before:-?} -> ${oom_after:-?}): a cgroup or outside kill"
    fi
    echo "::error title=cargo groups out of memory::cargo group(s) ${killed[*]} lost a process to SIGKILL; $why. Memory at the start: memory.max ${mem_gib:-none} GiB, MemAvailable ${avail_gib:-?} GiB of ${total_gib:-?} GiB; MemAvailable now $(meminfo_gib MemAvailable) GiB. CARGO_BUILD_JOBS=$lead_jobs for group 1, $CARGO_BUILD_JOBS for the others (scripts/ci/cargo-groups.sh)" >&2
  fi
  echo "error: cargo group(s) ${failed[*]} failed" >&2
  exit 1
fi
if [[ -n "${missing[*]:-}" ]]; then
  echo "error: no binary ${missing[*]} in its group's target directory" >&2
  exit 1
fi
