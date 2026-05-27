# Agent ADE Workflows with cmux

This guide explains how to replicate the agent-driven engineering (ADE) workflow—used by tools like Claude Code, Codex, and OpenCode—inside cmux. The goal is a single primary checkout plus per-task worktrees, with each agent session organized in the sidebar.

## Recommended repo layout

```
~/repos/my-project/          # primary checkout (bare or regular clone)
├── main/                    # main worktree tracking origin/main
├── task-42-fix-auth/        # worktree for authentication bugfix
├── task-43-refactor-db/     # worktree for database refactor
└── ...
```

Each worktree is an isolated working directory that shares the same `.git` object store, so branching, stashing, and history are cheap.

## Creating a worktree and opening it in cmux

1. Create the worktree from your primary checkout:

   ```bash
   cd ~/repos/my-project
   git worktree add task-44-add-metrics origin/main
   cd task-44-add-metrics
   ```

2. Open the directory in cmux:

   ```bash
   cmux new-workspace --name "my-project#44" --directory "$PWD"
   ```

   The workspace name appears in the sidebar. Use the `#<task>` suffix to keep the mapping obvious.

3. Start your agent in that workspace:

   ```bash
   claude  # or codex, opencode, etc.
   ```

   The agent session runs in the worktree directory, and cmux sidebar shows the branch, working directory, and any notifications.

## Organizing per-agent or per-task sessions in the sidebar

Use cmux workspaces as the top-level unit of organization:

- One workspace per task/worktree.
- Name pattern: `<repo>#<issue>` or `<repo>-<brief-desc>`.
- Use workspace colors (`cmux themes set --workspace <ref> --color <hex>`) to visually group related tasks.

If you run multiple agents in parallel (e.g., Claude on one task and Codex on another), split the workspace (`Cmd+D`) and launch each agent in its own pane. Each pane gets its own sidebar metadata and notification ring.

## Comparison with fully automated ADEs

Fully automated ADEs (e.g., some cloud-based agent platforms) handle worktree provisioning for you:

| Aspect | Fully automated ADE | cmux manual workflow |
|--------|---------------------|----------------------|
| Worktree creation | Automatic per task | `git worktree add` |
| Session isolation | VM or container | cmux workspace + pane |
| Sidebar metadata | Platform-specific UI | cmux native sidebar (branch, PR, cwd, ports) |
| Notification routing | Platform-specific | cmux native notification rings |
| Cleanup | Automatic on task close | Manual `git worktree remove` |

The manual workflow trades one-click provisioning for full control: you choose when to branch, when to merge, and which tools to run.

## Current manual steps versus future automation

**Manual today:**
1. `git worktree add <path> <branch>`
2. `cmux new-workspace --name ... --directory ...`
3. Start agent CLI manually.
4. `git worktree remove <path>` when done.

**Future automation (planned):**
- Native `cmux worktree` commands to create/remove worktrees and workspaces in one step.
- Agent hook auto-detection to spawn a new workspace when an agent session starts.
- Vault integration to persist and resume agent sessions across worktrees.

See related tracking issues:
- [#3414](https://github.com/manaflow-ai/cmux/issues/3414)
- [#4221](https://github.com/manaflow-ai/cmux/issues/4221)

## Cleanup and recovery

**Remove a stale worktree:**

```bash
cd ~/repos/my-project
git worktree remove task-44-add-metrics
```

If the directory was deleted without `git worktree remove`, prune it:

```bash
git worktree prune
```

**Close the cmux workspace:**

```bash
cmux close-workspace --workspace workspace:<id>
```

Or use `Cmd+Shift+W` in the UI.

**Recover a lost session:**

If cmux crashed or was force-quit, use `File > Reopen Previous Session` (`Cmd+Shift+O`) to restore the last saved layout. Worktrees themselves are ordinary Git working directories and are unaffected by cmux state.

## Quick-start checklist

- [ ] Clone or initialize a primary repo checkout.
- [ ] Create a worktree for the next task: `git worktree add ...`.
- [ ] Open it in cmux: `cmux new-workspace --directory ...`.
- [ ] Start the agent CLI in the workspace pane.
- [ ] Observe sidebar metadata (branch, PR, cwd, ports).
- [ ] Close and clean up when done: `git worktree remove ...` + `cmux close-workspace ...`.
