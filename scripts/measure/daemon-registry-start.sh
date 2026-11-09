#!/usr/bin/env bash
# Start time of the cmux-tui session daemon on a large registry, before and after an agent-roster
# reducer version bump (2026-11-09: a 59 GB registry took 26 min to restore after a bump).
#   cmux-ci run --class exclusive --measurement --script scripts/measure/daemon-registry-start.sh \
#     --ref SHA --os macos [--arg=size_gb=10] [--arg=bump=1] [--arg=seal=1] [--arg=output_gb=0] \
#     [--arg=rounds=1] --artifact .build/daemon-registry-start/report.json --timeout 7200
# It builds release `cmux-tui` and cmux-tui-core's `synth_registry` example, writes a registry of
# about size_gb (96% personal.session.put rows of ~6 KiB, agent hook events, legacy output, sealed
# segments: cmux_tui_core::synth_registry), then starts `cmux-tui --headless` on it with its own
# CMUX_TUI_STATE_DIR, rounds times after a roster version bump and once more with the saved
# snapshot. Each start reports time to listen (socket file), to identify (first answer), to ready
# (identify's lifecycle_ready) and the owner's startup-timings.jsonl laps.
# Output: DRS-GEN {json} (the generator's report and throughput), DRS {json} per start, and
# .build/daemon-registry-start/report.json with all of them. Exit 1 when a start did not get ready.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
size_gb=2 bump=1 seal=1 output_gb=0 rounds=1 ready_timeout=3600
for kv in "$@"; do
  case "$kv" in
    size_gb=*) size_gb="${kv#*=}" ;;
    bump=*) bump="${kv#*=}" ;;
    seal=*) seal="${kv#*=}" ;;
    output_gb=*) output_gb="${kv#*=}" ;;
    rounds=*) rounds="${kv#*=}" ;;
    ready_timeout=*) ready_timeout="${kv#*=}" ;;
    *) echo "error: unknown argument $kv" >&2; exit 2 ;;
  esac
done
out="$root/.build/daemon-registry-start"
rm -rf "$out" && mkdir -p "$out"
# ghostty-vt-sys builds libghostty-vt from the ghostty-next submodule (as cmux-tui-rust-check.sh).
if [[ ! -f "$root/ghostty-next/build.zig" ]]; then
  git -C "$root" submodule update --init --depth 1 ghostty-next
fi
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$root/.build/cmux-tui-rust-target}"
(cd "$root/cmux-tui" && cargo build --release --locked -p cmux-tui --bin cmux-tui \
  && cargo build --release --locked -p cmux-tui-core --example synth_registry)
bin="$CARGO_TARGET_DIR/release/cmux-tui"
synth="$CARGO_TARGET_DIR/release/examples/synth_registry"

# The registry is tens of GB: on disk, not /tmp (Linux /tmp can be RAM). The socket stays short.
scratch="${CMUX_DRS_SCRATCH:-$HOME/.cache/cmux-daemon-registry-start}/run-$$"
socket_dir="$(mktemp -d /tmp/cmux-drs.XXXXXX)"
trap 'rm -rf "$scratch" "$socket_dir"' EXIT
mkdir -p "$scratch/state" "$scratch/home"
chmod 700 "$scratch" "$scratch/state"
free_gb=$(( $(df -Pk "$scratch" | awk 'NR==2 {print $4}') / 1048576 ))
echo "DRS host $(hostname -s) $(uname -sm) free ${free_gb} GB at $scratch"
if (( free_gb < size_gb * 3 )); then
  echo "warning: $free_gb GB free, under 3x the registry; the run may run out of disk"
fi

# Rows: a ~6 KiB put costs about 6.6 KiB of file; agent events are 4% of the rows.
puts=$(( size_gb * 1024 * 1024 * 1024 * 96 / 100 / 6750 ))
events=$(( puts / 24 ))
args=(--out "$scratch/state" --session drs --session-puts "$puts" --agent-events "$events"
  --output-bytes "$(( output_gb * 1024 * 1024 * 1024 ))" --workspaces 24 --quiet)
[[ "$seal" != 1 ]] || args+=(--seal)
[[ "$bump" != 1 ]] || args+=(--roster-version-bump)
gen_started=$(date +%s)
"$synth" "${args[@]}" > "$out/generate.json"
echo "DRS-GEN $(cat "$out/generate.json") wall_s=$(( $(date +%s) - gen_started ))"

python3 "$root/scripts/measure/daemon-registry-start.py" \
  --bin "$bin" --state "$scratch/state" --home "$scratch/home" --session drs \
  --socket "$socket_dir/mux.sock" --generate "$out/generate.json" \
  --rounds "$rounds" --bump "$bump" --ready-timeout "$ready_timeout" --report "$out/report.json"
