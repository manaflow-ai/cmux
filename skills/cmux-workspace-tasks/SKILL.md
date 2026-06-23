---
name: cmux-workspace-tasks
description: "Read and manage cmux Workspace Tasks when the user asks about tasks, todos, ideas, deliverables, goals, or per-workspace planning for the current coding session."
---

# cmux Workspace Tasks

Use this skill when the user asks you to inspect, add, complete, archive, remove, reorder, or open tasks for a cmux workspace. Workspace Tasks are beta-gated and scoped to one workspace. They are not global project todos.

## Scope

Default to the caller workspace:

```bash
cmux workspace tasks list --workspace "${CMUX_WORKSPACE_ID:-}"
```

Use another workspace only when the user names it. If `CMUX_WORKSPACE_ID` is missing, run:

```bash
cmux identify --json
```

Then tell the user which workspace context you used.

## Commands

List open and archived tasks:

```bash
cmux workspace tasks list --workspace "${CMUX_WORKSPACE_ID:-}"
cmux --json workspace tasks list --workspace "${CMUX_WORKSPACE_ID:-}"
```

Add a task:

```bash
cmux workspace tasks add --workspace "${CMUX_WORKSPACE_ID:-}" --title "Write release notes"
cmux workspace tasks add --workspace "${CMUX_WORKSPACE_ID:-}" --title "Update docs" --before <task-uuid>
cmux workspace tasks add --workspace "${CMUX_WORKSPACE_ID:-}" --title "Check CI" --index 0
```

Insert or reorder within the Open bucket:

```bash
cmux workspace tasks add --workspace "${CMUX_WORKSPACE_ID:-}" --title "Update docs" --after <task-uuid>
cmux workspace tasks move --workspace "${CMUX_WORKSPACE_ID:-}" <task-uuid> --index 0
cmux workspace tasks move --workspace "${CMUX_WORKSPACE_ID:-}" <task-uuid> --before <task-uuid>
cmux workspace tasks move --workspace "${CMUX_WORKSPACE_ID:-}" <task-uuid> --after <task-uuid>
cmux workspace tasks move --workspace "${CMUX_WORKSPACE_ID:-}" --task <task-uuid> --index 0
cmux workspace tasks move --workspace "${CMUX_WORKSPACE_ID:-}" --task-id <task-uuid> --before <task-uuid>
cmux workspace tasks move --workspace "${CMUX_WORKSPACE_ID:-}" --id <task-uuid> --after <task-uuid>
```

Complete a task by moving it to Archived:

```bash
cmux workspace tasks archive --workspace "${CMUX_WORKSPACE_ID:-}" <task-uuid>
```

Restore an archived task to Open:

```bash
cmux workspace tasks unarchive --workspace "${CMUX_WORKSPACE_ID:-}" <task-uuid>
cmux workspace tasks restore --workspace "${CMUX_WORKSPACE_ID:-}" <task-uuid>
```

Remove a task:

```bash
cmux workspace tasks remove --workspace "${CMUX_WORKSPACE_ID:-}" <task-uuid>
```

Open the native Workspace Tasks surface without stealing focus:

```bash
cmux workspace tasks open --workspace "${CMUX_WORKSPACE_ID:-}" --focus false
cmux workspace tasks open --workspace "${CMUX_WORKSPACE_ID:-}" --focus true
```

## Rules

- Treat Open as active work and Archived as completed/history.
- Use `--json` when you need stable task UUIDs for follow-up mutations.
- Never mutate tasks from another workspace unless the user explicitly names that workspace.
- Prefer `archive` for completed work. Use `remove` only when the user asks to delete or discard an item.
- Use `unarchive` or `restore` when the user asks to reopen, restore, undo completion, or move an archived task back to Open.
- If the command says Workspace Tasks beta is disabled, tell the user it must be enabled in Settings > Beta Features before task operations work.
