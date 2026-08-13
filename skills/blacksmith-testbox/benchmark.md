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
| Protected environment | `blacksmith-testbox-trusted` |
| Rust source of truth | `cmux-tui/rust-toolchain.toml`, via `./.github/actions/setup-cmux-tui-rust` |
| Remote build helper | `scripts/blacksmith-cmux-tui-testbox-stage.sh` |
| Cleanup helper | `scripts/blacksmith-testbox-cleanup.sh` |
| Remote output | `testbox-benchmark/` |

A repository administrator must configure the protected environment with
required reviewers and no secrets before this plan is usable. The lane must
never run untrusted PR or fork code. `begin-testbox` exposes its auth token to
commands in the Testbox, so `contents: read` is not a trust boundary.

The warmup job only checks out the exact dispatch SHA, initializes `ghostty`,
installs Linux headers/tools, installs the pinned Zig and Rust toolchains,
fetches Cargo and Zig dependencies, and records JSON identity. `zig build
--fetch` is the only build-system operation in warmup, and it exits before
compiling. Rust builds happen only in the three explicit benchmark runs.

The current Blacksmith catalog reports the requested x64 label as 32 vCPU and
121.6 GB, while the ARM label with the same vCPU count reports 96 GB. Keep the
requested `blacksmith-32vcpu-ubuntu-2404` label unless repository Linux
constraints make x64 impossible, and record the catalog result with the run.

## Exact pushed source and Ghostty identity

Blacksmith/GitHub rejected the previous raw-SHA `--ref` with HTTP 422 (`No ref
found`). A raw commit SHA is not a supported warmup ref for this lane. Use a
pushed branch ref and carry the full source SHA as an assertion:

```bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
SOURCE_REF="$(git symbolic-ref --short HEAD)"
SOURCE_SHA="$(git rev-parse HEAD)"
GHOSTTY_SHA="$(git rev-parse HEAD:ghostty)"
[[ -n "$SOURCE_REF" ]]
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$GHOSTTY_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ -z "$(git status --porcelain=v1 --untracked-files=normal)" ]]
remote_sha="$(git ls-remote --exit-code origin "refs/heads/$SOURCE_REF" | awk 'NR == 1 { print $1 }')"
[[ "$remote_sha" == "$SOURCE_SHA" ]] || {
  echo "push the exact clean branch head before warming Testbox" >&2
  exit 1
}
mkdir -p ".cmux-scratch/blacksmith-testbox-$SOURCE_SHA/raw"
python3 - "$SOURCE_REF" "$SOURCE_SHA" "$GHOSTTY_SHA" > ".cmux-scratch/blacksmith-testbox-$SOURCE_SHA/source.json" <<'PY'
import json
import subprocess
import sys

ref, sha, ghostty = sys.argv[1:]
record = {
    "source_ref": ref,
    "source_sha": sha,
    "source_tree_sha": subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], text=True).strip(),
    "ghostty_gitlink_sha": ghostty,
}
print(json.dumps(record, indent=2, sort_keys=True))
PY
```

Before every stage, rerun the clean-branch check and recompute the expected
values. If the branch moved, the worktree became dirty, or the Ghostty pointer
changed, stop the box and start a new evidence directory. Do not silently
substitute the new SHA.

## Warmup and setup identity

Use the branch ref, not `SOURCE_SHA`, in warmup:

```bash
WORKFLOW=.github/workflows/ci-workflow-guard-tests-testbox.yml
JOB=cmux-tui-rust
OUT="$PWD/.cmux-scratch/blacksmith-testbox-$SOURCE_SHA"
TBX=""
mkdir -p "$OUT/raw"
blacksmith auth whoami
blacksmith --version | tee "$OUT/blacksmith-version.txt"
blacksmith runners catalog > "$OUT/runner-catalog.json"
blacksmith testbox warmup "$WORKFLOW" \
  --ref "$SOURCE_REF" \
  --job "$JOB" \
  --idle-timeout 30 \
  2>&1 | tee "$OUT/warmup.log"
TBX="$(python3 - "$OUT/warmup.log" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
ids = re.findall(r"\btbx_[A-Za-z0-9_-]+\b", text)
if not ids:
    raise SystemExit("warmup output did not contain a Testbox ID")
print(ids[-1])
PY
)"
printf 'Testbox ID: %s\n' "$TBX" | tee "$OUT/testbox-id.txt"
blacksmith testbox status --id "$TBX" --wait --wait-timeout 15m \
  2>&1 | tee "$OUT/status-ready.log"
```

The workflow validates that the dispatch ref is a pushed branch, that
`github.sha` is a full SHA, and that the branch still resolves to that SHA. If
a direct GitHub dispatch supplies the optional `source_sha` input, it must equal
`github.sha`. The Blacksmith CLI path relies on the same full SHA passed to the
remote helper because the CLI only supplies `testbox_id` to workflow inputs.

Capture a harmless remote identity transcript before builds:

```bash
blacksmith testbox run --id "$TBX" --debug \
  "set -euo pipefail; test -s /tmp/.testbox/auth_token; grep -Eq '(^|[[:space:]])metadata_port=[^[:space:]]+' /proc/cmdline; test \"\$(git rev-parse HEAD)\" = \"$SOURCE_SHA\"; test \"\$(git rev-parse HEAD:ghostty)\" = \"$GHOSTTY_SHA\"; test \"\$(git -C ghostty rev-parse HEAD)\" = \"$GHOSTTY_SHA\"; test -z \"\$(git status --porcelain=v1 --untracked-files=normal)\"; test -z \"\$(git -C ghostty status --porcelain=v1 --untracked-files=normal)\"; rustup show active-toolchain; rustc --version; cargo --version; \"$CMUX_ZIG\" version" \
  2>&1 | tee "$OUT/identity.run.log"
```

The setup job's `setup-identity.json` is uploaded as a GitHub artifact. Keep
its artifact URL or download it into `$OUT`; it records runner/toolchain/
Ghostty identity independently of the stage helper.

## Three remote build timings

The helper creates one structured JSON record, one raw Cargo log, and one raw
`/usr/bin/time -p` file per stage. It verifies source and submodule identity
before the stage, holds a remote `flock` through all writes, restores the
controlled changed file, and verifies clean identity again.

```bash
run_stage() {
  local stage="$1"
  local run_status download_status=0
  set +e
  blacksmith testbox run --id "$TBX" --debug \
    "CMUX_TESTBOX_REMOTE=1 CMUX_TESTBOX_ID=$TBX CMUX_TESTBOX_SOURCE_REF=$SOURCE_REF ./scripts/blacksmith-cmux-tui-testbox-stage.sh $stage $SOURCE_SHA $GHOSTTY_SHA" \
    2>&1 | tee "$OUT/$stage.run.log"
  run_status=${PIPESTATUS[0]}
  set -e

  # rsync --delete can remove remote output before the next run. Download each
  # stage immediately, before starting another stage.
  for suffix in json time log; do
    if ! blacksmith testbox download --id "$TBX" \
      "testbox-benchmark/$stage.$suffix" "$OUT/raw/$stage.$suffix" \
      2>&1 | tee -a "$OUT/$stage.download.log"; then
      download_status=1
    fi
  done
  if (( run_status != 0 )); then
    return "$run_status"
  fi
  return "$download_status"
}

benchmark_status=0
for stage in first-clean incremental-noop changed-file; do
  if ! run_stage "$stage"; then
    benchmark_status=1
    break
  fi
done
```

`first-clean` is target-clean but dependency-warm. `incremental-noop` repeats
the exact build on the same VM. `changed-file` appends a comment to
`cmux-tui/crates/cmux-tui/src/main.rs`, builds, and restores the original bytes.
The local worktree is never mutated by the helper.

Verify the downloaded records before accepting timings:

```bash
python3 - "$OUT" "$SOURCE_SHA" "$GHOSTTY_SHA" "$TBX" <<'PY'
import json
import pathlib
import subprocess
import sys

out = pathlib.Path(sys.argv[1])
expected_source, expected_ghostty, testbox_id = sys.argv[2:]
expected_tree = subprocess.check_output(
    ["git", "rev-parse", f"{expected_source}^{{tree}}"], text=True
).strip()
required = {"first-clean", "incremental-noop", "changed-file"}
records = [json.loads(path.read_text(encoding="utf-8")) for path in sorted((out / "raw").glob("*.json"))]
if {record.get("stage") for record in records} != required:
    raise SystemExit("expected exactly three stage records")
for record in records:
    stage = record.get("stage")
    if record.get("testbox", {}).get("id") != testbox_id:
        raise SystemExit(f"{stage}: wrong Testbox ID")
    source_record = record.get("source", {})
    if source_record.get("expected_commit_sha") != expected_source or source_record.get("expected_tree_sha") != expected_tree:
        raise SystemExit(f"{stage}: wrong expected source identity")
    for side in ("before", "after"):
        source = source_record.get(side, {})
        if source.get("commit_sha") != expected_source or source.get("tree_sha") != expected_tree or source.get("dirty_files"):
            raise SystemExit(f"{stage}: source mismatch or dirty {side} checkout")
        ghostty = source.get("ghostty", {})
        if ghostty.get("gitlink_sha") != expected_ghostty or ghostty.get("head_sha") != expected_ghostty or ghostty.get("dirty_files"):
            raise SystemExit(f"{stage}: Ghostty mismatch or dirty {side} checkout")
    if not record.get("ok"):
        raise SystemExit(f"{stage}: build failed")
with (out / "timings.json").open("w", encoding="utf-8") as handle:
    json.dump({"schema": 2, "source_sha": expected_source, "ghostty_gitlink_sha": expected_ghostty, "testbox_id": testbox_id, "stages": records}, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
```

## Cleanup and evidence

Download all raw files and `timings.json` before cleanup. Then call the
fail-safe helper, which preserves an already-completed 409 but fails on other
stop/status/list errors and verifies this exact Testbox ID is no longer active:

```bash
scripts/blacksmith-testbox-cleanup.sh "$TBX" "$OUT"
```

A shell `EXIT` trap should call that helper while preserving the benchmark
status. If warmup did not return a Testbox ID, still run
`blacksmith testbox list --all` and save its output. Keep warmup/status/identity
transcripts, every stage run and download transcript, raw JSON/time/log files,
runner catalog, setup identity artifact, cleanup logs, and the final source
manifest in the separate `.cmux-scratch/` directory. Never store credentials,
private keys, or `/tmp/.testbox/auth_token`.

Record these fields alongside `timings.json`:

1. Exact source branch, full source SHA/tree SHA, Ghostty gitlink SHA, and the
   clean-status result before each stage.
2. Requested runner label and catalog output.
3. Blacksmith CLI version, Testbox ID, setup workflow run/job IDs, identity run
   ID, and each stage run/sync ID from raw transcripts.
4. Whether the comparison was target-clean, registry/git-cache warm,
   Zig-cache warm, or a genuinely cold VM. Warmup deliberately hydrates
   dependencies, so `first-clean` is target-cold and dependency-warm.
5. Cleanup stop/status/list output and whether the specific ID was absent from
   the active inventory.

The historical 32-vCPU evidence at
`.cmux-scratch/blacksmith-testbox-e40704611ac35f4ffa153/` remains unchanged:
setup SHA `e40704611ac35f0e3a806841a9eae383f4ffa153`, Testbox
`tbx_01kzxebn91nhatkv4ygevh06vs`, workflow run `31696013711`, first-clean
`161.47s`, incremental no-op `8.28s`, changed-file `9.13s`, and cleanup with no
active box. Do not rewrite it while validating this hardening change.

Prior hosted cmux-tui correctness runs without Cargo durations are provenance,
not performance comparisons. Prior Blacksmith macOS Swift/Xcode artifacts use
a different OS, architecture, runner SKU, cache state, and workload, so they
are context rather than a Rust baseline.
