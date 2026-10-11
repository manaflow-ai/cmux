// The review of one memory edit. Every write shows its diff first; the text
// reaches the app only through a document handle, and the write is a
// document.edit against the revision the diff was made from. States:
//   idle -> preparing (read the document, apply the intent) -> review
//   review -> applying -> applied
//   applying -> stale -> preparing (once: read again, apply the same intent) -> review (note "rebased")
//   preparing -> gone (the entry no longer exists) | failed ; review -> idle (Cancel)

import type { Intent } from "./edits.ts"

export type FileRef = { root: string; path: string; label: string }
export type Prepared = { doc: string; revision: string; before: string; after: string }

type Base = { file: FileRef; intent: Intent; title: string }
export type ReviewState =
  | { phase: "idle" }
  | (Base & { phase: "preparing"; rebases: number })
  | (Base & Prepared & { phase: "review"; rebases: number; note: "rebased" | null })
  | (Base & Prepared & { phase: "applying"; rebases: number })
  | (Base & { phase: "applied" })
  | (Base & { phase: "gone" })
  | (Base & { phase: "failed"; code: string; message: string })

export type ReviewEvent =
  | { type: "ask"; file: FileRef; intent: Intent; title: string }
  | { type: "prepared"; prepared: Prepared }
  | { type: "apply" }
  | { type: "applied" }
  | { type: "stale" }
  | { type: "gone" }
  | { type: "error"; code: string; message: string }
  | { type: "cancel" }

export const MAX_REBASES = 1

const base = (s: Base): Base => ({ file: s.file, intent: s.intent, title: s.title })

export function reduceReview(s: ReviewState, ev: ReviewEvent): ReviewState {
  switch (ev.type) {
    case "ask":
      return s.phase === "applying" ? s : { phase: "preparing", file: ev.file, intent: ev.intent, title: ev.title, rebases: 0 }
    case "prepared":
      return s.phase === "preparing" ? { ...base(s), ...ev.prepared, phase: "review", rebases: s.rebases, note: s.rebases > 0 ? "rebased" : null } : s
    case "apply":
      return s.phase === "review" ? { ...base(s), doc: s.doc, revision: s.revision, before: s.before, after: s.after, phase: "applying", rebases: s.rebases } : s
    case "applied":
      return s.phase === "applying" ? { ...base(s), phase: "applied" } : s
    case "stale":
      if (s.phase !== "applying") return s
      return s.rebases >= MAX_REBASES ? { ...base(s), phase: "failed", code: "document.stale", message: "" } : { ...base(s), phase: "preparing", rebases: s.rebases + 1 }
    case "gone":
      return s.phase === "preparing" ? { ...base(s), phase: "gone" } : s
    case "error":
      return s.phase === "preparing" || s.phase === "applying" ? { ...base(s), phase: "failed", code: ev.code, message: ev.message } : s
    case "cancel":
      return s.phase === "applying" ? s : { phase: "idle" }
  }
}

export const busyReview = (s: ReviewState) => s.phase === "preparing" || s.phase === "applying"
