# Per-pane git worktree isolation (issue #3414)

Status: **Phase 1 only** — `WorktreeManager` primitives + tests. UI / CLI / lifecycle integration are intentionally deferred to follow-up PRs (see "Phased rollout" below).

Tracking: [#3414](https://github.com/manaflow-ai/cmux/issues/3414). Original ask: [#156](https://github.com/manaflow-ai/cmux/issues/156). Prior art: [dmux](https://github.com/standardagents/dmux).

## Goal

Let users (opt-in, per workspace) launch panes that automatically run in their own git worktree on a fresh branch, so parallel agents don't trample each other's checkouts. Closing the pane reclaims the worktree, optionally snapshotting state to a recovery branch first.

## Non-goals

- Replacing the existing `worktree-agents` custom command pattern. That stays — it's the "shell-script all the way down" path.
- Cross-machine / cross-repo coordination.
- Auto-merging finished branches.

## What ships in this PR (Phase 1)

`Sources/Worktree/WorktreeManager.swift` — pure-Foundation Swift module with:

| API | Purpose |
| --- | --- |
| `add(repoPath:worktreePath:branch:basedOn:)` | `git worktree add -b <branch> <path> [<basedOn>]` with typed pre-checks for path collisions and branch collisions. |
| `list(repoPath:)` | `git worktree list --porcelain` parsed into typed `Record`s. |
| `remove(repoPath:worktreePath:force:)` | `git worktree remove [--force]`. |
| `snapshot(worktreePath:mainRepoPath:snapshotBranch:)` | Create a recovery branch ref in the main repo. Captures uncommitted tracked changes via `git stash create` so the branch can recover dirty state. |
| `repoToplevel(forPath:)` | `git rev-parse --show-toplevel`. |
| `parseListPorcelain(_:)` | Pure parser exposed for tests. |

Errors are modeled as `WorktreeManager.Failure`, an `Equatable` enum with `CustomStringConvertible` messages.

`cmuxTests/WorktreeManagerTests.swift` — runtime tests that:

1. Spin up a temp repo with `git init`, configure committer identity, make one commit.
2. Exercise `add` / `list` / `remove` / `snapshot` against a real `git` binary.
3. Verify behavior via `FileManager` and `git rev-parse`.
4. Skip when `/usr/bin/git` is absent (sandboxed CI).

Plus pure-parser tests that don't touch git, so the parser stays testable in isolation.

## Phased rollout (subsequent PRs)

### Phase 2 — config schema + CLI

- Extend `cmux.json` / `.cmux.yaml` with an `isolation` block:

  ```yaml
  isolation:
    mode: worktree                  # off | worktree
    base_branch: main               # branch to fork from
    branch_template: "cmux/{workspace}-{ts}"
    worktree_dir: "../worktrees"    # relative to repo toplevel
    cleanup:
      on_close: snapshot_then_remove   # remove | snapshot_then_remove | keep
      snapshot_branch: "cmux/abandoned/{ts}"
  ```

- New `cmux worktree` CLI subcommand group: `create`, `list`, `remove`, `gc`. Wraps `WorktreeManager` and surfaces JSON + human-readable output. Lives in `CLI/cmux.swift`.

- Add `cmux new-workspace --isolated` and `cmux new-pane --isolated` flags.

### Phase 3 — UI integration

- Pane "+" menu entry: **"New isolated agent pane"** — invokes `WorktreeManager.add` and opens the configured agent inside the new worktree.
- Sidebar / tab metadata gains a worktree affordance: badge icon, branch name, right-click menu (Open in Finder / Promote branch / Discard worktree).
- Honor the `Snapshot boundary` rule from `CLAUDE.md` — pass immutable value snapshots into rows, never observable stores.

### Phase 4 — lifecycle / GC / recovery

- Pane-close handler runs `cleanup.on_close` per the active config.
- Daemon-side reconciliation on launch: any worktree whose owner pid is dead is reconciled (snapshot then remove, or remove, or surface as orphaned). This subsumes [#3320](https://github.com/manaflow-ai/cmux/issues/3320) and [#3321](https://github.com/manaflow-ai/cmux/issues/3321).
- `cmux worktree gc --dry-run` / `cmux worktree gc` for explicit cleanup.
- Compose with [#3323](https://github.com/manaflow-ai/cmux/issues/3323) (file-lock broker) once that lands.

### Process-helper timeout (cross-cutting, deferred from Phase 1)

`WorktreeManager.runGit` and `Sources/PortScanner.swift`'s `captureStandardOutput` both call `process.waitUntilExit()` with no timeout. git can hang on credential / SSH passphrase prompts, locked indexes, or unresponsive remotes; once Phase 2/4 wires `snapshot()` / `add()` into the pane lifecycle on a worker thread, a single hung invocation stalls that thread permanently.

Phase 1 ships without timeout because the operations driven from tests are local-only and credential-free (`init`, `config`, `commit`, `worktree add` without remote, `branch`, `rev-parse`, `show-ref`, `stash create`). Phase 2 must add timeout consistently to **both** helpers so the repo carries one pattern.

Required steps (the naive `group.wait(timeout:) → throw` pattern races the `defer` block against in-flight `readDataToEndOfFile` calls and leaks `group.leave()`s):

1. `process.terminate()` (SIGTERM).
2. `process.waitUntilExit()` so the child closes its write-ends and `readDataToEndOfFile()` drains return naturally.
3. `group.wait(timeout: short-grace)` to confirm the drain closures have completed before we close the read handles.
4. SIGKILL fallback if the grace period elapses (hooks can ignore SIGTERM).
5. Throw a typed timeout error.

A configurable `gitCommandTimeoutSeconds` (or a unified `Process.captureWithTimeout` helper covering both `WorktreeManager` and `PortScanner`) is the natural surface. Tracked in PR [#3415](https://github.com/manaflow-ai/cmux/pull/3415) review thread (CodeRabbit).

## Design notes / decisions

### Why a parser separate from the Process call

`parseListPorcelain` is a pure function on `String`. That keeps the parser unit-testable without spawning git, which matters for both speed and CI environments where git might be policy-locked (signed-binary sandboxes).

### Why `git stash create` for snapshots

`git stash create` produces a stash commit *without* mutating the stash stack or the working tree. Its parent is HEAD, so a recovery branch pointing at the stash commit gives:

- `git log <recovery>` → stash commit → HEAD → ...
- `git checkout <recovery>` → detached HEAD on the stash; `git diff HEAD~1` shows the dirty state.

Untracked files are not captured by `git stash create` (it has no `--include-untracked` form). Phase 2 should capture untracked separately if we want full state recovery — for now this is documented as a known limitation.

### Why opt-in, not on-by-default

cmux's existing workspace model is "open a directory, run terminal there." Forcing worktrees would break that mental model. `isolation.mode: worktree` is opt-in per workspace (or globally via `~/.cmux/config.yaml`).

### Why the snapshot branch lives in the main repo

`git worktree remove` invalidates any branch that lived only inside the worktree's metadata. By creating the snapshot branch ref via `git -C <main_repo> branch ...`, the ref is owned by the main repo and survives worktree removal.

## Open questions

- **Branch naming collisions**: when `branch_template` produces a name that already exists, fail or auto-suffix? Phase 2 should pick. Current `add` throws `branchAlreadyExists` so the caller decides.
- **`worktree_dir` defaults**: relative to repo toplevel (`../worktrees`) is dmux-style and survives `git clean -fdx`. An alternate is `$XDG_DATA_HOME/cmux/worktrees/<repo-hash>/`, which keeps the user's repo dir tidy but breaks `cd ..` familiarity.
- **Untracked files in snapshot**: Phase 2 — capture via temp commit on a dummy ref before stash, then merge into recovery branch?

## Related issues

- [#156](https://github.com/manaflow-ai/cmux/issues/156) — closed Not Planned predecessor
- [#3414](https://github.com/manaflow-ai/cmux/issues/3414) — this feature
- [#3320](https://github.com/manaflow-ai/cmux/issues/3320) — orphan/idle worktree GC
- [#3321](https://github.com/manaflow-ai/cmux/issues/3321) — snapshot before kill
- [#3323](https://github.com/manaflow-ai/cmux/issues/3323) — file-lock broker for parallel worktrees
- [#666](https://github.com/manaflow-ai/cmux/issues/666) — sidebar branch refresh
