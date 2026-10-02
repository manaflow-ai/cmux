// Hunk model for review: per-hunk decisions, per-file rollup, side-by-side rows,
// draft comments. Pure functions over plain data; the views keep one signal.

import type { DiffDecision } from "../interfaces/diff.ts"
import type { DiffLine, FileDiff, Hunk } from "./unified.ts"

export type Decision = "accept" | "reject"
export type FileDecision = Decision | "partial" | "pending"

export interface ReviewState {
  /** Hunk id -> decision. */
  hunks: Record<string, Decision>
  /** Decisions the owner has confirmed (sent and acknowledged). */
  confirmed: Record<string, Decision>
  comments: DraftComment[]
}

export interface DraftComment {
  id: string
  path: string
  line: number
  side: "old" | "new"
  body: string
}

export const emptyReview = (): ReviewState => ({ hunks: {}, confirmed: {}, comments: [] })

export function decideHunk(state: ReviewState, hunk: string, decision: Decision | null): ReviewState {
  const hunks = { ...state.hunks }
  if (decision === null || hunks[hunk] === decision) delete hunks[hunk]
  else hunks[hunk] = decision
  return { ...state, hunks }
}

export function decideFile(state: ReviewState, file: FileDiff, decision: Decision | null): ReviewState {
  const hunks = { ...state.hunks }
  for (const h of file.hunks) {
    if (decision === null) delete hunks[h.id]
    else hunks[h.id] = decision
  }
  return { ...state, hunks }
}

export function fileDecision(state: ReviewState, file: FileDiff): FileDecision {
  if (!file.hunks.length) return "pending"
  const ds = file.hunks.map((h) => state.hunks[h.id])
  if (ds.every((d) => d === "accept")) return "accept"
  if (ds.every((d) => d === "reject")) return "reject"
  return ds.some((d) => d) ? "partial" : "pending"
}

export interface ReviewCounts { files: number; hunks: number; accepted: number; rejected: number; pending: number }

export function counts(state: ReviewState, files: readonly FileDiff[]): ReviewCounts {
  const all = files.flatMap((f) => f.hunks)
  const accepted = all.filter((h) => state.hunks[h.id] === "accept").length
  const rejected = all.filter((h) => state.hunks[h.id] === "reject").length
  return { files: files.length, hunks: all.length, accepted, rejected, pending: all.length - accepted - rejected }
}

/** Decisions not yet confirmed by the owner, as the `diff.decide` payload. */
export function unsentDecisions(state: ReviewState, files: readonly FileDiff[]): DiffDecision[] {
  const out: DiffDecision[] = []
  for (const f of files) {
    const fd = fileDecision(state, f)
    const allUnsent = f.hunks.every((h) => state.confirmed[h.id] !== state.hunks[h.id])
    if ((fd === "accept" || fd === "reject") && allUnsent) {
      out.push({ path: f.path, decision: fd })
      continue
    }
    for (const h of f.hunks) {
      const d = state.hunks[h.id]
      if (d && state.confirmed[h.id] !== d) out.push({ path: f.path, hunk: h.id, decision: d })
    }
  }
  return out
}

export function confirm(state: ReviewState, files: readonly FileDiff[], sent: readonly DiffDecision[]): ReviewState {
  const confirmed = { ...state.confirmed }
  for (const d of sent) {
    const file = files.find((f) => f.path === d.path)
    if (!file) continue
    for (const h of file.hunks) if (!d.hunk || d.hunk === h.id) confirmed[h.id] = d.decision
  }
  return { ...state, confirmed }
}

/** Seeds decisions the owner already recorded (reopening a review). */
export function fromOwner(files: readonly FileDiff[], decisions: readonly DiffDecision[] | undefined): ReviewState {
  let state = emptyReview()
  for (const d of decisions ?? []) {
    const file = files.find((f) => f.path === d.path)
    if (!file) continue
    state = d.hunk ? decideHunk(state, d.hunk, d.decision) : decideFile(state, file, d.decision)
  }
  return { ...state, confirmed: { ...state.hunks } }
}

export function addComment(state: ReviewState, c: Omit<DraftComment, "id">, id: string): ReviewState {
  const body = c.body.trim()
  if (!body) return state
  return { ...state, comments: [...state.comments, { ...c, body, id }] }
}

export const removeComment = (state: ReviewState, id: string): ReviewState => ({ ...state, comments: state.comments.filter((c) => c.id !== id) })

export const commentsAt = (state: ReviewState, path: string, line: DiffLine) =>
  state.comments.filter((c) => c.path === path && ((c.side === "new" && c.line === line.newLine) || (c.side === "old" && line.newLine === null && c.line === line.oldLine)))

/** Verdict a review answer carries: any rejection or comment asks for changes. */
export function verdict(state: ReviewState, files: readonly FileDiff[]): "approve" | "request_changes" | "comment" {
  const c = counts(state, files)
  if (c.rejected > 0) return "request_changes"
  if (c.pending === 0 && c.hunks > 0) return "approve"
  return "comment"
}

export interface SideRow {
  left: DiffLine | null
  right: DiffLine | null
}

/** Pairs a hunk's lines for a side-by-side view: each run of deletions sits beside the following additions. */
export function sideBySide(hunk: Hunk): SideRow[] {
  const rows: SideRow[] = []
  const lines = hunk.lines
  let i = 0
  while (i < lines.length) {
    const l = lines[i]!
    if (l.kind === "context") {
      rows.push({ left: l, right: l })
      i++
      continue
    }
    const dels: DiffLine[] = []
    const adds: DiffLine[] = []
    while (i < lines.length && lines[i]!.kind === "del") dels.push(lines[i++]!)
    while (i < lines.length && lines[i]!.kind === "add") adds.push(lines[i++]!)
    for (let k = 0; k < Math.max(dels.length, adds.length); k++) rows.push({ left: dels[k] ?? null, right: adds[k] ?? null })
  }
  return rows
}
