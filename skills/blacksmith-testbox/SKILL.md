---
name: blacksmith-testbox
description: >
  Run Linux-compatible cmux checks in a Blacksmith Testbox. Use for Blacksmith
  onboarding, remote Linux validation, Python workflow guards, and fast
  repeatable checks against the CI environment.
---

# Blacksmith Testbox

This repository's Testbox is a Linux environment derived from
`.github/workflows/ci.yml` and its `workflow-guard-tests` job. It hydrates Bun
1.3.6, Python 3.9, PyYAML, bashlex, and shallow `ghostty` and `vendor/bonsplit`
submodules. It does not provide macOS, Xcode, a GUI, or the full cmux CI suite.
Use the repository's cloud or hosted macOS workflow for Swift, XCTest, app-host,
and UI verification.

## Prerequisites

Install and authenticate the CLI once per machine:

```bash
curl -fsSL https://get.blacksmith.sh | sh
blacksmith auth whoami
```

If authentication is missing, use the browser flow. The organization slug for
this repository is `manaflow-ai`:

```bash
blacksmith auth login --non-interactive --organization manaflow-ai
```

Do not print or commit `~/.blacksmith/credentials`. Do not pass an API token
when browser authentication is requested.

## Warm up

Run every Testbox command from the root of the current git worktree. Push the
workflow file before warming up, because Blacksmith dispatches the workflow
from GitHub rather than reading an unpushed local file.

```bash
cd "$(git rev-parse --show-toplevel)"
blacksmith testbox warmup .github/workflows/ci-workflow-guard-tests-testbox.yml \
  --ref <branch> \
  --idle-timeout 30
```

The CLI defaults `--ref` to the current branch. Use an explicit branch when
the shell's checkout and the intended workflow revision could differ. Save the
returned `tbx_...` ID and use one ID per worktree or agent.

The workflow has two modes:

* A Testbox warmup supplies `testbox_id`, starts hydration, and keeps the VM
  alive.
* A normal pull request run has no `testbox_id`; the begin/run actions validate
  the setup without claiming a VM.

## Run checks

`run` waits for hydration automatically and returns the remote command's exit
status:

```bash
blacksmith testbox run --id <ID> \
  "python3 tests/test_ci_change_areas.py"

blacksmith testbox run --id <ID> \
  "cd agent-chat && bun test test/claude-environment.test.ts"
```

This workflow installs only the dependencies listed above. Before web, Go, Rust,
or other checks, run the repository's matching install/setup command in the
same Testbox, then run the check. A changed dependency manifest requires a
fresh install on the Testbox:

```bash
blacksmith testbox run --id <ID> \
  "cd web && bun install --frozen-lockfile && bun run typecheck"
```

Do not assume that a local `node_modules`, build directory, Swift package cache,
or other ignored/generated directory was transferred. The CLI synchronizes the
worktree with checksum-based deletion semantics; execute required installs and
builds remotely.

## Sync and safety rules

* Invoke `blacksmith testbox run` from the repository root. Put `cd` only
  inside the quoted remote command. Running the CLI from a subdirectory can
  mirror the wrong tree and delete unrelated remote files.
* Treat the Testbox as a disposable mirror of the current worktree. Do not
  store unique state there without downloading it first.
* Reuse the same ID for iterative runs. A new worktree needs its own warmup.
* Never use this Linux Testbox for macOS or iOS compilation, XCTest, app-host
  tests, UI tests, or GUI dogfood.
* Local formatting and static inspection are allowed. Follow the repository
  testing rules for every behavioral test and build.
* Do not put credentials, private keys, or generated Testbox state in the
  repository.

## Status, artifacts, and cleanup

Use a blocking status check when needed, rather than a sleep loop:

```bash
blacksmith testbox status --id <ID> --wait --wait-timeout 15m
```

Download artifacts relative to the remote worktree:

```bash
blacksmith testbox download --id <ID> test-results/ ./test-results/
blacksmith testbox download --id <ID> build/output.tar.gz ./output.tar.gz
```

Stop the VM after the task:

```bash
blacksmith testbox stop --id <ID>
```

The default idle timeout is 30 minutes. Stopping explicitly avoids paying for
unused runner minutes.
