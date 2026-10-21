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

bins=() commands=() dirs=() pids=() starts=() failed=() missing=()
while (($#)); do
  bins+=("$1") commands+=("$2")
  shift 2
done

grouped() { [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::$1::${2:-}" || true; }

if [[ -z "${CARGO_BUILD_JOBS:-}" ]]; then
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
  groups=${#commands[@]}
  jobs=$(((2 * cores + groups - 1) / groups))
  ((jobs >= 1)) || jobs=1
  export CARGO_BUILD_JOBS=$jobs
fi
echo "cargo groups: ${#commands[@]}, CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS each"

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
  starts+=("$(date +%s)")
  (
    export CARGO_TARGET_DIR="$dir"
    status=0
    bash -c "set -euo pipefail; ${commands[i]}" > "$logs/$n.log" 2>&1 || status=$?
    echo "$status $(date +%s)" > "$logs/$n.done"
    exit "$status"
  ) &
  pids+=("$!")
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
  if ((status != 0)); then
    echo "$label failed (exit $status)" >&2
    failed+=("$n")
    continue
  fi
  echo "$label: $((end - starts[i])) s"
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
