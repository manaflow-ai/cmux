// Which workspace is "current" and what workspaces are called.
//
// The app API has no per-client "current workspace" read (README, gaps): the
// mount context does not carry it and `workspace.list` only has a session-wide
// `focused` flag. We use, in order: `ctx.workspace` (proposed mount context
// field), then the focused workspace from `workspace.list`.

import { appError } from "./errors.ts"
import type { WorkspaceRef } from "./model.ts"

type Snapshot = Cmux.WorkspaceSnapshot

export interface Workspaces {
  /** Every workspace of the session (empty while loading or without `workspace:read`). */
  list: () => Snapshot[]
  current: () => WorkspaceRef | null
  /** Name of a workspace that still exists, else null (the note keeps its stored name). */
  liveName: (id: string) => string | null
  loading: () => boolean
  error: () => string | null
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
  return {
    list,
    current,
    liveName: (id) => list().find((w) => w.id === id)?.name ?? null,
    loading: () => live.loading(),
    error: () => live.error()?.code ?? null
  }
}

/**
 * Resolves a command's `workspace` argument: an id, "current" (the focused
 * workspace), or a workspace name. Returns null when absent; throws when it
 * names nothing.
 */
export async function resolveWorkspace(arg: unknown): Promise<WorkspaceRef | null> {
  if (arg === undefined || arg === null || arg === "") return null
  if (typeof arg !== "string") throw appError("invalid_params", "workspace must be a string: an id, a name or \"current\"")
  const all = await cmux.workspace.list({})
  const hit = arg === "current" ? all.find((w) => w.focused) : all.find((w) => w.id === arg) ?? all.find((w) => w.name === arg)
  if (!hit) throw appError("workspace.not_found", `no workspace ${arg}`)
  return { id: hit.id, name: hit.name }
}
