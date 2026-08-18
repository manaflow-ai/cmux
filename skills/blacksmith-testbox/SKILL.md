---
name: blacksmith-testbox
description: >
  Warm and drive a Blacksmith Testbox for cmux-tui Rust and Zig work on Linux.
  Use whenever a task will compile cmux-tui (cargo build, cargo test, clippy,
  startup benchmarks, Ghostty Zig deps) or when the user says testbox, warm a
  box, blacksmith, remote build box, or benchmark cmux-tui. Never run cargo,
  rustc, or zig build on the local Mac.
---

# cmux-tui Blacksmith Testbox

A Testbox is a persistent 32 vCPU Linux VM that keeps its disk between
commands. CI warms it once, and every later build reuses the Cargo registry,
the Zig cache, and `target/`. A clean cmux-tui build costs about 130 s on a warm
box, a no-op about 0.2 s, and a one-file change about 8 s.

## Warm your own box first, before you read code

Warmup takes about four minutes of wall clock you cannot compress. Starting it
at the end of your task means waiting; starting it in your first minute means it
is ready by the time you know what to build. So:

1. If your task might compile cmux-tui, dispatch the warmup **before** you open
   a single source file, then read code while it hydrates. The exception is an
   evidence run: `benchmark.md` requires its preflight, `OUT_ROOT`, and receipt
   to exist before warmup, so read that plan first and accept the delay.
2. Warm **your own** box. One box belongs to one worktree and one agent, because
   `blacksmith testbox run` synchronizes your worktree onto it with
   `rsync --delete`. Two agents on one ID overwrite each other's source and
   corrupt each other's timings.
3. Never adopt a box you find in `blacksmith testbox list --all`. A box you did
   not warm is someone else's working state.
4. Stop your box the moment you are done, and always pass `--idle-timeout` so a
   crashed agent cannot leak a running VM.

Skip the lane entirely for Swift, Xcode, XCUITest, GUI, and app-host work. That
is macOS, and it belongs in the hosted macOS workflows.

Run `./scripts/blacksmith-testbox-demo.sh` once to watch the whole lane work:
it warms a box, pins it, builds cmux-tui twice to show what the persistent disk
buys, prints every remote command before running it, and stops the box on the
way out. `--stages` runs the three measured stages instead.

## Prerequisites

```bash
blacksmith auth whoami     # confirms the manaflow-ai org; prints no secret
blacksmith --version       # record this with any evidence
```

Use the organization-approved pinned CLI. Never install it with
`curl ... | sh`. If the pinned artifact is unavailable, stop and ask the tooling
owner rather than substituting a version.

Run every command from the root of an isolated cmux worktree, never from
`repo/`. The directory you stand in is the directory that gets synchronized.

## Workflow

### Step 1: commit, push, and record identity

The commit you benchmark must be pushed. `blacksmith testbox run` synchronizes
file contents, not history: it makes one opportunistic `git fetch` of your
commit, falls back to copying changed files, and skips even that once the file
fingerprints match. A local-only commit fails on the box with
`upload-pack: not our ref`.

```bash
git submodule update --init ghostty
git push origin "$(git symbolic-ref --short HEAD)"
SOURCE_SHA="$(git rev-parse HEAD)"
GHOSTTY_SHA="$(git rev-parse HEAD:ghostty)"
[[ -z "$(git status --porcelain=v1 --untracked-files=normal)" ]] || exit 1
```

### Step 2: warm the box

```bash
blacksmith testbox warmup .github/workflows/cmux-tui-testbox-warmup.yml \
  --ref main --job cmux-tui-rust --idle-timeout 30   # minutes, not seconds
TBX=tbx_...    # the ID the command prints; assign it once and never retype it
```

`--ref main` is the trust boundary, not a preference. See the trust section
below. `--idle-timeout` is in minutes.

### Step 3: approve the deployment

`warmup` returns the ID immediately and does not block; the run then parks at
the `blacksmith-testbox-trusted` environment gate before its first step.
Approve it on the run page, or from the shell.

Every run in this lane has the same title and the same `main` head branch, so
**never approve `workflow_runs[0]`**. Two agents warm boxes minutes apart, and
approving the newest waiting run hands a stranger's deployment its gate. Bind
the approval to a run that appeared after your own dispatch, and refuse to guess
when more than one is waiting:

Identify your run by set difference against a snapshot taken before you
dispatch. A time window is not enough: another agent dispatching seconds after
you lands inside any window, and nothing in the REST API binds a run to a
Testbox ID. Never correlate a box to a run by timestamp either, because
Blacksmith rewrites a box's `CREATED` value as it hydrates, so the pairing that
looks obvious is wrong for any box past `queued`.

```bash
# Snapshot every gate already waiting in this lane BEFORE dispatching. Set
# difference against this is exact; a time window is not, because a second
# operator dispatching seconds after you lands inside any window you pick.
lane_runs_url="repos/manaflow-ai/cmux/actions/workflows/cmux-tui-testbox-warmup.yml/runs?event=workflow_dispatch&status=waiting"
waiting_before="$(mktemp)"
gh api "$lane_runs_url" --jq '.workflow_runs[].id' | sort >"$waiting_before"

# ... run `blacksmith testbox warmup` here, then:

# Your run is the one that appeared since the snapshot. GitHub does not surface
# it instantly, so poll; zero new runs means "not yet".
waiting_now="$(mktemp)"
approval_run=""
for attempt in $(seq 1 30); do
  gh api "$lane_runs_url" --jq '.workflow_runs[].id' | sort >"$waiting_now"
  new_runs="$(comm -13 "$waiting_before" "$waiting_now")"
  new_count="$(printf '%s' "$new_runs" | grep -c . || true)"
  if (( new_count == 1 )); then
    approval_run="$new_runs"
    break
  fi
  if (( new_count > 1 )); then
    # Two operators dispatched between polls. Nothing in the REST API binds a
    # run to a Testbox ID, so do not guess and do not correlate by timestamp:
    # Blacksmith rewrites a box's CREATED value as it hydrates. Stop your box,
    # re-snapshot, and dispatch again; the next set difference is unambiguous.
    echo "$new_count runs appeared at once; stop your box ($TBX), re-snapshot, and re-dispatch" >&2
    exit 1
  fi
  sleep 5
done
if [[ -z "$approval_run" ]]; then
  echo "no run appeared within 150s; Testbox $TBX is running and you own it" >&2
  exit 1
fi
approval_env="$(gh api "repos/manaflow-ai/cmux/actions/runs/$approval_run/pending_deployments" --jq '.[0].environment.id')"
gh api -X POST "repos/manaflow-ai/cmux/actions/runs/$approval_run/pending_deployments" \
  --input - <<< "{\"environment_ids\":[$approval_env],\"state\":\"approved\",\"comment\":\"benchmark warmup\"}"
printf 'approved run: %s\n' "$approval_run"
```

If this aborts, a warmed box is already running and you own it. Stop it, take a
fresh snapshot, and dispatch again; the next set difference is unambiguous. Do
not wait for a tie to break on its own, because the other operator is probably
stuck at the same guard.

`gh` has no native approve verb for deployments, so this uses REST. Self-approval
is permitted on this environment. `scripts/blacksmith-testbox-demo.sh` implements
exactly this guard if you would rather not hand-roll it.

### Step 4: wait for hydration, then read code

```bash
blacksmith testbox status --id "$TBX" --wait --wait-timeout 15m
```

This blocks while CI installs the pinned Zig and Rust and fetches Cargo and Zig
dependencies. Do your reading now.

### Step 5: pin the box to your commit

The box is an exact checkout of `main`, because that is what CI hydrated. Make
it an exact checkout of your revision. Once per box, before the first build:

```bash
blacksmith testbox run --id "$TBX" \
  "set -euo pipefail; git fetch --no-tags origin $SOURCE_SHA; git reset --hard $SOURCE_SHA; git submodule update --init --depth 1 ghostty"
```

### Step 6: build or benchmark

Any build command goes inside `blacksmith testbox run`:

```bash
blacksmith testbox run --id "$TBX" "cd cmux-tui && cargo build -p cmux-tui --locked"
```

Tests and lints work the same way; only the quoted command changes:

```bash
blacksmith testbox run --id "$TBX" "cd cmux-tui && cargo test --locked"
blacksmith testbox run --id "$TBX" "cd cmux-tui && cargo clippy --locked --all-targets -- -D warnings"
blacksmith testbox run --id "$TBX" "cd cmux-tui && cargo test -p cmux-tui-core --locked some_test_name"
```

Each of these reuses the same warm `target/`, so a second invocation compiles
only what changed. Nothing here needs the stage helper; that is only for
measured timings.

For measured timings use the stage helper, which verifies VM identity, source
identity, and clean status before and after each build:

```bash
blacksmith testbox run --id "$TBX" \
  "CMUX_TESTBOX_REMOTE=1 CMUX_TESTBOX_ID=$TBX ./scripts/blacksmith-cmux-tui-testbox-stage.sh first-clean $SOURCE_SHA $GHOSTTY_SHA"
```

Stages are `first-clean` (wipes `target/`, dependencies stay warm),
`incremental-noop` (rebuild with nothing changed), and `changed-file` (appends a
comment to `cmux-tui/crates/cmux-tui/src/main.rs`, builds, restores the bytes).
`changed-file` rebuilds two crates, `cmux-remote` and `cmux-tui`, so read its
~8 s as a small-edit figure, not as a single-crate floor.
`CMUX_TESTBOX_REMOTE=1` guards against an accidental local launch; it is not
authentication. Add `--debug` to `run` to see the sync strategy.

### Step 7: download, then stop

Download after each stage, because the next sync can delete remote output.

```bash
blacksmith testbox download --id "$TBX" testbox-benchmark/first-clean.json ./first-clean.json
blacksmith testbox stop --id "$TBX"
blacksmith testbox list --all      # the box is gone from Blacksmith's inventory
gh run list --repo manaflow-ai/cmux --workflow cmux-tui-testbox-warmup.yml --limit 3
```

Check both. `list --all` only shows boxes, and an empty list is **not** proof
that nothing is burning: the warmup run's keepalive step keeps holding a 32 vCPU
runner for a while after the box is gone, and it has a 120 minute job timeout. If
your run is still `in_progress` a couple of minutes after the stop, end it:

```bash
gh run cancel <run-id> --repo manaflow-ai/cmux
```

Cancelling is required, not a fallback. Stopping the box does **not** reliably
end its run: measured runs sat `in_progress` for four minutes afterwards, and
`gh run cancel` itself takes about five minutes to land, so `in_progress` right
after either action is expected. Poll until the run reports `completed`. A
`cancelled` conclusion is the healthy end state here; a run that never reached
`Testbox ready` is the real failure.

That bare `stop` is the right cleanup for ordinary build work. The receipt-bound
ceremony in `benchmark.md` applies only to benchmark evidence someone else will
rely on, where the point is proving the box you destroyed is the one your
receipt describes. Never fabricate a receipt to satisfy that guard.

Wrap any of these in `./scripts/blacksmith-bounded-command.sh <seconds> <cmd>`
so a hung sync cannot stall a session. `benchmark.md` is the full evidence plan;
`references/operations.md` covers stage orchestration, cleanup, and the two
clocks.

## Trust boundary, in short

`begin-testbox` writes an auth token into the CI job, and `warmup` resolves the
workflow definition and the hydrated source from the same `--ref`. Warming a
candidate branch would therefore run that branch's copy of the workflow beside
the token, and the branch could delete its own guards. So the lane hydrates
`main` only, nothing from the repository runs before the token, and your
revision arrives afterwards through `blacksmith testbox run`.
`tests/test_ci_testbox_broker_guard.py` enforces that shape on every pull
request. Never edit the workflow to work around a missing control; if the
`blacksmith-testbox-trusted` environment drifts from required reviewers, no
secrets, no admin bypass, and a branch rule of exactly `main`, disable the lane
and stop. Full reasoning: `references/trust-boundary.md`.

## Rules

- MUST NOT run `cargo`, `rustc`, `rustup`, or `zig build` on the local Mac, including as a fallback when the box is unavailable.
- MUST run every Blacksmith command from the intended worktree root. `rsync --delete` can remove remote files that are absent locally.
- MUST push the benchmarked commit and pin the box to it. An unpushed commit silently leaves the box on `main` with your files written over it.
- MUST NOT reuse another agent's Testbox ID, and MUST NOT run concurrent `run` or `download` commands against one ID from separate clients.
- MUST stop the box and confirm with `list --all` when finished.
- MUST NOT print or download `/tmp/.testbox/auth_token`.
- MUST NOT dispatch the warmup for a pull request, a fork, or any ref other than `main`.
- If the toolchain differs from what CI hydrated, the stage helper exits 66. Rebase onto `main` rather than reporting a cold-cache timing.
