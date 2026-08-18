# Testbox operations reference

Long-form detail for `skills/blacksmith-testbox/SKILL.md`: the stage
orchestration loop, the receipt-bound cleanup ceremony, and how to read the two
clocks a run produces. The full evidence-producing plan lives in
`benchmark.md`.

## Remote benchmark stages

The detailed, receipt-producing orchestration in `benchmark.md` is the required
entry point for a complete benchmark. It creates the unique `OUT_ROOT`, receipt,
cleanup token, setup artifact capture, and cleanup preview state. Do not copy
only this stage loop into an ad hoc shell without those prerequisites.

Before each stage, recompute `SOURCE_SHA` and `GHOSTTY_SHA` and repeat the
clean pushed-branch preflight.
Pass the expected values as validated arguments;
the helper does not trust the remote checkout or a caller-supplied expected SHA
without comparing it to Git metadata:

```bash
# Run this orchestration block in Bash, not an interactive zsh session.
run_stage() {
  local stage="$1"
  local run_status download_status=0
  set +e
  printf -v remote_command \
    'CMUX_TESTBOX_REMOTE=1 CMUX_TESTBOX_ID=%q %q %q %q %q' \
    "$TBX" ./scripts/blacksmith-cmux-tui-testbox-stage.sh \
    "$stage" "$SOURCE_SHA" "$GHOSTTY_SHA"
  ./scripts/blacksmith-bounded-command.sh 1500 \
    blacksmith testbox run --id "$TBX" --debug \
    "$remote_command" >"$OUT/$stage.run.log" 2>&1
  run_status=$?
  set -e
  cat "$OUT/$stage.run.log"

  # Download immediately. Blacksmith's next rsync may delete or replace remote
  # files, so a one-time download after all stages is insufficient.
  : >"$OUT/$stage.download.log"
  for suffix in json time log; do
    if ! ./scripts/blacksmith-bounded-command.sh 120 \
      blacksmith testbox download --id "$TBX" \
      "testbox-benchmark/$stage.$suffix" "$OUT/raw/$stage.$suffix" \
      >>"$OUT/$stage.download.log" 2>&1; then
      download_status=1
    fi
  done
  cat "$OUT/$stage.download.log"
  if (( run_status != 0 )); then
    return "$run_status"
  fi
  return "$download_status"
}
```

The helper supports exactly `first-clean`, `incremental-noop`, and
`changed-file`. Each remote Cargo build is bounded to 20 minutes with a
30-second kill grace period. It records a schema-3 JSON object for each stage
containing:

* expected and observed source commit/tree identity before and after the build;
* expected and observed Ghostty gitlink and initialized submodule HEAD;
* clean/dirty file lists and source restoration status;
* Testbox ID and adopted workflow run ID;
* runner label, hostname, architecture, CPU count, and `uname`; the setup
  workflow fails closed unless the actual runner is x64 with 32 CPUs;
* active Rust toolchain, `rustc`, Cargo, Zig, lockfile/toolchain hashes, and
  Ghostty package-manifest hash; and
* Cargo exit status, `/usr/bin/time -p` values, and CLI transcript timing.

`first-clean` removes only the remote `cmux-tui/target` directory before a
`cargo build -p cmux-tui --locked`. `incremental-noop` repeats that command
without changing source. `changed-file` appends a comment to
`cmux-tui/crates/cmux-tui/src/main.rs`, builds, and restores the original bytes
before emitting its final record. A dirty or mismatched source before any
stage, after restoration, or in the Ghostty submodule aborts the stage.

After all successful downloads, aggregate and verify the records:

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
records = []
for path in sorted((out / "raw").glob("*.json")):
    record = json.loads(path.read_text(encoding="utf-8"))
    records.append(record)
if {record.get("stage") for record in records} != required:
    raise SystemExit("timing evidence is missing one or more benchmark stages")
for record in records:
    if record.get("testbox", {}).get("id") != testbox_id:
        raise SystemExit(f"{record.get('stage')} has the wrong Testbox ID")
    source = record.get("source", {})
    if source.get("expected_commit_sha") != expected_source or source.get("expected_tree_sha") != expected_tree:
        raise SystemExit(f"{record.get('stage')} has the wrong expected source identity")
    for side in ("before", "after"):
        snapshot = source.get(side, {})
        if snapshot.get("commit_sha") != expected_source or snapshot.get("tree_sha") != expected_tree:
            raise SystemExit(f"{record.get('stage')} has the wrong {side} source SHA")
        if snapshot.get("dirty_files"):
            raise SystemExit(f"{record.get('stage')} has dirty top-level source")
        ghostty = snapshot.get("ghostty", {})
        if ghostty.get("gitlink_sha") != expected_ghostty or ghostty.get("head_sha") != expected_ghostty:
            raise SystemExit(f"{record.get('stage')} has mismatched Ghostty identity")
        if ghostty.get("dirty_files"):
            raise SystemExit(f"{record.get('stage')} has dirty Ghostty source")
    if not record.get("ok"):
        raise SystemExit(f"{record.get('stage')} did not complete successfully")
with (out / "timings.json").open("w", encoding="utf-8") as handle:
    json.dump({"schema": 2, "stage_record_schema": 3, "source_sha": expected_source, "ghostty_gitlink_sha": expected_ghostty, "testbox_id": testbox_id, "stages": records}, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
```

Keep `raw/*.json`, `raw/*.time`, `raw/*.log`, every `*.run.log` and download
log, the setup artifact, and the source manifest in a new, unique
`.cmux-scratch/` evidence directory. Never reuse a prior SHA-only directory;
refuse to overwrite historical records. Do not add credentials or private keys.

## Fail-safe cleanup

Always download before cleanup. Use the checked-in cleanup helper rather than
ignoring errors with `|| true`. After an independent operator decides the exact
box may be destroyed, pass the ownership token generated with the warmup receipt
and the literal `STOP`; never print the token:

```bash
CLEANUP_TOKEN="${CLEANUP_TOKEN:-}"
[[ "$CLEANUP_TOKEN" =~ ^[0-9a-f]{32}$ ]] || {
  echo "use the ownership token emitted by the warmup receipt" >&2
  exit 64
}
scripts/blacksmith-testbox-cleanup.sh "$TBX" "$OUT" "$CLEANUP_TOKEN" PREVIEW   # exits 75 on success: preview written, nothing destroyed
# Review cleanup-preview.json, then rerun with STOP:<sha256(cleanup-preview.json)>.
```

It records a pre-stop status preview, stop result, post-stop status, and
`list --all` output. The preview must match the receipt's workflow, job, and
branch before any stop is attempted. Cleanup is destructive and requires a fresh `STOP:<sha256(cleanup-preview.json)>`
confirmation after reviewing the current receipt-bound preview.
It verifies that the specific Testbox ID is terminal or absent from the active
inventory, accepts the known terminal states `completed`, `stopped`, `cancelled`,
`failed`, `terminated`, and `hydration_failed`, plus a 409 saying the box is
already stopped or completed, and polls for up to two minutes while cancellation
propagates. Other stop, status, or list failures remain failures.
Put it in an `EXIT` trap only after an independent operator exports
`CONFIRM_TESTBOX_STOP_SHA` containing the SHA-256 of a separately reviewed
`cleanup-preview.json`; otherwise preserve the benchmark's original exit status
and leave the box for manual cleanup. The detailed benchmark writes a
receipt and ownership token for the exact ID returned by warmup; cleanup refuses an ID
or token that is not bound to that receipt. If warmup fails before returning an
ID, retain before/after inventory but do not automatically stop a box, because
an inventory diff cannot prove ownership across concurrent operators. Reconcile
that orphan manually through the Blacksmith control plane.

## Partial stage sets

The verification and aggregation blocks require all three stages and raise
`SystemExit` on any subset, because a `timings.json` that silently omits a stage
reads as a complete result. Running one or two stages is fine, and common: read
the per-stage `testbox-benchmark/<stage>.json` records directly and do not
produce a `timings.json` at all.

## Timing interpretation

The benchmark reports two clocks, and the stage record contains only one of
them. `wall_seconds` in each stage JSON is measured **on the box**, around the
cargo command, which is why it sits a few milliseconds above the
`/usr/bin/time -p` `real` value rather than well above it. It is not the CLI
clock.

The second clock is local: the wall time of the `blacksmith testbox run`
invocation itself, which also covers sync, transport, and queueing. The plan in
`benchmark.md` writes it to `$OUT/<stage>.cli-wall.txt`. Compare remote `real`
or `time_real_seconds` for build performance, and use the difference between the
local and remote clocks for Testbox overhead. A pack without `cli-wall.txt`
cannot measure overhead at all.

Compare overhead only across `first-clean` and `incremental-noop`. The
`changed-file` gap is several times larger (8.1 s against 1.2 s in one measured
run, with all three stages syncing `strategy=skip`), because that stage's
backup, edit, restore, and re-verify work runs inside the CLI call but outside
`wall_seconds`. Its local-minus-remote figure is real but is not sync and
transport, so do not read it as Testbox overhead.

`first-clean` is target-clean but dependency-warm: warmup runs `cargo fetch` and
`zig build --fetch`, and the workflow may restore registry, git, and Zig caches.
`incremental-noop` measures a second build on the same VM. `changed-file` is a
controlled source change on that same VM. These are deliberately different
from a cold-VM benchmark.

Treat any evidence directory you did not create this run as read-only. Never
select an existing one as a writable `OUT`, and never rewrite its raw records or
cleanup result.

After a stop, `blacksmith testbox status --id <id>` still prints a row reading
`completed` while `list --all` reports no active testboxes. Both are correct:
`status` answers about one ID including terminal ones, and `list` shows only
live boxes. Cite both, and do not read the difference as a failed stop.

The two identity transcripts spell the architecture differently for the same
host: `setup-identity.json` records GitHub's `RUNNER_ARCH` (`X64`), while stage
records use `uname` (`x86_64`). The verification block asserts the `uname`
spelling. This is expected, not a mismatch.

Blacksmith's `CREATED` column is not a creation time. It tracks the last state
transition, so one box reports a different value while hydrating, at ready, and
after stop. For elapsed hydration read the `status --wait` transcript, which
prints the wait duration next to `Testbox ready!`.
