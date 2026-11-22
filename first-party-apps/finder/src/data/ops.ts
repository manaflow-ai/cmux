// Every operation the app calls. None of the fs.*, host.*, document.* or
// open.* ops exist yet: they are the proposals in plans/cmux-next/finder.md,
// called through `cmux.call` so the app shows what is missing when the host
// answers operation.unsupported or scope.missing.

import type { Entry, Filter, Sort } from "../model/entries.ts"
import type { Rights, DragItem } from "../model/drag.ts"
import type { Batch } from "../model/listing.ts"
import type { Conflict, ConflictChoice, JobOp } from "../model/jobs.ts"

export type ConnKind = "local" | "server" | "team_vm" | "cloud_vm" | "ssh"
export type ConnState = "connected" | "connecting" | "verifying" | "needs_auth" | "disconnected" | "unreachable"

/** A connection handle the shell gave this app (finder.md 3.1). `host` is the public `host_…` id for cmux endpoints, null for plain SSH. */
export type Conn = { conn: string; host: string | null; kind: ConnKind; label: string; state: ConnState; path?: string | null; detail?: string | null }

/** A root handle (finder.md 2.1); `display` is the owner's display path, never parsed. */
export type Root = { root: string; conn: string; label: string; kind: "home" | "folder" | "workspace" | "volume" | "remote"; display: string; rights: Rights; pinned?: boolean }

export type OpError = { code: string; message: string; missing: boolean; retryable: boolean; op: string }
export type OpResult<T> = { ok: true; value: T } | { ok: false; error: OpError }

const MISSING = new Set(["operation.unsupported", "scope.missing"])

export function toOpError(e: unknown, op = ""): OpError {
  const err = e as { code?: unknown; message?: unknown; retryable?: unknown } | null
  const code = typeof err?.code === "string" ? err.code : "internal"
  const message = typeof err?.message === "string" ? err.message : String(e)
  return { code, message, missing: MISSING.has(code), retryable: err?.retryable === true, op }
}

export async function call<T>(name: string, params: Record<string, unknown> = {}, options: CmuxCallOptions = {}): Promise<OpResult<T>> {
  try {
    return { ok: true, value: (await cmux.call(name, params, options)) as T }
  } catch (e) {
    return { ok: false, error: toOpError(e, name) }
  }
}

export type Where = { conn: string; root: string; path: string }

export const ops = {
  hosts: () => call<{ conns: Conn[] }>("host.list"),
  connect: (gesture: string | null, conn?: string) => call<{ conn: Conn }>("host.connect", conn ? { conn } : {}, { gesture: gesture ?? undefined }),
  disconnect: (conn: string) => call<{ conn: Conn }>("host.disconnect", { conn }),
  roots: () => call<{ roots: Root[] }>("fs.roots.list"),
  pickRoot: (gesture: string | null, conn?: string) => call<{ root: Root }>("fs.root.pick", { mode: "folder", ...(conn ? { conn } : {}) }, { gesture: gesture ?? undefined }),
  list: (w: Where, sort: Sort, filter: Filter, limit: number, cursor: string | null, listing: string | null) =>
    call<Batch>("fs.list", {
      ...w,
      sort: { key: sort.key, dir: sort.dir, dirs_first: sort.dirsFirst },
      filter: { query: filter.query || undefined, hidden: filter.hidden },
      limit,
      ...(cursor ? { cursor, listing } : {})
    }),
  read: (w: Where, maxBytes: number) => call<{ text: string | null; truncated: boolean; size: number; encoding: "utf8" | "binary" }>("fs.read", { ...w, max_bytes: maxBytes }),
  thumbnail: (w: Where, size: number) => call<{ image: string; width: number; height: number; pages?: number }>("fs.thumbnail", { ...w, size }),
  mkdir: (w: Where, name: string, gesture: string | null) => call<{ entry: Entry }>("fs.mkdir", { ...w, name }, { gesture: gesture ?? undefined }),
  rename: (w: Where, name: string, gesture: string | null) => call<{ entry: Entry; undo: string | null }>("fs.rename", { ...w, name }, { gesture: gesture ?? undefined }),
  transfer: (op: Extract<JobOp, "copy" | "move">, from: { conn: string; root: string; paths: string[] }, to: Where, gesture: string | null) =>
    call<{ job: string; subject: string; destination: string; cross_host: boolean }>(`fs.${op}`, { from, to, conflict: "ask" }, { gesture: gesture ?? undefined }),
  trash: (w: { conn: string; root: string; paths: string[] }, gesture: string | null) =>
    call<{ job: string; subject: string; destination: string; cross_host: boolean }>("fs.trash", w, { gesture: gesture ?? undefined }),
  jobs: () => call<{ jobs: Array<JobSnapshot> }>("fs.job.list"),
  cancelJob: (job: string) => call<Record<string, never>>("fs.job.cancel", { job }),
  resolveJob: (job: string, choice: ConflictChoice, applyToAll: boolean, gesture: string | null) =>
    call<Record<string, never>>("fs.job.resolve", { job, choice, apply_to_all: applyToAll }, { gesture: gesture ?? undefined }),
  undo: (undo: string, gesture: string | null) => call<Record<string, never>>("fs.undo", { undo }, { gesture: gesture ?? undefined }),
  openDocument: (w: Where, gesture: string | null) => call<{ doc: string; opened_with: string | null }>("document.open", { ...w, show: true }, { gesture: gesture ?? undefined }),
  dropOnTerminal: (items: DragItem[], gesture: string | null) => call<{ action: string }>("terminal.drop", { items }, { gesture: gesture ?? undefined }),
  attachToAgent: (items: DragItem[], gesture: string | null) => call<{ attached: number }>("agent.attach", { items }, { gesture: gesture ?? undefined }),
  openPane: (gesture: string | null) => call<Record<string, never>>("app.pane.open", { kind: "browser" }, { gesture: gesture ?? undefined })
}

/** A job as `fs.job.list` reports it (the state the owner holds). */
export type JobSnapshot = {
  job: string
  op: JobOp
  phase: string
  seq: number
  subject: string
  destination: string
  cross_host: boolean
  bytes_done: number
  bytes_total: number | null
  items_done: number
  items_total: number | null
  current: string | null
  eta_s?: number | null
  conflict: Conflict | null
  undo: string | null
  started_at: number
}
