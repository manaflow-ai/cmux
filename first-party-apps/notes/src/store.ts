// The notes store: one in-memory copy (a signal every surface reads), ordered
// writes, and two backends.
//
// - "documents": the proposed document store (`document.list/get/put/delete`,
//   event `document.changed`; README "Proposed operations"). Per-note writes
//   with a base revision; on a conflict the op is replayed on the newer copy.
// - "local": `cmux.storage` (5 MiB local KV) as one key holding the whole set.
//   Works today; local to this machine.
//
// Commands and sections run in the same app VM, so a write from an agent's
// MCP call updates every mounted section through the signal, with no reload
// and no focus change.

import { applyOp, LIMITS, NoteError, parseDocument, serializeDocument, type Note, type NoteOp, type Stamp } from "./model.ts"

export type Backend = "documents" | "local"

export const STORAGE_KEY = "notes.v1"
export const COLLECTION = "notes"
/** Leave headroom under the 5 MiB local quota for the app's other keys. */
export const LOCAL_BUDGET_BYTES = 4_500_000

const [notes, setNotes] = signal<Note[]>([])
const [ready, setReady] = signal(false)
const [loadError, setLoadError] = signal<string | null>(null)
const [saveError, setSaveError] = signal<string | null>(null)
const [backendSignal, setBackend] = signal<Backend | null>(null)

export { notes, ready, loadError, saveError }
export const backend = backendSignal

let loading: Promise<void> | null = null

const errorCode = (e: unknown) => (e && typeof e === "object" && "code" in e ? String((e as { code: unknown }).code) : "")
/** The op does not exist on this host, or the app lacks its scope: use the fallback. */
const unavailable = (e: unknown) => ["operation.unsupported", "scope.missing", "operation.forbidden"].includes(errorCode(e))
const message = (e: unknown) => (e instanceof Error ? e.message : String(e))

interface DocumentRecord {
  id: string
  revision: string | number
  data: Record<string, unknown>
}

/** Revision the document store last confirmed per note (the base of the next write). */
const known = new Map<string, number>()

const fromRecord = (r: DocumentRecord): Note | undefined => {
  const note = parseDocument({ notes: [{ ...r.data, id: r.id, revision: Number(r.revision) }] })[0]
  if (note) known.set(note.id, Number(r.revision))
  return note
}
/** What the document store keeps per note (the id and revision live on the record). */
const toData = (n: Note) => {
  const { id: _id, revision: _rev, ...data } = n
  return data
}

async function loadOnce(): Promise<void> {
  try {
    const r = await cmux.call<{ documents: DocumentRecord[] }>("document.list", { collection: COLLECTION })
    setNotes(r.documents.map(fromRecord).filter((n): n is Note => !!n))
    setBackend("documents")
    cmux.events.on("document.changed", (payload) => void onRemoteChange(payload as { collection?: string; id?: string; revision?: string | number; deleted?: boolean }), { collection: COLLECTION })
  } catch (e) {
    if (!unavailable(e)) throw e
    const value = await cmux.storage.get(STORAGE_KEY)
    setNotes(parseDocument(value))
    setBackend("local")
  }
}

/** Loads once; every surface and command awaits the same promise. A failed load is retried on the next call. */
export function ensureLoaded(): Promise<void> {
  if (!loading) {
    loading = loadOnce().then(
      () => {
        setLoadError(null)
        setReady(true)
      },
      (e) => {
        loading = null
        setLoadError(message(e))
        throw e
      }
    )
  }
  return loading
}

export const findNote = (id: string) => notes().find((n) => n.id === id) ?? null

// Writes leave in commit order. Local writes coalesce: a queued write that
// finds a newer snapshot already saved skips itself.
let chain: Promise<unknown> = Promise.resolve()
let generation = 0
let savedGeneration = 0

const enqueue = <T>(work: () => Promise<T>): Promise<T> => {
  const next = chain.then(work, work)
  chain = next.catch(() => undefined)
  return next
}

function persistLocal(target: number): Promise<void> {
  return enqueue(async () => {
    if (savedGeneration >= target) return
    const at = generation
    await cmux.storage.set(STORAGE_KEY, serializeDocument(notes()))
    savedGeneration = Math.max(savedGeneration, at)
  })
}

function persistDocument(op: NoteOp, stamp: Stamp): Promise<void> {
  return enqueue(async () => {
    for (let attempt = 0; attempt < 3; attempt++) {
      const local = findNote(op.id)
      try {
        if (op.kind === "delete") {
          await cmux.call("document.delete", { collection: COLLECTION, id: op.id, base_revision: String(known.get(op.id) ?? 0) })
          known.delete(op.id)
          return
        }
        if (!local) return // deleted locally after this op was queued
        const r = await cmux.call<{ revision: string | number }>("document.put", { collection: COLLECTION, id: local.id, data: toData(local), base_revision: String(known.get(local.id) ?? 0) })
        const revision = Number(r.revision)
        known.set(local.id, revision)
        const latest = findNote(local.id)
        if (latest && latest.revision < revision) replaceNote({ ...latest, revision })
        return
      } catch (e) {
        if (errorCode(e) !== "revision.conflict") throw e
        // Someone else wrote this note first: take their copy and replay our op on it.
        const current = await cmux.call<DocumentRecord | null>("document.get", { collection: COLLECTION, id: op.id })
        const theirs = current ? fromRecord(current) : undefined
        if (!theirs) {
          removeNote(op.id)
          return
        }
        replaceNote(theirs)
        if (op.kind === "create") return
        const replay = applyOp(notes(), op, stamp)
        setNotes(replay.notes)
        if (!replay.changed) return
      }
    }
    throw new NoteError("note.invalid", "the note kept changing while saving; try again")
  })
}

const replaceNote = (note: Note) => setNotes((list) => (list.some((n) => n.id === note.id) ? list.map((n) => (n.id === note.id ? note : n)) : [...list, note]))
const removeNote = (id: string) => setNotes((list) => list.filter((n) => n.id !== id))

async function onRemoteChange(e: { collection?: string; id?: string; revision?: string | number; deleted?: boolean }) {
  if (!e || e.collection !== COLLECTION || !e.id) return
  if (e.deleted) {
    known.delete(e.id)
    return removeNote(e.id)
  }
  if (e.revision !== undefined && Number(e.revision) <= (known.get(e.id) ?? 0)) return
  const r = await cmux.call<DocumentRecord | null>("document.get", { collection: COLLECTION, id: e.id })
  const note = r ? fromRecord(r) : undefined
  if (note) replaceNote(note)
  else removeNote(e.id)
}

const sizeOf = (list: readonly Note[]) => JSON.stringify(serializeDocument(list)).length

/**
 * Applies one op now (every surface sees it at once) and resolves when it is
 * saved. Rejects with a NoteError for invalid ops and with the storage error
 * when the save fails; the in-memory copy keeps the change and the next write
 * saves it again.
 */
export async function commit(op: NoteOp, stamp: Stamp): Promise<Note | null> {
  await ensureLoaded()
  const result = applyOp(notes(), op, stamp)
  if (!result.changed) return result.note
  if (backendSignal() === "local" && op.kind !== "delete" && sizeOf(result.notes) > LOCAL_BUDGET_BYTES) {
    throw new NoteError("notes.full", `notes use more than ${Math.round(LOCAL_BUDGET_BYTES / 1_000_000)} MB of local storage`)
  }
  setNotes(result.notes)
  generation++
  try {
    if (backendSignal() === "documents") await persistDocument(op, stamp)
    else await persistLocal(generation)
    setSaveError(null)
  } catch (e) {
    setSaveError(message(e))
    throw e
  }
  return op.kind === "delete" ? null : findNote(op.id)
}

/** A fresh id: "note_" + 16 base-36 characters. */
export function newNoteId(): string {
  let s = ""
  for (let i = 0; i < 16; i++) s += Math.floor(Math.random() * 36).toString(36)
  return `note_${s}`
}

export const limits = LIMITS

/** For tests: forget everything loaded. */
export function resetForTests(): void {
  setNotes([])
  setReady(false)
  setBackend(null)
  loading = null
  known.clear()
  chain = Promise.resolve()
  generation = 0
  savedGeneration = 0
}
