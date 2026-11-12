#!/usr/bin/env bash
# The migration proof of the registry rebuild at a retention floor, on a GENERATED registry of
# the long-lived shape (many workspaces, agent and progress records, almost no stored output).
#   scripts/measure/registry-migration-proof.sh [size_gb=1] [workspaces=826] [seal_age_minutes=120]
#     [young_segments=N]
#     [arms=control,main,kill-stage,kill-swap,kill-renamed,space,in-place,in-place-kept,second-swap,
#      old,old-raised]
#     [space_dwell=0] [in_place_dwell=150] [kept_dwell=N] [kept_records=N] [stack_ms=10]
#     [debug=1] [old_bin=label=/abs/older/cmux-tui[,label=/abs/other/cmux-tui]] [old_dwell=45]
#     [ready_timeout=3600] [build_timeout=7200]
#     [state=/abs/path/of/a/generated/state/dir]
#     [records=N sparse_head=N sparse_records=N] [rested_agents=N] [live_rows=N]
#     [second_records=200000] [second_build_timeout=1800]
#     [bin=/abs/release/cmux-tui synth=/abs/release/synth_registry [debug_bin=/abs/debug/cmux-tui]]
#     [base_bin=/abs/release/cmux-tui of a build with none of this change]
#     [session=rmp]
# records=, sparse_head= and sparse_records= write the SPARSE form of a long-lived journal (the
# head far above the records the file holds; synth_registry's doc); rested_agents= adds agents
# with every record below any floor; live_rows= is the count of records above the last
# checkpoint; second_records= is the count of records that the second-swap arm appends before
# its rebuild (an owner rebuilds only with 100,000 records at or below the floor), and
# second_build_timeout= is the longest wait in seconds for that rebuild. bin= and synth= take
# binaries that another host built from the same commit: this script then compiles nothing
# (debug_bin= for the free-space arm; without it that arm is left out). session= is the session
# name of the registry; a state= dir must hold a registry of that session.
# The in-place arm: a release owner that starts no rebuild (this script puts an empty file with
# the kept name beside the registry) deletes sealed segments in place for in_place_dwell=
# seconds; the row is the registry lock by site (server-stats `locks`) and the request times.
# space_dwell= keeps the debug owner of the space arm that long after the refusal: the same
# deletes through the product's own no-space path, with a debug build's times.
# The in-place-kept arm: the delete in place on the SMALL file after the swap, with the kept
# file of that swap held (what a person gets each day: no rebuild for 7 days and 3 starts) and
# kept_records= sealed records appended by the generator (default second_records=). It runs
# until 75 s pass with no delete, or kept_dwell= seconds (default in_place_dwell=). The row
# has each pass that deleted and the request times while a pass deleted and with no pass.
# arms= can also name in-place-stacks and in-place-kept-stacks (not in the default list): the
# same two arms on their own clones with the macOS stack sampler on the owner each stack_ms=
# milliseconds: the share of the delete that waits for another writer, syncs, writes, reads or
# runs. The sampler slows the owner: the times of those two arms are not the arms' times.
# arms= can also name in-place-kept-nowatch and in-place-kept-quiet: the in-place-kept arm with no
# read of the registry file by the script while the owner runs, and (quiet) with no probe request.
# Each in-place row and the base-sample row has `wal`: the owner's own WAL counters.
# arms= can also name first-fold (not in the default list): a head owner on a clone from before
# start 1 is asked for the agent History list until the answer is complete; the row is the seconds
# of that first fold.
# arms= can also name kill-hold (not in the default list): kill -9 between two holds of the
# delete in place of one segment (a part of its rows gone, its row and content there), then
# a start that must end that delete with the counts and the served answer equal.
# base_bin= adds the base-sample arm: that build owns a clone from before start 1 for
# in_place_dwell= seconds with the same sampler, so the lock and request times of the in-place
# arm have a row that shows what the size of the file and the host cost with no delete.
# arms= can also name base-kept (with base_bin=): that build owns a clone of the SMALL registry
# after the swap, with the same appended records and the same probe as the in-place-kept arms
# for kept_dwell= seconds. It has no retention pass: the row is what the probe's requests cost
# on that file with no delete in place (the WAL counters, the request times).
# It builds release `cmux-tui` and cmux-tui-core's `synth_registry` example (and a debug
# `cmux-tui` with debug=1, for the free-space arm: only a debug owner has that test seam), writes
# the registry (synth_registry --shape lawrence), then runs registry-migration-proof.py: real owner
# processes, real kill -9, counts before and after. A release owner has no test seam, so the
# times are the product's: 60 s before the first staging, 30 s between two maintenance passes.
# Needs free disk of about 3 x size_gb (the file, the new file beside it, the kept old file);
# the arms clone the state (`cp -c` on APFS: no extra disk until a file changes).
# state= takes a state dir that synth_registry wrote before (a 9.6 GB one takes most of an hour
# to write): the run works on a clone of it and writes none; that dir stays, its owner removes it.
# Output: RMP-GEN {json}, RMP {json} per step, RMP-TABLE rows, and
# .build/registry-migration-proof/report.json. The report holds counts, sizes and times only.
# The scratch dir with every generated registry goes at exit. Exit 1 when a count differs.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
session=rmp
size_gb=1 workspaces=826 seal_age_minutes=120 young_segments= debug=1 old_bin= state=
arms=control,main,kill-stage,kill-swap,kill-renamed,space,in-place,in-place-kept,second-swap,old,old-raised
old_dwell=45 space_dwell=0 in_place_dwell=150 kept_dwell=0 kept_records=0 stack_ms=10
ready_timeout=3600 build_timeout=7200
records= sparse_head= sparse_records= rested_agents= live_rows= bin= synth= debug_bin=
base_bin=
second_records=200000 second_build_timeout=1800
for kv in "$@"; do
  case "$kv" in
    size_gb=*) size_gb="${kv#*=}" ;;
    workspaces=*) workspaces="${kv#*=}" ;;
    seal_age_minutes=*) seal_age_minutes="${kv#*=}" ;;
    young_segments=*) young_segments="${kv#*=}" ;;
    arms=*) arms="${kv#*=}" ;;
    debug=*) debug="${kv#*=}" ;;
    old_bin=*) old_bin="${kv#*=}" ;;
    old_dwell=*) old_dwell="${kv#*=}" ;;
    space_dwell=*) space_dwell="${kv#*=}" ;;
    in_place_dwell=*) in_place_dwell="${kv#*=}" ;;
    kept_dwell=*) kept_dwell="${kv#*=}" ;;
    kept_records=*) kept_records="${kv#*=}" ;;
    stack_ms=*) stack_ms="${kv#*=}" ;;
    ready_timeout=*) ready_timeout="${kv#*=}" ;;
    build_timeout=*) build_timeout="${kv#*=}" ;;
    state=*) state="${kv#*=}" ;;
    records=*) records="${kv#*=}" ;;
    sparse_head=*) sparse_head="${kv#*=}" ;;
    sparse_records=*) sparse_records="${kv#*=}" ;;
    rested_agents=*) rested_agents="${kv#*=}" ;;
    live_rows=*) live_rows="${kv#*=}" ;;
    second_records=*) second_records="${kv#*=}" ;;
    second_build_timeout=*) second_build_timeout="${kv#*=}" ;;
    bin=*) bin="${kv#*=}" ;;
    synth=*) synth="${kv#*=}" ;;
    debug_bin=*) debug_bin="${kv#*=}" ;;
    base_bin=*) base_bin="${kv#*=}" ;;
    session=*) session="${kv#*=}" ;;
    *) echo "error: unknown argument $kv" >&2; exit 2 ;;
  esac
done
# No space in a path: the list splits at commas (bash 3.2 has no safe empty array under -u).
for one in ${old_bin//,/ }; do
  one="${one##*=}"
  if [[ "$one" != /* || ! -x "$one" ]]; then
    echo "error: old_bin= needs the absolute path of an executable cmux-tui: $one" >&2; exit 2
  fi
done
if [[ -n "$base_bin" && ( "$base_bin" != /* || ! -x "$base_bin" ) ]]; then
  echo "error: base_bin= needs the absolute path of an executable cmux-tui: $base_bin" >&2; exit 2
fi
if [[ -n "$state" && ( "$state" != /* || ! -d "$state" ) ]]; then
  echo "error: state= needs the absolute path of a generated state dir" >&2; exit 2
fi
out="$root/.build/registry-migration-proof"
mkdir -p "$out"
if [[ -n "$bin" || -n "$synth" ]]; then
  # Binaries of another host: nothing is compiled here.
  for one in "$bin" "$synth" $debug_bin; do
    if [[ "$one" != /* || ! -x "$one" ]]; then
      echo "error: bin=, synth= and debug_bin= need absolute paths of executables: $one" >&2; exit 2
    fi
  done
else
  # ghostty-vt-sys builds libghostty-vt from the ghostty-next submodule (as cmux-tui-rust-check.sh).
  if [[ ! -f "$root/ghostty-next/build.zig" ]]; then
    git -C "$root" submodule update --init --depth 1 ghostty-next
  fi
  export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$root/.build/cmux-tui-rust-target}"
  (cd "$root/cmux-tui" && cargo build --release --locked -p cmux-tui --bin cmux-tui \
    && cargo build --release --locked -p cmux-tui-core --example synth_registry)
  bin="$CARGO_TARGET_DIR/release/cmux-tui"
  synth="$CARGO_TARGET_DIR/release/examples/synth_registry"
  debug_bin=
  if [[ "$debug" == 1 ]]; then
    (cd "$root/cmux-tui" && cargo build --locked -p cmux-tui --bin cmux-tui)
    debug_bin="$CARGO_TARGET_DIR/debug/cmux-tui"
  fi
fi

# The registry is GBs: on disk, not /tmp (Linux /tmp can be RAM). The socket path stays short.
scratch="${CMUX_RMP_SCRATCH:-$HOME/.cache/cmux-registry-migration-proof}/run-$$"
socket_dir="$(mktemp -d /tmp/cmux-rmp.XXXXXX)"
trap 'rm -rf "${scratch:?}" "${socket_dir:?}"' EXIT
mkdir -p "$scratch/home"
chmod 700 "$scratch"
free_gb=$(( $(df -Pk "$scratch" | awk 'NR==2 {print $4}') / 1048576 ))
echo "RMP host $(hostname -s) $(uname -sm) free ${free_gb} GB size_gb=$size_gb workspaces=$workspaces"
if (( free_gb < size_gb * 3 + 2 )); then
  echo "error: $free_gb GB free, under 3 x the registry + 2 GB: not started" >&2; exit 1
fi

if [[ -n "$state" ]]; then
  if [[ "$(uname -s)" == Darwin ]]; then cp -cR "$state" "$scratch/state"; else cp -R --reflink=auto "$state" "$scratch/state"; fi
  chmod 700 "$scratch/state"
  echo "RMP-GEN a clone of a state dir that was generated before"
else
  mkdir -p "$scratch/state"
  chmod 700 "$scratch/state"
  args=(--out "$scratch/state" --session "$session" --shape lawrence
    --target-bytes "$(( size_gb * 1024 * 1024 * 1024 ))" --workspaces "$workspaces"
    --seal-age-minutes "$seal_age_minutes" --quiet)
  [[ -z "$young_segments" ]] || args+=(--young-segments "$young_segments")
  [[ -z "$records" ]] || args+=(--records "$records")
  [[ -z "$sparse_head" ]] || args+=(--sparse-head "$sparse_head" --sparse-records "$sparse_records")
  [[ -z "$rested_agents" ]] || args+=(--rested-agents "$rested_agents")
  [[ -z "$live_rows" ]] || args+=(--live-rows "$live_rows")
  gen_started=$(date +%s)
  "$synth" "${args[@]}" > "$out/generate.json"
  echo "RMP-GEN $(cat "$out/generate.json") wall_s=$(( $(date +%s) - gen_started ))"
fi

python3 "$root/scripts/measure/registry-migration-proof.py" \
  --bin "$bin" --synth "$synth" --state "$scratch/state" --home "$scratch/home" \
  --session "$session" --socket-dir "$socket_dir" --scratch "$scratch" \
  --debug-bin "$debug_bin" --base-bin "$base_bin" --old-bin "$old_bin" --arms "$arms" \
  --old-dwell "$old_dwell" \
  --ready-timeout "$ready_timeout" --build-timeout "$build_timeout" \
  --seal-age-minutes "$seal_age_minutes" --second-records "$second_records" \
  --second-build-timeout "$second_build_timeout" \
  --space-dwell "$space_dwell" --in-place-dwell "$in_place_dwell" \
  --kept-dwell "$kept_dwell" --kept-records "$kept_records" --stack-ms "$stack_ms" \
  --report "$out/report.json"
