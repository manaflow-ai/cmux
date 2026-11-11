#!/usr/bin/env bash
# The migration proof of the registry rebuild at a retention floor, on a GENERATED registry of
# the long-lived shape (many workspaces, agent and progress records, almost no stored output).
#   scripts/measure/registry-migration-proof.sh [size_gb=1] [workspaces=826] [seal_age_minutes=120]
#     [young_segments=N] [arms=main,kill-stage,kill-swap,kill-renamed,space,old,old-raised]
#     [debug=1] [old_bin=label=/abs/older/cmux-tui[,label=/abs/other/cmux-tui]] [old_dwell=45]
#     [ready_timeout=3600] [build_timeout=7200]
#     [state=/abs/path/of/a/generated/state/dir]
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
arms=main,kill-stage,kill-swap,kill-renamed,space,old,old-raised old_dwell=45
ready_timeout=3600 build_timeout=7200
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
    ready_timeout=*) ready_timeout="${kv#*=}" ;;
    build_timeout=*) build_timeout="${kv#*=}" ;;
    state=*) state="${kv#*=}" ;;
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
if [[ -n "$state" && ( "$state" != /* || ! -d "$state" ) ]]; then
  echo "error: state= needs the absolute path of a generated state dir" >&2; exit 2
fi
out="$root/.build/registry-migration-proof"
mkdir -p "$out"
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
  gen_started=$(date +%s)
  "$synth" "${args[@]}" > "$out/generate.json"
  echo "RMP-GEN $(cat "$out/generate.json") wall_s=$(( $(date +%s) - gen_started ))"
fi

python3 "$root/scripts/measure/registry-migration-proof.py" \
  --bin "$bin" --synth "$synth" --state "$scratch/state" --home "$scratch/home" \
  --session "$session" --socket-dir "$socket_dir" --scratch "$scratch" \
  --debug-bin "$debug_bin" --old-bin "$old_bin" --arms "$arms" --old-dwell "$old_dwell" \
  --ready-timeout "$ready_timeout" --build-timeout "$build_timeout" --report "$out/report.json"
