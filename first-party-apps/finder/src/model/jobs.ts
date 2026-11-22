// File operation jobs (finder.md section 5): `fs.copy` / `fs.move` / `fs.trash`
// return a `job_…` handle at once; the owner streams `fs.job` events. This is
// the client half of the state machine. The owner is authoritative: the client
// only applies events in `seq` order and marks its own requests (cancel,
// resolve) as pending until the owner confirms them.
//
//   queued -> preparing -> running <-> conflict
//   running | conflict | preparing | queued -> cancelling -> cancelled
//   running -> done | failed      (done, failed, cancelled are terminal)

export type JobOp = "copy" | "move" | "trash" | "delete"
export type JobPhase = "queued" | "preparing" | "running" | "conflict" | "cancelling" | "done" | "failed" | "cancelled"
export type ConflictChoice = "replace" | "skip" | "keep_both"

export type Conflict = { item: string; existing: { size: number | null; mtime: number | null }; incoming: { size: number | null; mtime: number | null } }

export type Job = {
  id: string
  op: JobOp
  phase: JobPhase
  seq: number
  /** What the user sees: "3 items", "report.pdf"; destination label from the owner. */
  subject: string
  destination: string
  crossHost: boolean
  bytes: { done: number; total: number | null }
  items: { done: number; total: number | null }
  current: string | null
  /** The owner's estimate (it measures the real throughput between the two hosts); null until it has one. */
  eta: number | null
  conflict: Conflict | null
  /** A request the client sent and the owner has not answered yet. */
  pending: "cancel" | "resolve" | null
  error: { code: string; message: string } | null
  /** Undo handle when the owner can reverse the job (move and trash on one host; copy deletes what it made). */
  undo: string | null
  startedAt: number
  updatedAt: number
}

export type JobEvent =
  | { kind: "preparing"; seq: number; items_total?: number | null; bytes_total?: number | null }
  | { kind: "progress"; seq: number; bytes_done: number; bytes_total?: number | null; items_done: number; items_total?: number | null; current?: string | null; eta_s?: number | null }
  | { kind: "conflict"; seq: number; conflict: Conflict }
  | { kind: "resolved"; seq: number }
  | { kind: "cancelling"; seq: number }
  | { kind: "done"; seq: number; undo?: string | null; items_done?: number; bytes_done?: number }
  | { kind: "failed"; seq: number; error: { code: string; message: string } }
  | { kind: "cancelled"; seq: number }

export type JobAction =
  | { type: "event"; event: JobEvent; at: number }
  | { type: "requestCancel" }
  | { type: "requestResolve" }
  | { type: "requestFailed"; error: { code: string; message: string } }

export const TERMINAL: readonly JobPhase[] = ["done", "failed", "cancelled"]
export const isTerminal = (j: Job) => TERMINAL.includes(j.phase)

export function newJob(init: { id: string; op: JobOp; subject: string; destination: string; crossHost: boolean; at: number }): Job {
  return {
    ...init,
    phase: "queued",
    seq: 0,
    bytes: { done: 0, total: null },
    items: { done: 0, total: null },
    current: null,
    eta: null,
    conflict: null,
    pending: null,
    error: null,
    undo: null,
    startedAt: init.at,
    updatedAt: init.at
  }
}

const ALLOWED: Record<JobEvent["kind"], readonly JobPhase[]> = {
  preparing: ["queued"],
  progress: ["queued", "preparing", "running", "conflict"],
  conflict: ["preparing", "running"],
  resolved: ["conflict"],
  cancelling: ["queued", "preparing", "running", "conflict"],
  done: ["queued", "preparing", "running", "cancelling"],
  failed: ["queued", "preparing", "running", "conflict", "cancelling"],
  cancelled: ["queued", "preparing", "running", "conflict", "cancelling"]
}

export function reduceJob(j: Job, a: JobAction): Job {
  switch (a.type) {
    case "requestCancel":
      return isTerminal(j) || j.phase === "cancelling" ? j : { ...j, pending: "cancel" }
    case "requestResolve":
      return j.phase === "conflict" ? { ...j, pending: "resolve" } : j
    case "requestFailed":
      return { ...j, pending: null, error: a.error }
  }
  const ev = a.event
  // Events are applied once, in order; a late or repeated one is dropped. Terminal states absorb.
  if (ev.seq <= j.seq || isTerminal(j) || !ALLOWED[ev.kind].includes(j.phase)) return j
  const base = { ...j, seq: ev.seq, updatedAt: a.at }
  switch (ev.kind) {
    case "preparing":
      return { ...base, phase: "preparing", items: { done: 0, total: ev.items_total ?? null }, bytes: { done: 0, total: ev.bytes_total ?? null } }
    case "progress":
      return {
        ...base,
        // A conflict pauses the copy; progress for other items in a parallel copy may still arrive.
        phase: j.phase === "conflict" ? "conflict" : "running",
        bytes: { done: Math.max(j.bytes.done, ev.bytes_done), total: ev.bytes_total ?? j.bytes.total },
        items: { done: Math.max(j.items.done, ev.items_done), total: ev.items_total ?? j.items.total },
        current: ev.current ?? j.current,
        eta: ev.eta_s ?? null
      }
    case "conflict":
      return { ...base, phase: "conflict", conflict: ev.conflict, pending: null }
    case "resolved":
      return { ...base, phase: "running", conflict: null, pending: null }
    case "cancelling":
      return { ...base, phase: "cancelling", pending: null }
    case "done":
      return {
        ...base,
        phase: "done",
        pending: null,
        conflict: null,
        current: null,
        undo: ev.undo ?? null,
        items: { done: ev.items_done ?? j.items.total ?? j.items.done, total: j.items.total },
        bytes: { done: ev.bytes_done ?? j.bytes.total ?? j.bytes.done, total: j.bytes.total }
      }
    case "failed":
      return { ...base, phase: "failed", pending: null, error: ev.error, current: null }
    case "cancelled":
      return { ...base, phase: "cancelled", pending: null, conflict: null, current: null }
  }
}

/** 0..1 for a progress bar, or null for an indeterminate one. */
export function fraction(j: Job): number | null {
  if (j.phase === "done") return 1
  if (j.bytes.total && j.bytes.total > 0) return Math.min(1, j.bytes.done / j.bytes.total)
  if (j.items.total && j.items.total > 0) return Math.min(1, j.items.done / j.items.total)
  return null
}

/** Seconds left: the owner's estimate, else the average rate since start; null until there is enough signal. */
export function secondsLeft(j: Job, now: number): number | null {
  if (j.phase !== "running") return null
  if (j.eta !== null) return j.eta
  if (!j.bytes.total || j.bytes.done <= 0) return null
  const elapsed = (now - j.startedAt) / 1000
  if (elapsed < 1) return null
  const rate = j.bytes.done / elapsed
  return rate > 0 ? Math.ceil((j.bytes.total - j.bytes.done) / rate) : null
}

export const canCancel = (j: Job) => !isTerminal(j) && j.phase !== "cancelling" && j.pending !== "cancel"
export const canUndo = (j: Job) => j.phase === "done" && !!j.undo
