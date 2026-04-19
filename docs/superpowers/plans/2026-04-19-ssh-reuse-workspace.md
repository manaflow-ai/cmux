# SSH Reuse Existing Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `cmux ssh <destination>` reuse an existing matching SSH workspace by default, with `--new` preserving the old create-new behavior.

**Architecture:** Keep the feature in the CLI layer. Parse `--new`, use existing `workspace.list` metadata to find safe matches before relay/bootstrap setup, select the existing workspace unless `--no-focus` is set, and report `reused` in command output.

**Tech Stack:** Swift CLI (`CLI/cmux.swift`) and Python v2 integration tests (`tests_v2/test_ssh_remote_cli_metadata.py`).

---

### Task 1: Regression Tests

**Files:**
- Modify: `tests_v2/test_ssh_remote_cli_metadata.py`

- [ ] Add a test that configures one remote workspace, invokes `cmux ssh <same destination> --no-focus --json`, and asserts the workspace count does not increase and JSON contains the original workspace id with `reused: true`.
- [ ] Add a test that invokes `cmux ssh <same destination> --new --no-focus --json` and asserts a second workspace is created with `reused: false`.
- [ ] Run the new tests before implementation and confirm they fail because `cmux ssh` currently creates duplicate workspaces and does not parse `--new`.

### Task 2: CLI Implementation

**Files:**
- Modify: `CLI/cmux.swift`

- [ ] Add `forceNewWorkspace: Bool` to `SSHCommandOptions`.
- [ ] Parse `--new` in `parseSSHCommandOptions` and document it in help text.
- [ ] Add helpers in `CLI/cmux.swift` to locate a reusable SSH workspace from `workspace.list` payload.
- [ ] In `runSSH`, after parsing options and before generating relay/bootstrap state, return early when a reusable workspace exists and `--new` is absent.
- [ ] Include `reused: true` for reused workspaces and `reused: false` for newly-created workspaces.

### Task 3: Verification and Deployment

**Files:**
- Existing build/deploy scripts in `/Users/minoo/projs/cmux-patch`

- [ ] Run the targeted regression tests.
- [ ] Run Swift build/reload or the repository's existing verification command if targeted tests require a fresh binary.
- [ ] Run `/Users/minoo/projs/cmux-patch/rebuild.sh` to deploy the patched app.
