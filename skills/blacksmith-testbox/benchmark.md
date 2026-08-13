# cmux-tui Testbox timing plan

Run this plan from the root of the isolated cmux worktree. It never invokes a
Rust tool on the local Mac. Every `cargo`, `rustc`, and `zig` command below is
inside a quoted command passed to `blacksmith testbox run`, or inside the
setup-only GitHub job on the remote Linux runner.

## Fixed lane contract

| Item | Value |
| --- | --- |
| Workflow | `.github/workflows/ci-workflow-guard-tests-testbox.yml` |
| Job | `cmux-tui-rust` |
| Runner | `blacksmith-32vcpu-ubuntu-2404` |
| Rust source of truth | `cmux-tui/rust-toolchain.toml`, via `./.github/actions/setup-cmux-tui-rust` |
| Remote build helper | `scripts/blacksmith-cmux-tui-testbox-stage.sh` |
| Remote output | `testbox-benchmark/`, ignored by the repository so repeated runs retain it |

The warmup job only checks out the exact dispatch SHA, initializes `ghostty`,
installs Linux headers/tools, installs the pinned Zig and Rust toolchains, and
fetches Cargo and Zig dependencies. `zig build --fetch` is the only build-system
operation in warmup, and it exits before compiling. Rust builds happen only in
the three explicit benchmark runs.

The current Blacksmith catalog reports the requested x64 label as 32 vCPU and
121.6 GB, while the ARM label with the same vCPU count reports 96 GB. Keep the
requested `blacksmith-32vcpu-ubuntu-2404` label unless the repository's Linux
constraints make x64 impossible, and record the catalog result with the run.

## Warmup and identity capture

```bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
SHA="$(git rev-parse HEAD)"
WORKFLOW=.github/workflows/ci-workflow-guard-tests-testbox.yml
JOB=cmux-tui-rust
OUT="$PWD/.cmux-scratch/blacksmith-testbox-cmux-tui-$SHA"
mkdir -p "$OUT/raw"

blacksmith auth whoami

now() { python3 -c 'import time; print(f"{time.time():.6f}")'; }
TBX=""
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n "$TBX" ]]; then
    blacksmith testbox stop --id "$TBX" >"$OUT/stop.log" 2>&1 || true
  fi
  blacksmith testbox list --all >"$OUT/list-after-stop.log" 2>&1 || true
  exit "$result"
}
trap cleanup EXIT

warmup_started="$(now)"
set +e
blacksmith testbox warmup "$WORKFLOW" \
  --ref "$SHA" \
  --job "$JOB" \
  --idle-timeout 30 2>&1 | tee "$OUT/warmup.log"
warmup_status=${PIPESTATUS[0]}
set -e
warmup_finished="$(now)"
python3 - "$SHA" "$JOB" "$warmup_started" "$warmup_finished" "$warmup_status" "$OUT/warmup.json" <<'PY'
import json
import sys

sha, job, started, finished, status, output = sys.argv[1:]
record = {
    "sha": sha,
    "job": job,
    "started_epoch": float(started),
    "finished_epoch": float(finished),
    "wall_seconds": round(float(finished) - float(started), 3),
    "exit_code": int(status),
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
if [[ "$warmup_status" -ne 0 ]]; then
  echo "warmup failed; inspect $OUT/warmup.log and use https://app.blacksmith.sh" >&2
  exit "$warmup_status"
fi
TBX="$(python3 - "$OUT/warmup.log" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
ids = re.findall(r"\btbx_[A-Za-z0-9_-]+\b", text)
if not ids:
    raise SystemExit("warmup output did not contain a tbx_ ID")
print(ids[-1])
PY
)"
printf 'Testbox ID: %s\n' "$TBX" | tee "$OUT/testbox-id.txt"

blacksmith testbox status --id "$TBX" --wait --wait-timeout 15m \
  2>&1 | tee "$OUT/status-ready.log"
blacksmith testbox run --id "$TBX" --debug \
  'set -euo pipefail; printf "remote_sha="; git rev-parse HEAD; printf "runner="; uname -a; printf "cpus="; nproc; rustup show active-toolchain; rustc --version; cargo --version; "$CMUX_ZIG" version' \
  2>&1 | tee "$OUT/identity.run.log"
```

The warmup transcript is the source for the warmup ID and the GitHub job/run
IDs. Preserve it verbatim. Do not substitute a branch name for `SHA`: the
checkout guard and the evidence file are intended to prove the exact 40-byte
revision tested.

## Three remote build timings

The helper creates a structured JSON record, a raw Cargo log, and the raw
`/usr/bin/time -p` output for each stage. Its environment guard prevents a
local accidental launch.

```bash
run_stage() {
  local stage="$1"
  set +e
  blacksmith testbox run --id "$TBX" --debug \
    "CMUX_TESTBOX_REMOTE=1 ./scripts/blacksmith-cmux-tui-testbox-stage.sh $stage" \
    2>&1 | tee "$OUT/$stage.run.log"
  local status=${PIPESTATUS[0]}
  set -e
  return "$status"
}

benchmark_status=0
for stage in first-clean incremental-noop changed-file; do
  if ! run_stage "$stage"; then
    benchmark_status=1
    break
  fi
done

mkdir -p "$OUT/raw"
blacksmith testbox download --id "$TBX" testbox-benchmark/ "$OUT/raw/" \
  2>&1 | tee "$OUT/download.log"

python3 - "$OUT" "$SHA" "$TBX" <<'PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
sha, testbox_id = sys.argv[2:]
records = []
for path in sorted((out / "raw").glob("*.json")):
    records.append(json.loads(path.read_text(encoding="utf-8")))
with (out / "timings.json").open("w", encoding="utf-8") as handle:
    json.dump({"sha": sha, "testbox_id": testbox_id, "stages": records}, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
exit "$benchmark_status"
```

`first-clean` removes only the remote `cmux-tui/target` directory before a
debug `cargo build -p cmux-tui --locked`. `incremental-noop` repeats that exact
command without changing source. `changed-file` appends a comment to
`cmux-tui/crates/cmux-tui/src/main.rs` immediately before the build, which
changes Cargo's fingerprint, then restores the original bytes before the remote
command exits. The helper holds a remote stage lock so concurrent Testbox run
requests cannot overwrite timing files. The local worktree is never mutated by
the helper.

The local `*.run.log` files include Testbox run IDs and CLI wall time. The
 downloaded `raw/*.json`, `raw/*.log`, and `raw/*.time` files are the remote
 timing evidence. Keep both clocks: CLI wall time includes sync/transport,
while `time_real_seconds` measures the remote Cargo command.

## Historical comparison and cleanup

Record the following alongside `timings.json`:

1. The exact runner label and the output of `blacksmith runners catalog`.
2. The warmup ID, setup job/run ID, and each `blacksmith testbox run` ID from the
   raw transcripts.
3. Any prior hosted cmux-tui timing evidence found under the hq scratch/artifact
   directories. Local Rust timing evidence is intentionally absent because this
   Mac is prohibited from running Rust builds.
4. Whether the comparison was target-clean, registry/git-cache warm, Zig-cache
   warm, or a genuinely cold VM. The setup workflow deliberately warms the
   dependency caches, so `first-clean` is target-cold and dependency-warm.

Prior Blacksmith macOS reload timing artifacts, if used for context, are not a
Rust baseline: they measure a Swift/Xcode build on a different OS, architecture,
runner SKU, cache state, and workload. Hosted cmux-tui correctness runs without
recorded Cargo durations are provenance, not performance comparisons.

Always download before stopping, then stop and verify there is no active box:

```bash
blacksmith testbox stop --id "$TBX"
blacksmith testbox list --all
```

The final list must report no active Testboxes. Keep `warmup.log`, all run
transcripts, `download.log`, `stop.log`, `list-after-stop.log`, and the raw
remote directory in the separate `.cmux-scratch/` evidence artifact.
