/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// What this app shows of the notes server: note summaries (from `note.list`,
// then the typed `note.watch` stream) and the bodies a surface displays
// (`note.get`, refreshed when a newer revision arrives). The server owns every
// note; this is a projection, so a write from an agent, another device or the
// native editor shows up here through the stream, never by polling.

import { applyEdits, rebaseLine, toggleEdit } from "./model.ts"
import { api, NOTE_STREAM, type Note, type NoteEvent, type NoteSummary, type SortOrder } from "./notes.ts"

const [summaries, setSummaries] = signal<NoteSummary[]>([])
const [bodies, setBodies] = signal<ReadonlyMap<string, { revision: number; body: string }>>(new Map())
const [ready, setReady] = signal(false)
const [loadError, setLoadError] = signal<{ code: string; message: string } | null>(null)
const [saveError, setSaveError] = signal<string | null>(null)

export { summaries, ready, loadError, saveError }

export const codeOf = (e: unknown) => (e && typeof e === "object" && "code" in e ? String((e as { code: unknown }).code) : "")
export const messageOf = (e: unknown) => (e instanceof Error ? e.message : String(e))

let loading: Promise<void> | null = null
let lastSeq = 0

/** Summaries of every note (the server caps a user at 2000 notes, so one page holds them). */
async function loadOnce(): Promise<void> {
  const r = await api.list({ limit: 2000 })
  setSummaries(r.notes)
}

/**
 * Loads once per app VM; every surface and command awaits the same promise. A
 * failed load is retried on the next call. The stream subscription belongs to
 * the mount that asked first (`attach` re-subscribes for each mount).
 */
export function ensureLoaded(): Promise<void> {
  if (!loading) {
    loading = loadOnce().then(
      () => {
        setLoadError(null)
        setReady(true)
      },
      (e) => {
        loading = null
        setLoadError({ code: codeOf(e), message: messageOf(e) })
        throw e
      }
    )
  }
  return loading
}

/** Applies one note: a newer revision replaces the summary and any cached body it makes stale. */
function upsert(note: NoteSummary | Note): void {
  const current = summaries().find((n) => n.id === note.id)
  if (current && current.revision > note.revision) return
  const { body, ...summary } = note as Note
  setSummaries((list) => (current ? list.map((n) => (n.id === note.id ? summary : n)) : [...list, summary]))
  if (typeof body === "string") setBodies((m) => new Map(m).set(note.id, { revision: note.revision, body }))
}

function remove(id: string): void {
  setSummaries((list) => list.filter((n) => n.id !== id))
  setBodies((m) => {
    const next = new Map(m)
    next.delete(id)
    return next
  })
}

function onEvent(payload: unknown): void {
  const ev = payload as NoteEvent
  if (!ev || !ev.note || typeof ev.note.id !== "string") return
  // The stream is at-least-once: an event seen twice changes nothing.
  if (typeof ev.seq === "number") {
    if (ev.seq <= lastSeq) return
    lastSeq = ev.seq
  }
  if (ev.kind === "deleted") return remove(ev.note.id)
  upsert(ev.note)
}

/** Subscribes the calling mount to the server's stream (the subscription ends with the mount). */
export function attach(): void {
  cmux.events.on(NOTE_STREAM, onEvent)
  ensureLoaded().catch(() => undefined) // the status row shows the error
}

export const findSummary = (id: string) => summaries().find((n) => n.id === id) ?? null

const inflight = new Set<string>()

/**
 * The body of a note a surface shows, fetched when missing or older than the
 * summary's revision; null until it arrives.
 */
export function bodyOf(id: string): string | null {
  const summary = findSummary(id)
  const cached = bodies().get(id)
  if (summary && (!cached || cached.revision < summary.revision) && !inflight.has(id)) {
    inflight.add(id)
    api
      .get(id)
      .then(upsert, (e: unknown) => setSaveError(messageOf(e)))
      .finally(() => inflight.delete(id))
  }
  return cached?.body ?? null
}

/** Runs a write; its result (the note at the new revision) applies at once, the stream echo is ignored. */
async function write(fn: () => Promise<Note>): Promise<Note | null> {
  try {
    const note = await fn()
    upsert(note)
    setSaveError(null)
    return note
  } catch (e) {
    setSaveError(messageOf(e))
    throw e
  }
}

export const appendTo = (target: { note: string } | { workspace: string }, text: string) => write(() => api.append({ ...target, text }))
export const createNote = (params: Parameters<typeof api.create>[0], key?: string) => write(() => api.create(params, key))
export const updateNote = (id: string, change: Parameters<typeof api.update>[1]) => write(() => api.update(id, change))

export async function deleteNote(id: string): Promise<void> {
  try {
    await api.delete(id)
    remove(id)
  } catch (e) {
    setSaveError(messageOf(e))
    throw e
  }
}

/**
 * Toggles the checkbox on one line through the note's document
 * (`document.edit` with the revision the line was read at). When someone else
 * wrote first, the edit is rebased once onto the current text: the same line
 * is found again by its text, or the toggle is dropped.
 */
export async function toggleCheck(id: string, index: number): Promise<boolean> {
  const summary = findSummary(id)
  const cached = bodies().get(id)
  if (!summary || !cached) return false
  let base = { revision: cached.revision, body: cached.body }
  let line = index
  const lineText = base.body.split("\n")[index] ?? ""
  for (let attempt = 0; attempt < 2; attempt++) {
    const edit = toggleEdit(base.body, line)
    if (!edit) return false
    try {
      const r = await api.edit(summary.doc, base.revision, [edit])
      const body = applyEdits(base.body, [edit])
      setBodies((m) => new Map(m).set(id, { revision: r.revision, body }))
      return true
    } catch (e) {
      if (codeOf(e) !== "revision.conflict") {
        setSaveError(messageOf(e))
        return false
      }
      const current = await api.get(id)
      upsert(current)
      const moved = rebaseLine(current.body, line, lineText)
      if (moved === null) return false
      base = { revision: current.revision, body: current.body }
      line = moved
    }
  }
  return false
}

/** Pinned first, then the chosen order (the server's rule for `note.list`, applied to a projection that the stream changes). */
export function sorted(list: readonly NoteSummary[], order: SortOrder): NoteSummary[] {
  const by: Record<SortOrder, (a: NoteSummary, b: NoteSummary) => number> = {
    updated: (a, b) => b.updated_at - a.updated_at,
    created: (a, b) => b.created_at - a.created_at,
    title: (a, b) => a.title.localeCompare(b.title)
  }
  return list.slice().sort((a, b) => Number(b.pinned) - Number(a.pinned) || by[order](a, b) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
}

export const scratchpadOf = (workspaceId: string) => summaries().find((n) => n.scratchpad && n.workspace?.id === workspaceId) ?? null
