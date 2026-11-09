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
#
# On an existing registry instead of a generated one (also runs directly on a Mac):
#   scripts/measure/daemon-registry-start.sh registry=/path/to/workspace-registry.sqlite3 bump=0 rounds=2
# The file (and its -wal, -shm) is cloned into the scratch state dir where the owner of session
# drs opens it (`cp -c` on macOS: an APFS clone, instant and no extra disk, so CMUX_DRS_SCRATCH
# must be on the same volume; `cp --reflink=auto` on Linux). Only the clone is ever opened
# read-write; the source is only read by cp. bump=1 sets the clone's roster snapshot one version
# behind first (synth_registry --bump-only), bump=0 starts it as it is. DRS-REG {json} replaces
# DRS-GEN: sizes, journal head and roster version as found. The report holds only sizes, counts,
# versions and timings, no paths or row contents. The scratch dir with the clone goes at exit.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
size_gb=2 bump=1 seal=1 output_gb=0 rounds=1 ready_timeout=3600 registry=
for kv in "$@"; do
  case "$kv" in
    size_gb=*) size_gb="${kv#*=}" ;;
    bump=*) bump="${kv#*=}" ;;
    seal=*) seal="${kv#*=}" ;;
    output_gb=*) output_gb="${kv#*=}" ;;
    rounds=*) rounds="${kv#*=}" ;;
    ready_timeout=*) ready_timeout="${kv#*=}" ;;
    registry=*) registry="${kv#*=}" ;;
    *) echo "error: unknown argument $kv" >&2; exit 2 ;;
  esac
done
if [[ -n "$registry" && ( "$registry" != /* || ! -f "$registry" ) ]]; then
  echo "error: registry= needs the absolute path of an existing registry file" >&2; exit 2
fi
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

if [[ -n "$registry" ]]; then
  # The owner of session drs opens exactly this path (persistent_session_state_dir).
  clone="$("$synth" --out "$scratch/state" --session drs --print-registry-path)"
  mkdir -p "$(dirname "$clone")"
  chmod 700 "$(dirname "$clone")"
  if [[ "$(uname -s)" == Darwin ]]; then clone_flag=-c; else clone_flag=--reflink=auto; fi
  if [[ "$clone_flag" != -c ]]; then
    source_gb=$(( $(wc -c < "$registry") / 1073741824 ))
    if (( free_gb < source_gb * 2 )); then
      echo "warning: $free_gb GB free; a copy without reflink needs ${source_gb} GB and more"
    fi
  fi
  clone_started=$(date +%s)
  for suffix in "" -wal -shm; do
    [[ -e "$registry$suffix" ]] || continue
    if ! cp "$clone_flag" "$registry$suffix" "$clone$suffix"; then
      echo "error: could not clone the registry${suffix} (on macOS CMUX_DRS_SCRATCH must be on its volume)" >&2
      exit 1
    fi
    chmod 600 "$clone$suffix"
  done
  # Sizes, journal head and roster as found, read-only on the clone.
  python3 - "$clone" "$(( $(date +%s) - clone_started ))" > "$out/found.json" <<'PY'
import json, os, sqlite3, sys
clone, clone_s = sys.argv[1], int(sys.argv[2])
size = lambda path: os.path.getsize(path) if os.path.exists(path) else 0
db = sqlite3.connect("file:" + clone + "?mode=ro", uri=True)
one = lambda sql: db.execute(sql).fetchone()
roster = one("SELECT value FROM meta WHERE key = 'journal_reducer.agent_roster'")
roster = json.loads(roster[0]) if roster else {}
try:
    segments = one("SELECT count(*), max(end_sequence) FROM journal_segments")
except sqlite3.OperationalError:  # an older schema without sealed segments
    segments = (0, 0)
print(json.dumps({
    "registry_bytes": size(clone), "wal_bytes": size(clone + "-wal"), "shm_bytes": size(clone + "-shm"),
    "page_size": one("PRAGMA page_size")[0], "page_count": one("PRAGMA page_count")[0],
    "freelist_count": one("PRAGMA freelist_count")[0],
    "schema_version": int(one("SELECT value FROM meta WHERE key = 'schema_version'")[0]),
    "journal_max_sequence": one("SELECT max(sequence) FROM session_journal")[0] or 0,
    "segments": segments[0], "sealed_through": segments[1] or 0,
    "roster_version_found": roster.get("version"),
    "roster_cursor_found": int(roster["cursor"]) if "cursor" in roster else None,
    "clone_s": clone_s,
}))
PY
  if [[ "$bump" == 1 ]]; then
    "$synth" --bump-only --registry "$clone" > "$out/bump.json"
  else
    echo "{\"roster_current_version\":$("$synth" --print-roster-version)}" > "$out/bump.json"
  fi
  python3 -c 'import json, sys; found, bumped = (json.load(open(p)) for p in sys.argv[1:3])
found.update(source="registry", bumped=bumped); print(json.dumps(found))' \
    "$out/found.json" "$out/bump.json" > "$out/generate.json"
  echo "DRS-REG $(cat "$out/generate.json")"
else
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
fi

python3 "$root/scripts/measure/daemon-registry-start.py" \
  --bin "$bin" --state "$scratch/state" --home "$scratch/home" --session drs \
  --socket "$socket_dir/mux.sock" --generate "$out/generate.json" \
  --rounds "$rounds" --bump "$bump" --ready-timeout "$ready_timeout" --report "$out/report.json"
