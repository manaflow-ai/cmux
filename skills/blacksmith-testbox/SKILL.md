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
(or an equivalent manual approval rule), disable administrator bypass, leave the
environment secret set empty, and set these two **environment configuration
variables**:

* `BLACKSMITH_TESTBOX_REVIEWED_REF`, one exact branch name without the
  `refs/heads/` prefix;
* `BLACKSMITH_TESTBOX_REVIEWED_SHA`, one exact lowercase 40-character commit
  SHA for that branch.

Configure the environment's deployment branch rule to the same exact branch,
with no wildcard or fork rule. Update the two variables only after an
independent maintainer has reviewed that exact commit, including this workflow
and the remote helper. Treat the environment, its variables, and its branch
rule as required repository controls, not settings this workflow can create.
GitHub evaluates reviewer approval and the branch rule before the job's first
step, including `begin-testbox`. The workflow then compares `github.ref`,
`github.sha`, and a fresh `git ls-remote` result to those exact pins before
exposing the Testbox token. If the environment is deleted, renamed,
unconfigured, or stale, disable the lane and stop rather than changing the
workflow to proceed. If it has no required reviewer, no exact branch rule, or
no exact ref/SHA pins, the lane is not production-safe.

This is reviewed-branch mode, not PR validation. Never dispatch it for an
untrusted PR, fork, external contributor, wildcard branch, or commit whose
workflow/helper changes have not been independently reviewed. The Testbox
command environment can read `/tmp/.testbox/auth_token` and anything else
exposed to the GitHub job. The token is not sandboxed, and `permissions:
contents: read` does not change that trust boundary. When the reviewed commit
or trust context changes, stop the old box and warm a fresh one.

The helper retains the `CMUX_TESTBOX_REMOTE=1` guard for accidental local
launches, and additionally requires the Blacksmith VM kernel metadata marker
and matching `/tmp/.testbox` state. The environment flag remains caller
controlled and is not an authentication mechanism. The protected environment,
its exact ref/SHA pins, and trusted-maintainer review are the security boundary.
The workflow cannot manufacture those controls, so configuration drift makes
the lane unavailable rather than safe.

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
The repository does not currently pin a checksum-verified CLI artifact, so CLI
provenance is a trusted-lane operational limitation: do not silently upgrade or
substitute a version, and retain `blacksmith --version` with each evidence set.

## Exact source contract

Blacksmith/GitHub rejected the previous raw-SHA warmup with HTTP 422 (`No ref
found`). Do not pass a commit SHA to `blacksmith testbox warmup --ref`, and do
not document raw SHA refs as supported. Warm up a pushed branch ref, then carry
the full SHA separately and assert it remotely.

Initialize the public Ghostty submodule once, then run this preflight from the
clean worktree root:

```bash
set -euo pipefail
git submodule update --init ghostty
cd "$(git rev-parse --show-toplevel)"
SOURCE_REF="$(git symbolic-ref --short HEAD)"
REVIEWED_REF="$(gh variable get BLACKSMITH_TESTBOX_REVIEWED_REF --env blacksmith-testbox-trusted --repo manaflow-ai/cmux --json value --jq .value)"
REVIEWED_SHA="$(gh variable get BLACKSMITH_TESTBOX_REVIEWED_SHA --env blacksmith-testbox-trusted --repo manaflow-ai/cmux --json value --jq .value)"
[[ "$SOURCE_REF" == "$REVIEWED_REF" ]] || {
  echo "HEAD is not the exact branch pinned by blacksmith-testbox-trusted" >&2
  exit 1
}
if [[ ! "$SOURCE_REF" =~ ^[A-Za-z0-9._/-]+$ || "$SOURCE_REF" == *..* || "$SOURCE_REF" == */ || "$SOURCE_REF" == *//* ]]; then
  echo "HEAD must name a supported pushed branch ref" >&2
  exit 1
fi
SOURCE_SHA="$(git rev-parse HEAD)"
[[ "$REVIEWED_SHA" =~ ^[0-9a-f]{40}$ && "$SOURCE_SHA" == "$REVIEWED_SHA" ]] || {
  echo "HEAD is not the exact commit pinned by blacksmith-testbox-trusted" >&2
  exit 1
}
ghostty_entry="$(git ls-tree HEAD ghostty)"
[[ "$ghostty_entry" =~ ^160000[[:space:]]commit[[:space:]][0-9a-f]{40}[[:space:]]ghostty$ ]] || {
  echo "HEAD:ghostty is not a gitlink" >&2
  exit 1
}
GHOSTTY_SHA="$(git rev-parse HEAD:ghostty)"
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$GHOSTTY_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$(git -C ghostty rev-parse HEAD)" == "$GHOSTTY_SHA" ]]
[[ -z "$(git status --porcelain=v1 --untracked-files=normal)" ]]
[[ -z "$(git -C ghostty status --porcelain=v1 --untracked-files=normal)" ]]
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

The workflow's optional `source_sha` input is an assertion only; it cannot
select a candidate because Blacksmith supplies only `testbox_id`. The CLI
warmup selects `SOURCE_REF`, while GitHub supplies `github.sha`; the protected
environment pins both and the workflow checks the remote branch again. A
supplied `source_sha` must equal that same protected SHA. This is the mechanism
that permits a reviewed feature branch to validate its final PR head without
executing an unreviewed branch.

## Warmup and identity capture

Warm the exact branch pinned by the protected environment, never an
unreviewed branch or a raw SHA:

```bash
WORKFLOW=.github/workflows/ci-workflow-guard-tests-testbox.yml
JOB=cmux-tui-rust
blacksmith testbox warmup "$WORKFLOW" \
  --ref "$SOURCE_REF" \
  --job "$JOB" \
  --idle-timeout 30
```

Save the returned `tbx_...` ID. One ID belongs to one worktree and one trust
context. The workflow concurrency group keys every setup request by Testbox
ID, including requests for different source SHAs. Source identity is validated
separately, and each remote stage holds `testbox-benchmark/.stage.lock` through
its build and artifact writes. Blacksmith's CLI exposes no pre-rsync lease, so
that remote lock cannot serialize the CLI's initial sync. One Testbox ID must
therefore have one owning worktree/operator; do not issue concurrent `run` or
download commands from independent clients. This is an explicit trusted-lane
limitation, not a claim of multi-client Testbox isolation.

Wait for setup and capture the exact run identity:

```bash
blacksmith testbox status --id "$TBX" --wait --wait-timeout 15m
```

The setup job's `setup-identity.json` artifact and each stage helper's
pre-build JSON record are the identity transcripts. The helper verifies the
Testbox VM marker, claimed Testbox ID, source commit/tree, Ghostty
gitlink/checkout, and clean status before it invokes Cargo, then repeats those
checks after the build. Keep the setup artifact URL or download it into `$OUT`;
it records runner/toolchain/Ghostty identity independently of the stage helper.
The setup JSON contains the workflow run, source ref/SHA/tree, Ghostty gitlink
and checkout SHA, runner label/architecture/CPU identity, and pinned
Rust/Zig/toolchain-file metadata. A successful setup also copies that JSON to
`/tmp/.testbox/cmux-tui-rust-setup-identity.json`; the stage helper refuses a
missing or mismatched marker, so a failed hydration cannot be benchmarked.
Never print or download `/tmp/.testbox/auth_token`.

## Remote benchmark stages

The detailed, receipt-producing orchestration in `benchmark.md` is the required
entry point for a complete benchmark. It creates the unique `OUT_ROOT`, receipt,
cleanup token, setup artifact capture, and cleanup preview state. Do not copy
only this stage loop into an ad hoc shell without those prerequisites.

Before each stage, recompute `SOURCE_SHA` and `GHOSTTY_SHA` and repeat the
clean pushed-branch preflight, including the protected reviewed ref/SHA pins.
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
30-second kill grace period. It records a schema-2 JSON object for each stage
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
    json.dump({"schema": 2, "source_sha": expected_source, "ghostty_gitlink_sha": expected_ghostty, "testbox_id": testbox_id, "stages": records}, handle, indent=2, sort_keys=True)
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
scripts/blacksmith-testbox-cleanup.sh "$TBX" "$OUT" "$CLEANUP_TOKEN" PREVIEW
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
