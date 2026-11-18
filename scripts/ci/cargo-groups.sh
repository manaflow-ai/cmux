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
#
# Memory: each group has a weight in GB, CARGO_GROUPS_GB (one number per
# group, in order; 6 for a group it does not list). A group starts, in group
# order, once the weights of the running groups and its own fit in MEM_GB (the
# job's cgroup limit, else MemTotal; CARGO_GROUPS_MEM_GB sets it for a test),
# or when nothing else runs. All six Linux musl groups at once on a 4 vCPU
# Blacksmith runner were killed by the OOM killer: rustc ended "(signal: 9,
# SIGKILL: kill)" with no compiler error (run 44284933048, 2026-11-18, while
# RUNNER_POOLS had spilled linux_16 to 4 vCPU). The cmux-tui and
# acpmux-standalone groups each link cmux-tui-core under fat LTO and need
# 10-12 GB; the others under 2 (cmux-tui-build-package.yml). The script prints
# the peak memory in use and each group's largest process, and names a group
# whose compiler was killed by signal 9 as the runner's memory, not the code
# ("[cmux-ci machine: runner-oom]").
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

bins=() commands=() dirs=() starts=() failed=() missing=()
while (($#)); do
  bins+=("$1") commands+=("$2")
  shift 2
done

grouped() { [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::$1::${2:-}" || true; }

gb() { awk -v kb="$1" 'BEGIN { printf "%.1f", kb / 1048576 }'; }
cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
groups=${#commands[@]}
# mem_kb: the job's memory, its cgroup limit when that is lower.
mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)
limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)
if [[ "$limit" =~ ^[0-9]+$ ]] && { [[ -z "$mem_kb" ]] || ((limit / 1024 < mem_kb)); }; then
  mem_kb=$((limit / 1024))
fi
[[ -z "${CARGO_GROUPS_MEM_GB:-}" ]] || mem_kb=$((CARGO_GROUPS_MEM_GB * 1048576))
read -r -a listed <<< "${CARGO_GROUPS_GB:-}"
weights=()
for i in "${!commands[@]}"; do
  w=${listed[i]:-6}
  [[ "$w" =~ ^[0-9]+$ ]] || { echo "error: CARGO_GROUPS_GB entry '$w' is not a whole number of GB" >&2; exit 2; }
  weights+=("$w")
done
# fits USED I: group I+1 fits beside running groups weighing USED GB.
fits() { [[ -z "$mem_kb" ]] || ((($1 + weights[$2]) * 1048576 <= mem_kb)); }
# How many start at once, for the log.
first=0 used=0
for i in "${!commands[@]}"; do
  if ((first == 0)) || fits "$used" "$i"; then
    first=$((first + 1)) used=$((used + weights[i]))
  fi
done
# The most groups that can ever run together: the lightest ones, as many as
# fit. The job split is sized for that, not for the first admission: on 16 GB
# with weights 13 2 2 2 13 2 two start, but once group 1 ends four 2 GB groups
# run at once, and a split sized for two gave each of them every core (review
# of #46436, F1).
peak=0 used=0
while read -r w; do
  if ((peak == 0)) || [[ -z "$mem_kb" ]] || (((used + w) * 1048576 <= mem_kb)); then
    peak=$((peak + 1)) used=$((used + w))
  fi
done < <(printf '%s\n' "${weights[@]}" | sort -n)
echo "cargo groups: $groups, $first at first, at most $peak at once ($cores vCPU, $(gb "${mem_kb:-0}") GB; GB a group: ${weights[*]})"

if [[ -z "${CARGO_BUILD_JOBS:-}" ]]; then
  slots=$peak
  jobs=$(((2 * cores + slots - 1) / slots))
  ((jobs <= cores)) || jobs=$cores
  ((jobs >= 1)) || jobs=1
  lead_jobs=$((cores > jobs ? cores : jobs))
  export CARGO_BUILD_JOBS=$jobs
  echo "cargo groups: CARGO_BUILD_JOBS=$lead_jobs for group 1, $CARGO_BUILD_JOBS each for the others"
else
  lead_jobs=$CARGO_BUILD_JOBS
  echo "cargo groups: CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS each"
fi

# The peak memory in use while the groups run (MemTotal - MemAvailable),
# sampled each second into $logs/peak.
sample_memory() {
  local peak=0 used
  while :; do
    used=$(awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2} END {if (t && a) print t - a}' /proc/meminfo 2>/dev/null || true)
    if [[ -n "$used" ]] && ((used > peak)); then
      peak=$used
      echo "$peak" > "$logs/peak"
    fi
    sleep 1
  done
}
sampler=""
if [[ -r /proc/meminfo ]]; then
  sample_memory &
  sampler=$!
  trap 'if [[ -n "$sampler" ]]; then kill "$sampler" 2>/dev/null || true; fi; rm -rf "$logs"' EXIT
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

for i in "${!commands[@]}"; do
  n=$((i + 1))
  dir="$target_dir"
  ((n == 1)) || dir="$target_dir/groups/$n"
  dirs+=("$dir")
  # An optional binary must not survive from an earlier build: the copy would
  # stand in for one this run failed to make.
  for b in ${bins[i]}; do
    [[ "$b" == \?* ]] && rm -f "$dir/$triple/release/${b#\?}" "$target_dir/$triple/release/${b#\?}"
  done
done

# run_group I: group I+1 in the foreground; its log, start, end and largest
# process (GNU time, when the runner has it) go to $logs.
run_group() {
  local i=$1 n=$(($1 + 1)) status=0
  date +%s > "$logs/$n.start"
  (
    export CARGO_TARGET_DIR="${dirs[i]}"
    if ((n == 1)); then export CARGO_BUILD_JOBS="$lead_jobs"; fi
    timed=()
    [[ ! -x /usr/bin/time ]] || timed=(/usr/bin/time -q -f %M -o "$logs/$n.rss")
    "${timed[@]}" bash -c "set -euo pipefail; ${commands[i]}" > "$logs/$n.log" 2>&1
  ) || status=$?
  echo "$status $(date +%s)" > "$logs/$n.done"
}

# Start every pending group that fits, in group order; when none does, wait
# for one to end and look again. A group that fits nowhere starts alone.
pending=("${!commands[@]}") used=0
declare -A running=()
while ((${#pending[@]})); do
  rest=()
  for i in "${pending[@]}"; do
    if ((${#running[@]} == 0)) || fits "$used" "$i"; then
      run_group "$i" &
      running[$!]=$i
      used=$((used + weights[i]))
    else
      rest+=("$i")
    fi
  done
  pending=("${rest[@]}")
  ((${#pending[@]})) || break
  ended=""
  wait -n -p ended "${!running[@]}" || true
  [[ -n "$ended" && -n "${running[$ended]:-}" ]] || continue
  done_group=${running[$ended]}
  used=$((used - weights[done_group]))
  unset -v 'running[$ended]'
done
for pid in "${!running[@]}"; do wait "$pid" || true; done
if [[ -n "$sampler" ]]; then
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
  sampler=""
fi
peak_kb=$(cat "$logs/peak" 2>/dev/null || true)
[[ -z "$peak_kb" ]] || echo "cargo groups: peak memory in use $(gb "$peak_kb") of $(gb "${mem_kb:-0}") GB"

for i in "${!commands[@]}"; do
  n=$((i + 1))
  # A group killed before it wrote its .done file still counts as failed, and
  # the other groups' logs still print.
  status=255 end=$(date +%s)
  [[ -f "$logs/$n.done" ]] && read -r status end < "$logs/$n.done"
  start=$end
  [[ -f "$logs/$n.start" ]] && read -r start < "$logs/$n.start"
  starts+=("$start")
  label="cargo group $n (${bins[i]//\?/})"
  grouped group "$label"
  cat "$logs/$n.log" 2>/dev/null || true
  grouped endgroup
  if ((status != 0)); then
    echo "$label failed (exit $status)" >&2
    # A compiler the kernel killed prints no error of its own: the runner ran
    # out of memory. Say so, so nobody reads the job as the code's failure.
    if grep -qE 'signal: 9, SIGKILL' "$logs/$n.log" 2>/dev/null; then
      oom="$label: a compiler was killed by signal 9 with no compiler error, the runner's out-of-memory killer [cmux-ci machine: runner-oom]."
      oom+=" Runner ${RUNNER_NAME:-?}: $cores vCPU, $(gb "${mem_kb:-0}") GB, $(gb "${peak_kb:-0}") GB the peak in use."
      oom+=" The machine, not the code: re-run it on a larger size (RUNNER_POOLS linux_16: 16, 8 or 32 vCPU)."
      echo "$oom" >&2
      grouped "error title=runner out of memory" "$oom"
    fi
    failed+=("$n")
    continue
  fi
  rss=$(tail -n 1 "$logs/$n.rss" 2>/dev/null || true)
  [[ "$rss" =~ ^[0-9]+$ ]] || rss=""
  echo "$label: $((end - start)) s${rss:+, largest process $(gb "$rss") GB}"
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
  echo "error: cargo group(s) ${failed[*]} failed" >&2
  exit 1
fi
if [[ -n "${missing[*]:-}" ]]; then
  echo "error: no binary ${missing[*]} in its group's target directory" >&2
  exit 1
fi
