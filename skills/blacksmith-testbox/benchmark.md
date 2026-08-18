# cmux-tui Testbox timing plan

Run this plan from the root of the isolated cmux worktree. It never invokes a
Rust tool on the local Mac. Every `cargo`, `rustc`, and `zig` command below is
inside a quoted command passed to `blacksmith testbox run`, or inside the
setup-only GitHub job on the remote Linux runner.

## Fixed lane contract

| Item | Value |
| --- | --- |
| Workflow | `.github/workflows/cmux-tui-testbox-warmup.yml` |
| Job | `cmux-tui-rust` |
| Runner | `blacksmith-32vcpu-ubuntu-2404` |
| Protected environment | `blacksmith-testbox-trusted` |
| Rust source of truth | `cmux-tui/rust-toolchain.toml`, via `./.github/actions/setup-cmux-tui-rust` |
| Remote build helper | `scripts/blacksmith-cmux-tui-testbox-stage.sh` |
| Cleanup helper | `scripts/blacksmith-testbox-cleanup.sh` |
| Remote output | `testbox-benchmark/` |

A repository administrator must configure the protected environment with
required reviewers, no secrets, administrator bypass disabled, and a deployment
branch rule of exactly `main` before this plan is usable. The lane needs no
environment variables: the workflow refuses any ref except `refs/heads/main`,
so `main` alone decides what code runs in the token-bearing job. Verify that
configuration before each run, and stop instead of treating the environment
name as a guard if it drifts.
`begin-testbox` exposes its auth token to commands in the Testbox, so
`contents: read` is not a trust boundary and the token is not sandboxed. The
repository does not currently pin a checksum-verified Blacksmith CLI artifact;
that is a trusted-lane operational limitation. Use only the organization-
approved CLI, record `blacksmith --version`, and stop rather than silently
substituting a version.

The warmup job only checks out `main`, initializes `ghostty`,
installs Linux headers/tools, installs the pinned Zig and Rust toolchains,
fetches Cargo and Zig dependencies, and records JSON identity. `zig build
--fetch` is the only build-system operation in warmup, and it exits before
compiling. Rust builds happen only in the three explicit benchmark runs.

The current Blacksmith catalog reports the requested x64 label as 32 vCPU and
121.6 GB, while the ARM label with the same vCPU count reports 96 GB. Keep the
requested `blacksmith-32vcpu-ubuntu-2404` label unless repository Linux
constraints make x64 impossible, and record the catalog result with the run.

## Exact benchmarked source and Ghostty identity

Warmup hydrates `main`. This section pins the separate commit you benchmark,
which `blacksmith testbox run` synchronizes onto the warm box. A raw commit SHA
is not a supported warmup ref (HTTP 422, `No ref found`), and this lane accepts
only `main` regardless. Carry the benchmarked SHA as an assertion:

```bash
set -euo pipefail
git submodule update --init ghostty
cd "$(git rev-parse --show-toplevel)"
SOURCE_REF="$(git symbolic-ref --short HEAD)"
if [[ ! "$SOURCE_REF" =~ ^[A-Za-z0-9._/-]+$ || "$SOURCE_REF" == *..* || "$SOURCE_REF" == */ || "$SOURCE_REF" == *//* ]]; then
  echo "HEAD must name a supported pushed branch ref" >&2
  exit 1
fi
SOURCE_SHA="$(git rev-parse HEAD)"
SOURCE_TREE_SHA="$(git rev-parse 'HEAD^{tree}')"
ghostty_entry="$(git ls-tree HEAD ghostty)"
[[ "$ghostty_entry" =~ ^160000[[:space:]]commit[[:space:]][0-9a-f]{40}[[:space:]]ghostty$ ]] || {
  echo "HEAD:ghostty is not a gitlink" >&2
  exit 1
}
GHOSTTY_SHA="$(git rev-parse HEAD:ghostty)"
[[ -n "$SOURCE_REF" ]]
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$GHOSTTY_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$(git -C ghostty rev-parse HEAD)" == "$GHOSTTY_SHA" ]]
[[ -z "$(git status --porcelain=v1 --untracked-files=normal)" ]]
[[ -z "$(git -C ghostty status --porcelain=v1 --untracked-files=normal)" ]]
remote_sha="$(git ls-remote --exit-code origin "refs/heads/$SOURCE_REF" | awk 'NR == 1 { print $1 }')"
[[ "$remote_sha" == "$SOURCE_SHA" ]] || {
  echo "push the exact clean branch head before warming Testbox" >&2
  exit 1
}
EVIDENCE_ROOT="$PWD/.cmux-scratch"
# Every evidence directory is blacksmith-testbox-<sha>-<suffix>, so test the
# glob, not the bare name. The bare name never matched, so a second run of the
# same SHA from the same PID collided instead of getting a timestamp.
if compgen -G "$EVIDENCE_ROOT/blacksmith-testbox-$SOURCE_SHA-*" >/dev/null; then
  RUN_SUFFIX="$(date -u +%Y%m%dT%H%M%SZ)-$$"
else
  RUN_SUFFIX="initial-$$"
fi
OUT_ROOT="$EVIDENCE_ROOT/blacksmith-testbox-$SOURCE_SHA-$RUN_SUFFIX"
if [[ -e "$OUT_ROOT" ]]; then
  echo "evidence directory already exists; choose a new run path: $OUT_ROOT" >&2
  exit 1
fi
mkdir -p "$OUT_ROOT/raw"
python3 - "$SOURCE_REF" "$SOURCE_SHA" "$SOURCE_TREE_SHA" "$GHOSTTY_SHA" > "$OUT_ROOT/source.json" <<'PY'
import json
import sys

ref, sha, tree, ghostty = sys.argv[1:]
print(json.dumps({
    "source_ref": ref,
    "source_sha": sha,
    "source_tree_sha": tree,
    "ghostty_gitlink_sha": ghostty,
}, indent=2, sort_keys=True))
PY

assert_source_unchanged() {
  local current_ref current_sha current_tree current_ghostty remote_sha ghostty_entry
  current_ref="$(git symbolic-ref --short HEAD)"
  current_sha="$(git rev-parse HEAD)"
  current_tree="$(git rev-parse 'HEAD^{tree}')"
  ghostty_entry="$(git ls-tree HEAD ghostty)"
  current_ghostty="$(git rev-parse HEAD:ghostty)"
  remote_sha="$(git ls-remote --exit-code origin "refs/heads/$SOURCE_REF" | awk 'NR == 1 { print $1 }')"
  if [[ "$current_ref" != "$SOURCE_REF" || "$current_sha" != "$SOURCE_SHA" ||
        "$current_tree" != "$SOURCE_TREE_SHA" || "$current_ghostty" != "$GHOSTTY_SHA" ||
        ! "$ghostty_entry" =~ ^160000[[:space:]]commit[[:space:]][0-9a-f]{40}[[:space:]]ghostty$ ||
        "$remote_sha" != "$SOURCE_SHA" ||
        -n "$(git status --porcelain=v1 --untracked-files=normal)" ||
        -n "$(git -C ghostty status --porcelain=v1 --untracked-files=normal)" ]]; then
    echo "source branch, tree, Ghostty gitlink, remote head, or clean status changed" >&2
    return 1
  fi
}
assert_source_unchanged
```

`assert_source_unchanged` runs before every stage below. If the branch moved,
the worktree became dirty, or the Ghostty pointer changed, stop the box and
start a new evidence directory. Do not silently substitute the new SHA.

## Warmup and setup identity

Warm from `main`. The lane refuses every other ref, and a raw SHA is not a
supported warmup ref. Your benchmarked branch never appears here; it reaches the
box later, through the pin step.

**Then approve the deployment gate, before you wait.** The run parks at the
`blacksmith-testbox-trusted` environment gate before its first step, so the
`status --wait` below simply times out after 15 minutes if nothing approves it.
Use the `DISPATCH_EPOCH`-guarded approval in `SKILL.md` Step 3, which binds to a
run created after your own dispatch and refuses when more than one is waiting.
Never approve `workflow_runs[0]`: every run in this lane shares a title and a
`main` head branch, so the newest waiting run may belong to another operator.

Write every approval attempt to its own `$OUT/approval-attempt-<n>.json` and
never overwrite. A retry that clobbers the first attempt leaves a pack that
looks like a clean single-approval run, hiding the fact that a box was live and
unapproved in between.

```bash
WORKFLOW=.github/workflows/cmux-tui-testbox-warmup.yml
JOB=cmux-tui-rust
OUT_ROOT="${OUT_ROOT:?set by the exact-source preflight above}"
OUT="$OUT_ROOT"
TBX=""
warmup_testbox_id=""
cleanup_token=""
before_list_status=125
mkdir -p "$OUT/raw"
cleanup() {
  local result=$?
  local cleanup_status=0
  local after_list_status=125
  trap - EXIT
  if [[ -n "$TBX" && -n "$cleanup_token" && -n "${CONFIRM_TESTBOX_STOP_SHA:-}" ]]; then
    set +e
    scripts/blacksmith-testbox-cleanup.sh "$TBX" "$OUT" "$cleanup_token" "STOP:${CONFIRM_TESTBOX_STOP_SHA}"
    cleanup_status=$?
    set -e
  else
    # Without the CLI receipt there is no proof that a newly listed box belongs
    # to this invocation. Report inventory, but never stop another operator's box.
    set +e
    ./scripts/blacksmith-bounded-command.sh 60 \
      blacksmith testbox list --all >"$OUT/list-at-exit.log" 2>&1
    after_list_status=$?
    set -e
    if (( after_list_status != 0 )); then
      cleanup_status="$after_list_status"
      echo "could not capture post-failure Testbox inventory" >&2
    else
      cleanup_status=1
      # Say which of the two conditions actually held. Reporting "no receipt"
      # when the receipt exists sends the operator hunting for the wrong thing,
      # and the usual cause is simply that no stop was ever authorized.
      if [[ -z "${TBX:-}" ]]; then
        echo "no Testbox was created; nothing to stop" >&2
      elif [[ -z "${CONFIRM_TESTBOX_STOP_SHA:-}" ]]; then
        echo "Testbox ${TBX} is still running; no stop was authorized, so stop it yourself with the PREVIEW then STOP ceremony" >&2
      else
        echo "no owned Testbox receipt; refusing to stop a box this run cannot prove it owns" >&2
      fi
    fi
  fi
  if (( result == 0 && cleanup_status != 0 )) && [[ -n "${CONFIRM_TESTBOX_STOP_SHA:-}" ]]; then
    result="$cleanup_status"
  fi
  exit "$result"
}
trap cleanup EXIT
blacksmith auth whoami 2>&1 | tee "$OUT/whoami.txt"   # whoami writes to stderr
blacksmith --version >"$OUT/blacksmith-version.txt"
cat "$OUT/blacksmith-version.txt"
blacksmith runners catalog >"$OUT/runner-catalog.json"
set +e
./scripts/blacksmith-bounded-command.sh 60 \
  blacksmith testbox list --all >"$OUT/list-before-warmup.log" 2>&1
before_list_status=$?
set -e
cat "$OUT/list-before-warmup.log"
if (( before_list_status != 0 )); then
  echo "refusing to warm a Testbox without a baseline inventory" >&2
  exit "$before_list_status"
fi
set +e
./scripts/blacksmith-bounded-command.sh 1200 \
  blacksmith testbox warmup "$WORKFLOW" \
  --ref main \
  --job "$JOB" \
  --idle-timeout 30 \
  >"$OUT/warmup.log" 2>&1
warmup_status=$?
set -e
cat "$OUT/warmup.log"
if (( warmup_status != 0 )); then
  # Do not parse IDs from a failed CLI transcript. It may contain a stale ID
  # from an error message, and cleanup is intentionally receipt-bound.
  exit "$warmup_status"
fi
set +e
warmup_testbox_id="$(python3 - "$OUT/warmup.log" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
ids = re.findall(r"\btbx_[A-Za-z0-9_-]+\b", text)
if not ids:
    raise SystemExit("warmup output did not contain a Testbox ID")
print(ids[-1])
PY
)"
parse_status=$?
set -e
if (( parse_status != 0 )); then
  exit "$parse_status"
fi
umask 077
set +e
cleanup_token="$(python3 - "$OUT/testbox-receipt.json" "$warmup_testbox_id" "$WORKFLOW" "$JOB" main "$SOURCE_REF" "$SOURCE_SHA" "$SOURCE_TREE_SHA" "$GHOSTTY_SHA" <<'PY'
import datetime as dt
import json
import pathlib
import secrets
import sys

path, testbox_id, workflow, job, warmup_ref, source_ref, source_sha, source_tree, ghostty_sha = sys.argv[1:]
token = secrets.token_hex(16)
path = pathlib.Path(path)
path.write_text(json.dumps({
    "schema": 2,
    "testbox_id": testbox_id,
    "workflow": workflow,
    "job": job,
    # What the inventory shows, always main in the broker lane.
    "warmup_ref": warmup_ref,
    # The branch being benchmarked, which never appears in the inventory.
    "source_ref": source_ref,
    "source_sha": source_sha,
    "source_tree_sha": source_tree,
    "ghostty_gitlink_sha": ghostty_sha,
    "confirmation_token": token,
    "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
path.chmod(0o600)
print(token)
PY
)"
receipt_status=$?
set -e
if (( receipt_status != 0 )); then
  echo "could not create the warmup ownership receipt" >&2
  exit "$receipt_status"
fi
TBX="$warmup_testbox_id"
printf 'Testbox ID: %s\n' "$TBX" | tee "$OUT/testbox-id.txt"
if (( warmup_status != 0 )); then
  exit "$warmup_status"
fi
set +e
blacksmith testbox status --id "$TBX" --wait --wait-timeout 15m \
  >"$OUT/status-ready.log" 2>&1
status_ready=$?
set -e
cat "$OUT/status-ready.log"
if (( status_ready != 0 )); then
  exit "$status_ready"
fi
```

The workflow refuses any dispatch ref except `refs/heads/main`, and it repeats
that check after `begin-testbox` so a ref that changed during reviewer approval
fails closed. `testbox_id` is the only input, so no caller can steer the job at
a different revision, and `main` alone decides what code runs beside the auth
token.
The workflow concurrency group serializes setup requests by Testbox ID, even
when source SHAs differ. The remote `flock` begins after Blacksmith's rsync, so
it protects stage/build/artifact writes only. Blacksmith exposes no pre-rsync
lease; one Testbox ID must have one owning worktree/operator, and independent
clients must not issue concurrent `run` or download commands. This is an
explicit trusted-lane limitation.

Do not issue a separate interpolated identity command. The setup job's
`setup-identity.json` artifact and each stage helper's pre-build JSON record are
the identity transcripts. They describe different commits on purpose: the setup
artifact names the hydrated `main`, and the stage record names the benchmarked
revision you synchronized. The helper verifies the Testbox VM marker, claimed
Testbox ID, the hydration marker's own internal consistency and runner class,
and then the synchronized source commit/tree, Ghostty gitlink/checkout, and
clean status before it invokes Cargo, repeating the source checks after the
build. Each stage JSON carries a `hydration` block with the warmed ref and
commit plus `matches_benchmarked_source`, which is normally `false`. Keep the
setup artifact URL or download it into `$OUT`. The workflow uploads it under the
name `cmux-tui-testbox-setup-<run-id>`, so with the approved run's ID in `$RUN_ID`:
`gh run download "$RUN_ID" --repo manaflow-ai/cmux --name "cmux-tui-testbox-setup-$RUN_ID" --dir "$OUT/setup-artifact"`.
A successful setup copies the
same JSON to `/tmp/.testbox/cmux-tui-rust-setup-identity.json`; the stage helper
rejects a missing or malformed marker, so failed hydration cannot be
benchmarked. The active Rust, Cargo, and Zig versions must still equal the
hydrated ones, so a branch that repins its toolchain stops the run instead of
reporting a cold-cache timing.

## Pin the box, then take the three timings

Pin the box to the benchmarked commit once, after readiness and before the
first stage. `blacksmith testbox run` synchronizes file contents rather than
history, and skips even that once fingerprints match, so the box otherwise keeps
the `main` checkout the warmup job made:

```bash
./scripts/blacksmith-bounded-command.sh 300 \
  blacksmith testbox run --id "$TBX" \
  "set -euo pipefail; git fetch --no-tags origin $SOURCE_SHA; git reset --hard $SOURCE_SHA; git submodule update --init --depth 1 ghostty; git rev-parse HEAD" \
  >"$OUT/pin-source.log" 2>&1
cat "$OUT/pin-source.log"
```

The commit must already be pushed. A local-only commit fails on the box with
`upload-pack: not our ref`, and the stage helper refuses rather than
benchmarking `main` under a candidate's name.

The warmup job only ever checks out `main`, so this pin is what makes the box an
exact checkout of the revision you are benchmarking. Do it before the stage loop
below. Running the loop first measures `main`, not your branch.

## Three remote build timings

The helper creates one structured JSON record, one raw Cargo log, and one raw
`/usr/bin/time -p` file per stage. Each remote Cargo build is bounded to 20
minutes with a 30-second kill grace period, and the outer CLI invocation is
bounded to 25 minutes so rsync, SSH, or control-plane hangs cannot bypass the
benchmark's cleanup path. It verifies source and submodule identity before the
stage, exports and records the exact Zig binary used by Cargo, holds a remote
`flock` through all writes, restores the controlled changed file from an
integrity-checked backup, and verifies clean identity again.

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
  # The second clock. The stage record's wall_seconds is measured on the box
  # around cargo; this one includes sync, transport, and queueing, and the gap
  # between them is the Testbox overhead.
  cli_start="$(python3 -c 'import time; print(time.time())')"
  ./scripts/blacksmith-bounded-command.sh 1500 blacksmith testbox run --id "$TBX" --debug \
    "$remote_command" >"$OUT/$stage.run.log" 2>&1
  run_status=$?
  set -e
  python3 -c "import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 3))" \
    "$cli_start" "$(python3 -c 'import time; print(time.time())')" >"$OUT/$stage.cli-wall.txt"
  cat "$OUT/$stage.run.log"

  # rsync --delete can remove remote output before the next run. Download each
  # stage immediately, before starting another stage.
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

benchmark_status=0
for stage in first-clean incremental-noop changed-file; do
  if ! assert_source_unchanged; then
    benchmark_status=1
    break
  fi
  if ! run_stage "$stage"; then
    benchmark_status=1
    break
  fi
done
if (( benchmark_status != 0 )); then
  exit "$benchmark_status"
fi
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
    runner = record.get("runner", {})
    if runner.get("arch") != "x86_64" or runner.get("cpu_count") != 32:
        raise SystemExit(f"{stage}: wrong runner identity {runner}")
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
    json.dump({"schema": 2, "stage_record_schema": 3, "source_sha": expected_source, "ghostty_gitlink_sha": expected_ghostty, "testbox_id": testbox_id, "stages": records}, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
```

## Cleanup and evidence

Download all raw files and `timings.json` before cleanup. Then, after an
operator explicitly decides this exact box may be destroyed, call the fail-safe
helper. It previews the exact receipt context, preserves an already-completed
409, polls cancellation to a bounded deadline, fails on other stop/status/list
errors, and verifies this exact Testbox ID is no longer active:

```bash
cleanup_token="${cleanup_token:-}"
[[ "$cleanup_token" =~ ^[0-9a-f]{32}$ ]] || {
  echo "use the confirmation token emitted by the warmup receipt" >&2
  exit 64
}
# PREVIEW exits 75 on success, meaning "preview written, nothing destroyed
# yet". Run it outside `set -e`, which this plan otherwise enables, or it aborts
# the orchestration immediately before cleanup.
set +e
scripts/blacksmith-testbox-cleanup.sh "$TBX" "$OUT" "$cleanup_token" PREVIEW
preview_status=$?
set -e
(( preview_status == 75 )) || { echo "cleanup preview failed with $preview_status" >&2; exit "$preview_status"; }
# Review cleanup-preview.json, then rerun with STOP:<sha256(cleanup-preview.json)>.
```

A shell `EXIT` trap may call that helper only when an independent operator has
exported `CONFIRM_TESTBOX_STOP_SHA` with the SHA-256 of a separately reviewed
`cleanup-preview.json`; otherwise it preserves the benchmark status, records
inventory, and leaves the box for explicit manual cleanup.
Warmup writes `testbox-receipt.json` and an ownership token bound to the exact
returned ID; cleanup refuses a mismatched ID or token. If warmup fails before
returning an ID, retain before/after inventories but do not automatically stop a
box, because an inventory diff cannot prove ownership across concurrent
operators. Reconcile that orphan manually through the
Blacksmith control plane. Keep both inventories and their command statuses,
plus warmup/status/identity transcripts, every stage run and download
transcript, raw JSON/time/log files, runner catalog, setup identity artifact,
cleanup logs, the receipt, and the final source manifest in the new, unique
`.cmux-scratch/` directory. Never reuse a prior SHA-only directory or overwrite
historical records. Never store credentials, private keys, or
`/tmp/.testbox/auth_token`.

Record these fields alongside `timings.json`:

1. Exact source branch, full source SHA/tree SHA, Ghostty gitlink SHA, and the
   clean-status result before each stage.
2. Requested runner label and catalog output. The setup job rejects any
   actual architecture or CPU count other than x64 and 32.
3. Blacksmith CLI version, Testbox ID, and the setup workflow run and job IDs.
   There is no separate identity run: this plan forbids issuing one, and the
   identity transcripts are the setup artifact plus each stage's own record.
4. Whether the comparison was target-clean, registry/git-cache warm,
   Zig-cache warm, or a genuinely cold VM. Warmup deliberately hydrates
   dependencies, so `first-clean` is target-cold and dependency-warm.
5. Cleanup stop/status/list output and whether the specific ID was absent from
   the active inventory.

Never write into an evidence directory you did not create in this run. The
`-e "$OUT_ROOT"` check above is that guard: if the path exists, stop and choose a
new run suffix rather than merging two runs' records into one pack.

Prior hosted cmux-tui correctness runs without Cargo durations are provenance,
not performance comparisons. Prior Blacksmith macOS Swift/Xcode artifacts use
a different OS, architecture, runner SKU, cache state, and workload, so they
are context rather than a Rust baseline.
