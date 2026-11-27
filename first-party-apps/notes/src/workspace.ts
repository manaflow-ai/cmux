/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Which workspace a surface treats as "current", and what workspaces are
// called. The app API has no per-client "current workspace" read (README,
// gaps): the mount context does not carry it and `workspace.list` only has a
// session-wide `focused` flag. A surface uses `ctx.workspace` (proposed mount
// context field), then the focused workspace. Commands pass workspace
// selectors through; the op router resolves them for the notes server.

import type { WorkspaceRef } from "./notes.ts"

type Snapshot = Cmux.WorkspaceSnapshot

export interface Workspaces {
  current: () => WorkspaceRef | null
  /** Name of a workspace that still exists, else null (the note keeps its stored name). */
  liveName: (id: string) => string | null
}

/** Per-mount workspace state; re-reads on `workspace.changed`, never polls. */
export function watchWorkspaces(ctx: { workspace?: unknown }): Workspaces {
  const live = cmux.live<Snapshot[]>("workspace.list", {})
  const list = computed(() => live() ?? [])
  const current = computed<WorkspaceRef | null>(() => {
    const all = list()
    const fromCtx = typeof ctx.workspace === "string" ? all.find((w) => w.id === ctx.workspace) : undefined
    const focused = fromCtx ?? all.find((w) => w.focused)
    return focused ? { id: focused.id, name: focused.name } : null
  })
  return { current, liveName: (id) => list().find((w) => w.id === id)?.name ?? null }
}
