---
name: blacksmith-testbox
description: >
  Provision and reuse a trusted Blacksmith Testbox for cmux-tui Rust builds,
  capture remote timings, download raw evidence, and clean up safely. Never run
  cargo, rustc, or Zig builds on the local Mac.
---

# cmux-tui Blacksmith Testbox

This lane is Linux-only. It uses
`.github/workflows/ci-workflow-guard-tests-testbox.yml`, job
`cmux-tui-rust`, on `blacksmith-32vcpu-ubuntu-2404`. The workflow is a
setup-only entrypoint for a reusable Testbox. It validates a pushed branch
ref, checks out and verifies the exact dispatch commit, initializes the
`ghostty` source submodule, installs Linux C/LLVM headers, installs the
repository-pinned Zig and Rust toolchains, fetches Zig and Cargo dependencies,
records runner/toolchain/Ghostty identity in JSON, and then hands control back
to Testbox. It does not run Rust tests or Rust compilation during warmup.
`zig build --fetch` only hydrates Zig packages and exits before compilation.

The repository's single Rust toolchain source is
`cmux-tui/rust-toolchain.toml`. The workflow invokes
`./.github/actions/setup-cmux-tui-rust`, so a workflow-specific Rust version
must never be added.

## Hard safety and trust boundary

This is a trusted-maintainer lane, not a pull-request validation lane.
`useblacksmith/begin-testbox` writes `/tmp/.testbox/auth_token` into the
candidate command environment. Any command run through `blacksmith testbox
run` can read that token and can inspect anything else exposed to the GitHub
job. `permissions: contents: read` does not prevent token access, and this
workflow intentionally grants no other GitHub permissions or workflow secrets.

Before using the lane, a repository administrator must create the
`blacksmith-testbox-trusted` GitHub environment, configure required reviewers
(or an equivalent manual approval rule), and leave the environment secret set
empty. GitHub evaluates that approval before the job's first step, including
`begin-testbox`. If the environment does not exist or has no required reviewer,
stop: the lane is not production-safe. Never dispatch it for an untrusted PR,
fork, branch containing unreviewed workflow/helper changes, or source supplied
by an external contributor. When trust changes, stop the old box and warm a
fresh one.

The helper retains the `CMUX_TESTBOX_REMOTE=1` guard for accidental local
launches, and additionally requires the Blacksmith VM kernel metadata marker
and matching `/tmp/.testbox` state. The environment flag remains caller
controlled and is not an authentication mechanism. The protected environment
and trusted-maintainer policy are the security boundary.

* Never run `cargo`, `rustc`, `rustup`, `zig build`, or another Rust/Zig build
  command on Lawrence's Mac. This includes local fallback builds and local
  test commands.
* Run every Blacksmith CLI command from the root of the intended isolated
  worktree. The CLI synchronizes that directory with `rsync --delete`; it can
  delete remote files that are not represented locally.
* Put remote build commands inside `blacksmith testbox run`. The benchmark
  helper also requires the Testbox VM guard, so an accidental local launch
  exits before invoking a compiler.
* Use this Testbox only for Linux-compatible cmux-tui work. Use hosted macOS
  workflows for Swift, Xcode, XCTest, GUI, and app-host verification.

## Authentication and CLI installation

Check authentication without printing credentials:

```bash
blacksmith auth whoami
blacksmith --version
```

Use the repository or organization-approved, pinned Blacksmith CLI artifact or
package-manager version. Record its version in the evidence. Do not install a
mutable remote script with `curl ... | sh`; if the approved pinned artifact is
not available, stop and ask the tooling owner rather than weakening this lane.

## Exact source contract

Blacksmith/GitHub rejected the previous raw-SHA warmup with HTTP 422 (`No ref
found`). Do not pass a commit SHA to `blacksmith testbox warmup --ref`, and do
not document raw SHA refs as supported. Warm up a pushed branch ref, then carry
the full SHA separately and assert it remotely.

Run this preflight from the clean worktree root:

```bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
SOURCE_REF="$(git symbolic-ref --short HEAD)"
[[ -n "$SOURCE_REF" ]] || { echo "HEAD is detached" >&2; exit 1; }
SOURCE_SHA="$(git rev-parse HEAD)"
GHOSTTY_SHA="$(git rev-parse HEAD:ghostty)"
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$GHOSTTY_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ -z "$(git status --porcelain=v1 --untracked-files=normal)" ]]
remote_sha="$(git ls-remote --exit-code origin "refs/heads/$SOURCE_REF" | awk 'NR == 1 { print $1 }')"
[[ "$remote_sha" == "$SOURCE_SHA" ]] || {
  echo "the pushed branch is not the exact local HEAD" >&2
  exit 1
}
printf 'source_ref=%s\nsource_sha=%s\nghostty_gitlink_sha=%s\n' \
  "$SOURCE_REF" "$SOURCE_SHA" "$GHOSTTY_SHA"
```

The branch can move after this check. Every remote stage rechecks the full
source SHA, commit tree, GitHub `ghostty` gitlink, initialized Ghostty HEAD,
and clean status before building. A moved branch or dirty/mismatched checkout
fails closed; do not silently warm another revision.

The workflow has an optional `source_sha` workflow-dispatch input for a direct
GitHub dispatch. The Blacksmith CLI supplies `testbox_id` but does not expose
arbitrary workflow inputs, so the normal CLI path uses `github.sha` plus the
remote assertion in the helper. A supplied `source_sha` must be a lowercase
40-character SHA equal to the branch dispatch SHA.

## Warmup and identity capture

Warm the validated branch, never its SHA:

```bash
WORKFLOW=.github/workflows/ci-workflow-guard-tests-testbox.yml
JOB=cmux-tui-rust
blacksmith testbox warmup "$WORKFLOW" \
  --ref "$SOURCE_REF" \
  --job "$JOB" \
  --idle-timeout 30
```

Save the returned `tbx_...` ID. One ID belongs to one worktree and one trust
context. The workflow concurrency group keys the Testbox ID and source, and
each remote stage holds `testbox-benchmark/.stage.lock` through its build and
artifact writes. Do not issue concurrent `run` commands against one ID.

Wait for setup and capture the exact run identity:

```bash
blacksmith testbox status --id "$TBX" --wait --wait-timeout 15m
blacksmith testbox run --id "$TBX" --debug \
  "set -euo pipefail; test -s /tmp/.testbox/auth_token; grep -Eq '(^|[[:space:]])metadata_port=[^[:space:]]+' /proc/cmdline; test \"\$(git rev-parse HEAD)\" = \"$SOURCE_SHA\"; test \"\$(git rev-parse HEAD:ghostty)\" = \"$GHOSTTY_SHA\"; test \"\$(git -C ghostty rev-parse HEAD)\" = \"$GHOSTTY_SHA\"; test -z \"\$(git status --porcelain=v1 --untracked-files=normal)\"; test -z \"\$(git -C ghostty status --porcelain=v1 --untracked-files=normal)\"; rustup show active-toolchain; rustc --version; cargo --version; \"$CMUX_ZIG\" version"
```

The setup workflow also uploads `setup-identity.json`. It contains the
workflow run, source ref/SHA/tree, Ghostty gitlink and checkout SHA, runner
label/architecture/CPU identity, and pinned Rust/Zig/toolchain-file metadata.
Never print or download `/tmp/.testbox/auth_token`.

## Remote benchmark stages

Before each stage, recompute `SOURCE_SHA` and `GHOSTTY_SHA` and repeat the
clean pushed-branch preflight. Pass the expected values as validated arguments;
the helper does not trust the remote checkout or a caller-supplied expected SHA
without comparing it to Git metadata:

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

  # Download immediately. Blacksmith's next rsync may delete or replace remote
  # files, so a one-time download after all stages is insufficient.
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
```

The helper supports exactly `first-clean`, `incremental-noop`, and
`changed-file`. It records a schema-2 JSON object for each stage containing:

* expected and observed source commit/tree identity before and after the build;
* expected and observed Ghostty gitlink and initialized submodule HEAD;
* clean/dirty file lists and source restoration status;
* Testbox ID and adopted workflow run ID;
* runner label, hostname, architecture, CPU count, and `uname`;
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
    json.dump({"schema": 2, "source_sha": expected_source, "ghostty_gitlink_sha": expected_ghostty, "testbox_id": testbox_id, "stages": records}, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
```

Keep `raw/*.json`, `raw/*.time`, `raw/*.log`, every `*.run.log` and download
log, the setup artifact, and the source manifest in the separate
`.cmux-scratch/` evidence directory. Do not add credentials or private keys.

## Fail-safe cleanup

Always download before cleanup. Use the checked-in cleanup helper rather than
ignoring errors with `|| true`:

```bash
scripts/blacksmith-testbox-cleanup.sh "$TBX" "$OUT"
```

It records stop, post-stop status, and `list --all` output; verifies that the
specific Testbox ID is terminal or absent from the active inventory; and
accepts only the known race where stop returns a 409 saying the box is already
stopped or completed. Other stop, status, or list failures remain failures.
Put it in an `EXIT` trap that preserves the benchmark's original exit status
unless cleanup itself fails. If warmup never returned an ID, still run
`blacksmith testbox list --all` and retain its exit status and output.

## Timing interpretation

The benchmark reports two clocks. The local CLI transcript measures sync,
transport, queueing, and the remote command. The downloaded `/usr/bin/time -p`
record measures the remote `cargo build -p cmux-tui --locked` command. Compare
remote `real` or `time_real_seconds` values for build performance, and retain
CLI wall time when evaluating Testbox overhead.

`first-clean` is target-clean but dependency-warm: warmup runs `cargo fetch` and
`zig build --fetch`, and the workflow may restore registry, git, and Zig caches.
`incremental-noop` measures a second build on the same VM. `changed-file` is a
controlled source change on that same VM. These are deliberately different
from a cold-VM benchmark.

The existing 32-vCPU evidence at
`.cmux-scratch/blacksmith-testbox-e40704611ac35f4ffa153/` remains historical
provenance for setup SHA `e40704611ac35f0e3a806841a9eae383f4ffa153`, Testbox
`tbx_01kzxebn91nhatkv4ygevh06vs`, and workflow run `31696013711`. Its raw
records and cleanup result must not be rewritten when validating this hardening
change.
