// The notes document: types, limits and pure reducers. No cmux globals here,
// so tests import this module directly.

export interface WorkspaceRef {
  id: string
  /** Name when the note was attached or last seen, so a closed workspace still labels it. */
  name: string
}

/** Which entry point wrote last: the app's own UI, or a command (palette, CLI, MCP tool, other apps). */
export type EditVia = "ui" | "command"

export interface Note {
  id: string
  /** Empty means "derive from the body" (first heading or first prose line). */
  title: string
  body: string
  pinned: boolean
  /** The workspace's scratchpad: at most one per workspace. */
  scratchpad: boolean
  workspace: WorkspaceRef | null
  createdAt: number
  updatedAt: number
  /** Increments on every change; the conflict rule is last writer wins per note, ordered by revision. */
  revision: number
  lastEdit: { via: EditVia; actor?: string }
}

export interface Stamp {
  now: number
  via: EditVia
  /** Principal that caused the write when the host tells us (`agent:…`, `user:…`); absent today. */
  actor?: string
}

export type NoteOp =
  | { kind: "create"; id: string; title?: string; body?: string; workspace?: WorkspaceRef | null; scratchpad?: boolean; pinned?: boolean }
  | { kind: "append"; id: string; text: string }
  | { kind: "setTitle"; id: string; title: string }
  | { kind: "setBody"; id: string; body: string }
  | { kind: "replaceLine"; id: string; index: number; text: string }
  | { kind: "deleteLine"; id: string; index: number }
  | { kind: "toggleCheck"; id: string; index: number }
  | { kind: "setPinned"; id: string; pinned: boolean }
  | { kind: "setWorkspace"; id: string; workspace: WorkspaceRef | null }
  | { kind: "delete"; id: string }

export const LIMITS = {
  titleChars: 200,
  bodyChars: 200_000,
  notes: 2_000,
  appendChars: 50_000,
  previewChars: 120
}

export class NoteError extends Error {
  constructor(
    readonly code: "note.not_found" | "note.too_large" | "note.invalid" | "notes.full",
    message: string
  ) {
    super(message)
    this.name = "NoteError"
  }
}

export const normalizeNewlines = (s: string) => s.replace(/\r\n?/g, "\n")

const clampTitle = (s: string) => normalizeNewlines(s).replace(/\n+/g, " ").trim().slice(0, LIMITS.titleChars).trim()

function checkBody(body: string): string {
  const b = normalizeNewlines(body)
  if (b.length > LIMITS.bodyChars) throw new NoteError("note.too_large", `a note holds at most ${LIMITS.bodyChars} characters`)
  return b
}

/** Appends text as new line(s) at the end of body. */
export function appendText(body: string, text: string): string {
  const add = normalizeNewlines(text).replace(/\s+$/, "")
  if (!add) return body
  if (!body) return add
  return body.endsWith("\n") ? body + add : `${body}\n${add}`
}

export const emptyNote = (id: string, now: number): Note => ({
  id,
  title: "",
  body: "",
  pinned: false,
  scratchpad: false,
  workspace: null,
  createdAt: now,
  updatedAt: now,
  revision: 1,
  lastEdit: { via: "ui" }
})

export const scratchpadOf = (notes: readonly Note[], workspaceId: string) =>
  notes.find((n) => n.scratchpad && n.workspace?.id === workspaceId) ?? null

export interface ApplyResult {
  notes: Note[]
  /** The note after the op (null after delete). */
  note: Note | null
  /** False when the op changed nothing (no revision bump, no reorder, no write). */
  changed: boolean
}

function edit(lines: string[], index: number, fn: (lines: string[]) => void): string {
  if (!Number.isInteger(index) || index < 0 || index >= lines.length) throw new NoteError("note.invalid", `line ${index} does not exist`)
  const copy = lines.slice()
  fn(copy)
  return copy.join("\n")
}

/** Applies one op. Pure: returns new arrays and objects, never mutates its input. */
export function applyOp(notes: readonly Note[], op: NoteOp, stamp: Stamp): ApplyResult {
  const lastEdit = stamp.actor ? { via: stamp.via, actor: stamp.actor } : { via: stamp.via }
  if (op.kind === "create") {
    if (op.scratchpad && op.workspace) {
      const existing = scratchpadOf(notes, op.workspace.id)
      if (existing) return { notes: notes.slice(), note: existing, changed: false }
    }
    if (notes.some((n) => n.id === op.id)) throw new NoteError("note.invalid", `note ${op.id} already exists`)
    if (notes.length >= LIMITS.notes) throw new NoteError("notes.full", `at most ${LIMITS.notes} notes`)
    const note: Note = {
      ...emptyNote(op.id, stamp.now),
      title: clampTitle(op.title ?? ""),
      body: checkBody(op.body ?? ""),
      pinned: op.pinned === true,
      scratchpad: op.scratchpad === true && !!op.workspace,
      workspace: op.workspace ?? null,
      lastEdit
    }
    return { notes: [...notes, note], note, changed: true }
  }

  const index = notes.findIndex((n) => n.id === op.id)
  if (index < 0) throw new NoteError("note.not_found", `no note ${op.id}`)
  const before = notes[index]!
  if (op.kind === "delete") return { notes: notes.filter((n) => n.id !== op.id), note: null, changed: true }

  let next: Note = before
  const lines = () => before.body.split("\n")
  switch (op.kind) {
    case "append":
      if (normalizeNewlines(op.text).length > LIMITS.appendChars) throw new NoteError("note.too_large", `append at most ${LIMITS.appendChars} characters at once`)
      next = { ...before, body: checkBody(appendText(before.body, op.text)) }
      break
    case "setTitle":
      next = { ...before, title: clampTitle(op.title) }
      break
    case "setBody":
      next = { ...before, body: checkBody(op.body) }
      break
    case "replaceLine":
      next = { ...before, body: checkBody(edit(lines(), op.index, (l) => l.splice(op.index, 1, ...normalizeNewlines(op.text).split("\n")))) }
      break
    case "deleteLine":
      next = { ...before, body: edit(lines(), op.index, (l) => l.splice(op.index, 1)) }
      break
    case "toggleCheck":
      next = { ...before, body: edit(lines(), op.index, (l) => (l[op.index] = toggleCheckLine(l[op.index]!))) }
      break
    case "setPinned":
      next = { ...before, pinned: op.pinned }
      break
    case "setWorkspace":
      // A scratchpad is defined by its workspace; detaching makes it a plain note.
      next = { ...before, workspace: op.workspace, scratchpad: before.scratchpad && op.workspace?.id === before.workspace?.id }
      break
  }
  const same =
    next.title === before.title &&
    next.body === before.body &&
    next.pinned === before.pinned &&
    next.scratchpad === before.scratchpad &&
    JSON.stringify(next.workspace) === JSON.stringify(before.workspace)
  if (same) return { notes: notes.slice(), note: before, changed: false }
  // Pinning and attaching do not move a note in the "recent" order.
  const content = next.title !== before.title || next.body !== before.body
  next = { ...next, revision: before.revision + 1, updatedAt: content ? stamp.now : before.updatedAt, lastEdit }
  const out = notes.slice()
  out[index] = next
  return { notes: out, note: next, changed: true }
}

const CHECK = /^(\s*[-*+]\s+\[)([ xX])(\]\s?)/

/** "- [ ] task" <-> "- [x] task"; other lines are returned unchanged. */
export function toggleCheckLine(line: string): string {
  const m = line.match(CHECK)
  if (!m) return line
  return `${m[1]}${m[2] === " " ? "x" : " "}${m[3]}${line.slice(m[0].length)}`
}

/** Markdown decoration removed: images, link targets, emphasis, inline code ticks. */
export function unwrapMarkdown(s: string): string {
  return s
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[*_`~]+/g, "")
    .trim()
}

const stripListMarker = (s: string) => s.replace(/^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s*)?/, "").replace(/^>\s?/, "")
const FENCE = /^\s*(```|~~~)/
const HEADING = /^\s{0,3}#{1,6}\s+(.*)$/

/** Title from the body: the first heading, else the first prose line outside code fences. "" when none. */
export function deriveTitle(body: string): string {
  const lines = body.split("\n")
  let inFence = false
  for (const line of lines) {
    if (FENCE.test(line)) {
      inFence = !inFence
      continue
    }
    if (inFence) continue
    const h = line.match(HEADING)
    if (h) {
      const title = unwrapMarkdown(h[1]!)
      if (title) return title.slice(0, LIMITS.titleChars)
    }
  }
  inFence = false
  for (const line of lines) {
    if (FENCE.test(line)) {
      inFence = !inFence
      continue
    }
    if (inFence) continue
    const trimmed = line.trim()
    if (!trimmed || /^(-{3,}|\*{3,})$/.test(trimmed)) continue
    const title = unwrapMarkdown(stripListMarker(trimmed))
    if (title) return title.slice(0, LIMITS.titleChars)
  }
  return ""
}

/** The note's title as shown: explicit, else derived; "" when the note is empty. */
export const titleOf = (note: Pick<Note, "title" | "body">) => note.title.trim() || deriveTitle(note.body)

/** A one-line preview: prose outside headings and fences, without the line used as the title. */
export function previewOf(note: Pick<Note, "title" | "body">, max = LIMITS.previewChars, skipTitleLine = true): string {
  const title = titleOf(note)
  const parts: string[] = []
  let inFence = false
  let skippedTitle = false
  for (const line of note.body.split("\n")) {
    if (FENCE.test(line)) {
      inFence = !inFence
      continue
    }
    if (inFence || HEADING.test(line)) continue
    const trimmed = line.trim()
    if (!trimmed || /^(-{3,}|\*{3,})$/.test(trimmed)) continue
    const text = unwrapMarkdown(stripListMarker(trimmed))
    if (!text) continue
    if (skipTitleLine && !skippedTitle && !note.title.trim() && text === title) {
      skippedTitle = true
      continue
    }
    parts.push(text)
    if (parts.join(" · ").length >= max) break
  }
  const preview = parts.join(" · ")
  return preview.length > max ? `${preview.slice(0, max - 1)}…` : preview
}

export type SortOrder = "updated" | "created" | "title"

/** Pinned first, then the chosen order; ties break by id so the order is total. */
export function sortNotes(notes: readonly Note[], order: SortOrder = "updated"): Note[] {
  const by: Record<SortOrder, (a: Note, b: Note) => number> = {
    updated: (a, b) => b.updatedAt - a.updatedAt,
    created: (a, b) => b.createdAt - a.createdAt,
    title: (a, b) => titleOf(a).localeCompare(titleOf(b))
  }
  return notes.slice().sort((a, b) => Number(b.pinned) - Number(a.pinned) || by[order](a, b) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
}

export interface SearchHit {
  note: Note
  score: number
  /** The body line around the first match ("" when only the title matched). */
  snippet: string
}

const tokens = (query: string) =>
  query
    .toLowerCase()
    .split(/\s+/)
    .map((s) => s.replace(/^#/, ""))
    .filter(Boolean)

function snippetAround(body: string, needle: string, width = 80): string {
  const line = body.split("\n").find((l) => l.toLowerCase().includes(needle))
  if (!line) return ""
  const text = unwrapMarkdown(stripListMarker(line.trim()))
  const at = text.toLowerCase().indexOf(needle)
  if (text.length <= width || at < 0) return text.length <= width ? text : `${text.slice(0, width - 1)}…`
  const start = Math.max(0, Math.min(at - Math.floor(width / 3), text.length - width))
  return `${start > 0 ? "…" : ""}${text.slice(start, start + width - 2).trim()}${start + width - 2 < text.length ? "…" : ""}`
}

/**
 * Every query token must appear in the title, body or workspace name.
 * Title hits weigh more than body hits; a title that starts with the query
 * ranks first; ties go to the most recently updated note.
 */
export function searchNotes(notes: readonly Note[], query: string, limit = 50): SearchHit[] {
  const words = tokens(query)
  if (!words.length) return sortNotes(notes).slice(0, limit).map((note) => ({ note, score: 0, snippet: "" }))
  const hits: SearchHit[] = []
  for (const note of notes) {
    const title = titleOf(note).toLowerCase()
    const body = note.body.toLowerCase()
    const place = (note.workspace?.name ?? "").toLowerCase()
    let score = 0
    let all = true
    for (const w of words) {
      const inTitle = title.includes(w)
      const inBody = body.includes(w)
      if (!inTitle && !inBody && !place.includes(w)) {
        all = false
        break
      }
      score += (inTitle ? 10 : 0) + (inBody ? 3 : 0) + (inTitle || inBody ? 0 : 1)
    }
    if (!all) continue
    if (title.startsWith(words.join(" "))) score += 20
    if (note.pinned) score += 1
    const bodyWord = words.find((w) => body.includes(w))
    hits.push({ note, score, snippet: bodyWord ? snippetAround(note.body, bodyWord) : "" })
  }
  return hits.sort((a, b) => b.score - a.score || b.note.updatedAt - a.note.updatedAt || (a.note.id < b.note.id ? -1 : 1)).slice(0, limit)
}

/** What `list` returns to agents: enough to choose, never the full body. */
export function summaryOf(note: Note) {
  return {
    id: note.id,
    title: titleOf(note),
    preview: previewOf(note),
    pinned: note.pinned,
    scratchpad: note.scratchpad,
    workspace: note.workspace,
    lines: note.body ? note.body.split("\n").length : 0,
    updated_at: note.updatedAt,
    revision: note.revision
  }
}

/** File name for export: a slug of the title (letters of any script kept), ".md". */
export function fileNameOf(note: Note, fallback = "note"): string {
  const slug = titleOf(note)
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48)
    .replace(/-+$/, "")
  return `${slug || fallback}.md`
}

/** Markdown for export: a heading with the explicit title unless the body already starts with it. */
export function toMarkdown(note: Note): string {
  const title = note.title.trim()
  const body = note.body.replace(/\s+$/, "")
  if (!title) return `${body}\n`
  const first = body.split("\n", 1)[0] ?? ""
  const heading = first.match(HEADING)
  if (heading && unwrapMarkdown(heading[1]!) === title) return `${body}\n`
  return body ? `# ${title}\n\n${body}\n` : `# ${title}\n`
}

/** Minutes, hours or days since `ms`; the view turns the unit into words. */
export function age(ms: number, now: number): { unit: "now" | "minutes" | "hours" | "days"; n: number } {
  const minutes = Math.max(0, Math.floor((now - ms) / 60_000))
  if (minutes < 1) return { unit: "now", n: 0 }
  if (minutes < 60) return { unit: "minutes", n: minutes }
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return { unit: "hours", n: hours }
  return { unit: "days", n: Math.floor(hours / 24) }
}

/** Reads a stored document defensively (older or hand-edited values must not crash the app). */
export function parseDocument(value: unknown): Note[] {
  const list = value && typeof value === "object" && Array.isArray((value as { notes?: unknown }).notes) ? ((value as { notes: unknown[] }).notes) : []
  const out: Note[] = []
  const seen = new Set<string>()
  for (const raw of list) {
    if (!raw || typeof raw !== "object") continue
    const n = raw as Record<string, unknown>
    if (typeof n.id !== "string" || !n.id || seen.has(n.id)) continue
    seen.add(n.id)
    const ws = n.workspace as Record<string, unknown> | null | undefined
    out.push({
      id: n.id,
      title: typeof n.title === "string" ? n.title : "",
      body: typeof n.body === "string" ? normalizeNewlines(n.body) : "",
      pinned: n.pinned === true,
      scratchpad: n.scratchpad === true && !!ws,
      workspace: ws && typeof ws.id === "string" ? { id: ws.id, name: typeof ws.name === "string" ? ws.name : "" } : null,
      createdAt: Number(n.createdAt) || 0,
      updatedAt: Number(n.updatedAt) || 0,
      revision: Number(n.revision) || 1,
      lastEdit: (n.lastEdit as Note["lastEdit"]) ?? { via: "ui" }
    })
  }
  return out
}

export const DOCUMENT_VERSION = 1
export const serializeDocument = (notes: readonly Note[]) => ({ version: DOCUMENT_VERSION, notes })
