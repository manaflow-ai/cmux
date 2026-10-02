// Document session state machine for one editor view (shared by the editor
// apps; identical copies in first-party-apps/{monaco,codemirror}/src/shared).
//
// The owner (document host) holds the buffer, revision and dirty flag. The
// view applies typing at once and keeps the owner in step with one edit in
// flight at a time: the edit is the single replacement that turns the last
// confirmed text into the current view text. A stale base is rejected by the
// owner; the view resyncs, rebases its own change onto the owner's text and
// sends again. Pure: `reduce` returns the next state plus effects for the
// controller to run.

import { DOC_ERRORS, sameRevision, type DocConflict, type DocInfo, type DocRevision, type DocumentChangedEvent, type TextEdit } from "../interfaces/document.ts"

export type Phase = "loading" | "ready" | "saving" | "conflict" | "error" | "closed"
export type Notice = "saved" | "reloaded" | "merged" | "readOnly" | null

export interface DocState {
  phase: Phase
  info: DocInfo | null
  /** Text at `revision` as the owner confirmed it. */
  confirmedText: string
  revision: DocRevision | null
  /** Text the view shows. */
  viewText: string
  inflight: { id: number; text: string } | null
  dirty: boolean
  /** The owner or the host made it read-only. */
  readOnly: boolean
  /** Read-only because the embedding app or the user asked (prop). */
  readOnlyProp: boolean
  conflict: DocConflict | null
  notice: Notice
  error: { code: string; message: string } | null
  saveQueued: boolean
  nextId: number
}

export type DocEvent =
  | { type: "opened"; info: DocInfo; text: string }
  | { type: "openFailed"; code: string; message: string }
  | { type: "viewChanged"; text: string }
  | { type: "editAcked"; id: number; revision: DocRevision; dirty: boolean }
  | { type: "editFailed"; id: number; code: string; message: string }
  | { type: "remoteChanged"; event: DocumentChangedEvent; ownOrigin: string }
  | { type: "conflict"; diskRevision: DocRevision; bufferRevision: DocRevision }
  | { type: "saveRequested" }
  | { type: "saved"; revision: DocRevision }
  | { type: "saveFailed"; code: string; message: string; diskRevision?: DocRevision }
  | { type: "resolve"; keep: "buffer" | "disk" }
  | { type: "setReadOnly"; readOnly: boolean }
  | { type: "closed" }

export type DocEffect =
  | { type: "setView"; text: string; edits: TextEdit[] }
  | { type: "sendEdit"; id: number; base: DocRevision; edits: TextEdit[] }
  | { type: "save"; revision: DocRevision; overwriteDisk: boolean }
  | { type: "revert" }
  | { type: "resync" }

export const initialDocState = (): DocState => ({
  phase: "loading",
  info: null,
  confirmedText: "",
  revision: null,
  viewText: "",
  inflight: null,
  dirty: false,
  readOnly: false,
  readOnlyProp: false,
  conflict: null,
  notice: null,
  error: null,
  saveQueued: false,
  nextId: 1
})

/** The single replacement that turns `a` into `b` (common prefix and suffix), or null when equal. */
export function region(a: string, b: string): TextEdit | null {
  if (a === b) return null
  let p = 0
  const max = Math.min(a.length, b.length)
  while (p < max && a.charCodeAt(p) === b.charCodeAt(p)) p++
  let s = 0
  while (s < max - p && a.charCodeAt(a.length - 1 - s) === b.charCodeAt(b.length - 1 - s)) s++
  return { from: p, to: a.length - s, text: b.slice(p, b.length - s) }
}

export function applyEdits(text: string, edits: readonly TextEdit[]): string {
  let out = text
  for (const e of edits) {
    if (e.from < 0 || e.to < e.from || e.to > out.length) throw new RangeError(`edit ${e.from}-${e.to} outside 0-${out.length}`)
    out = out.slice(0, e.from) + e.text + out.slice(e.to)
  }
  return out
}

const applyOne = (text: string, e: TextEdit) => text.slice(0, e.from) + e.text + text.slice(e.to)

/**
 * Three-way rebase of the view's change onto the owner's new text. Changes in
 * different places both apply. When they overlap, the owner's change applies
 * and the view's text follows it, so nothing typed is lost; the controller
 * shows a "merged" notice.
 */
export function rebase(base: string, ours: string, theirs: string): { text: string; overlapped: boolean } {
  const o = region(base, ours)
  const th = region(base, theirs)
  if (!o) return { text: theirs, overlapped: false }
  if (!th) return { text: ours, overlapped: false }
  if (o.from >= th.to && !(o.from === th.to && th.from === th.to && o.from === o.to)) return { text: applyOne(applyOne(base, o), th), overlapped: false }
  if (o.to <= th.from) return { text: applyOne(applyOne(base, th), o), overlapped: false }
  const after = th.from + th.text.length
  return { text: theirs.slice(0, after) + o.text + theirs.slice(after), overlapped: true }
}

const editable = (s: DocState) => !s.readOnly && !s.readOnlyProp

function maybeSend(s: DocState, effects: DocEffect[]): DocState {
  if (s.inflight || !s.revision || s.phase === "loading" || s.phase === "closed" || s.phase === "error") return s
  const edit = region(s.confirmedText, s.viewText)
  if (!edit) {
    if (s.saveQueued && s.phase !== "conflict") {
      effects.push({ type: "save", revision: s.revision, overwriteDisk: false })
      return { ...s, saveQueued: false, phase: "saving" }
    }
    return s
  }
  const id = s.nextId
  effects.push({ type: "sendEdit", id, base: s.revision, edits: [edit] })
  return { ...s, inflight: { id, text: s.viewText }, nextId: id + 1 }
}

function opened(s: DocState, info: DocInfo, text: string, effects: DocEffect[], notice: Notice): DocState {
  const edit = region(s.viewText, text)
  if (edit) effects.push({ type: "setView", text, edits: [edit] })
  return {
    ...s,
    phase: info.conflict ? "conflict" : "ready",
    info,
    confirmedText: text,
    viewText: text,
    revision: info.revision,
    inflight: null,
    dirty: info.dirty,
    readOnly: info.readOnly,
    conflict: info.conflict,
    notice,
    error: null
  }
}

export function reduce(s: DocState, ev: DocEvent): { state: DocState; effects: DocEffect[] } {
  const effects: DocEffect[] = []
  const done = (state: DocState) => ({ state, effects })
  switch (ev.type) {
    case "opened":
      return done(opened(s, ev.info, ev.text, effects, null))
    case "openFailed":
      return done({ ...s, phase: "error", error: { code: ev.code, message: ev.message } })
    case "viewChanged": {
      if (ev.text === s.viewText) return done(s)
      if (!editable(s) || s.phase === "loading" || s.phase === "closed") {
        // The view must not diverge from a read-only buffer: put the text back.
        effects.push({ type: "setView", text: s.viewText, edits: [region(ev.text, s.viewText)!] })
        return done({ ...s, notice: "readOnly" })
      }
      return done(maybeSend({ ...s, viewText: ev.text, dirty: true, notice: null }, effects))
    }
    case "editAcked": {
      if (!s.inflight || s.inflight.id !== ev.id) return done(s)
      const confirmedText = s.inflight.text
      const next = { ...s, confirmedText, revision: ev.revision, inflight: null, dirty: ev.dirty || s.viewText !== confirmedText }
      return done(maybeSend(next, effects))
    }
    case "editFailed": {
      if (!s.inflight || s.inflight.id !== ev.id) return done(s)
      const next = { ...s, inflight: null }
      if (ev.code === DOC_ERRORS.stale) {
        effects.push({ type: "resync" })
        return done(next)
      }
      if (ev.code === DOC_ERRORS.readOnly) {
        effects.push({ type: "setView", text: s.confirmedText, edits: [region(s.viewText, s.confirmedText)!].filter(Boolean) })
        return done({ ...next, readOnly: true, viewText: s.confirmedText, notice: "readOnly" })
      }
      return done({ ...next, error: { code: ev.code, message: ev.message } })
    }
    case "remoteChanged": {
      const e = ev.event
      if (s.revision && sameRevision(e.revision, s.revision)) return done(s)
      if (e.origin === ev.ownOrigin && s.inflight) {
        // Our own edit echoed back: it is the acknowledgement.
        const confirmedText = s.inflight.text
        return done(maybeSend({ ...s, confirmedText, revision: e.revision, inflight: null, dirty: e.dirty || s.viewText !== confirmedText }, effects))
      }
      if (!s.revision || !sameRevision(e.base_revision, s.revision)) {
        effects.push({ type: "resync" })
        return done(s)
      }
      let theirs: string
      try {
        theirs = applyEdits(s.confirmedText, e.edits)
      } catch {
        effects.push({ type: "resync" })
        return done(s)
      }
      const { text, overlapped } = rebase(s.confirmedText, s.viewText, theirs)
      const edit = region(s.viewText, text)
      if (edit) effects.push({ type: "setView", text, edits: [edit] })
      const clean = text === theirs
      const notice: Notice = overlapped ? "merged" : e.origin === "disk" && clean ? "reloaded" : s.notice
      // A pending in-flight edit has a stale base now; the owner rejects it and we resend.
      return done(maybeSend({ ...s, confirmedText: theirs, revision: e.revision, viewText: text, inflight: null, dirty: e.dirty || !clean, notice }, effects))
    }
    case "conflict":
      return done({ ...s, phase: "conflict", conflict: { diskRevision: ev.diskRevision, bufferRevision: ev.bufferRevision }, saveQueued: false })
    case "saveRequested": {
      if (!editable(s)) return done({ ...s, notice: "readOnly" })
      if (s.phase === "conflict" || s.phase === "saving" || !s.revision) return done(s)
      if (s.inflight || s.viewText !== s.confirmedText) return done(maybeSend({ ...s, saveQueued: true }, effects))
      effects.push({ type: "save", revision: s.revision, overwriteDisk: false })
      return done({ ...s, phase: "saving" })
    }
    case "saved":
      return done({ ...s, phase: "ready", revision: ev.revision, dirty: s.viewText !== s.confirmedText, conflict: null, notice: "saved", error: null })
    case "saveFailed":
      if (ev.code === DOC_ERRORS.conflict) {
        const conflict = ev.diskRevision && s.revision ? { diskRevision: ev.diskRevision, bufferRevision: s.revision } : s.conflict
        return done({ ...s, phase: "conflict", conflict })
      }
      return done({ ...s, phase: "ready", error: { code: ev.code, message: ev.message } })
    case "resolve":
      if (s.phase !== "conflict" || !s.revision) return done(s)
      if (ev.keep === "buffer") {
        effects.push({ type: "save", revision: s.revision, overwriteDisk: true })
        return done({ ...s, phase: "saving" })
      }
      effects.push({ type: "revert" })
      return done({ ...s, phase: "loading" })
    case "setReadOnly":
      return done({ ...s, readOnlyProp: ev.readOnly })
    case "closed":
      return done({ ...s, phase: "closed" })
  }
}

/** Reopen or revert result: same as opened, with the "reloaded" notice when the text changed. */
export function reopened(s: DocState, info: DocInfo, text: string): { state: DocState; effects: DocEffect[] } {
  const effects: DocEffect[] = []
  if (s.inflight || s.viewText !== s.confirmedText) {
    // Resync with local changes: rebase them onto the owner's text.
    const { text: merged, overlapped } = rebase(s.confirmedText, s.viewText, text)
    const edit = region(s.viewText, merged)
    if (edit) effects.push({ type: "setView", text: merged, edits: [edit] })
    const state = { ...s, info, confirmedText: text, revision: info.revision, viewText: merged, inflight: null, readOnly: info.readOnly, conflict: info.conflict, phase: (info.conflict ? "conflict" : "ready") as Phase, notice: overlapped ? ("merged" as Notice) : s.notice }
    return { state: maybeSend(state, effects), effects }
  }
  const state = opened(s, info, text, effects, text !== s.confirmedText ? "reloaded" : s.notice)
  return { state, effects }
}
