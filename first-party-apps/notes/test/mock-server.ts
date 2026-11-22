// A small in-memory notes server and file broker for tests and preview
// fixtures, written from the catalog fragment (proposed/notes-server-catalog.json):
// one owner per note, a revision per note document, base-revision edits with
// `revision.conflict`, one scratchpad per workspace, typed `note.watch`
// events, and `fs.*` handles that only a gesture can create.
import type { LastEdit, Note, NoteEvent, NoteSummary, TextEdit, WorkspaceRef } from "../src/notes.ts"

export class ServerError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly details?: unknown
  ) {
    super(message)
  }
}
const fail = (code: string, message: string, details?: unknown): never => {
  throw new ServerError(code, message, details)
}

export const WORKSPACES = [
  { id: "workspace_api", session_id: "session_1", name: "api", index: 0, focused: true },
  { id: "workspace_web", session_id: "session_1", name: "web", index: 1, focused: false },
  { id: "workspace_docs", session_id: "session_1", name: "docs", index: 2, focused: false }
]

const HEADING = /^\s{0,3}#{1,6}\s+(.*)$/
const plain = (s: string) => s.replace(/^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s*)?/, "").replace(/^>\s?/, "").replace(/[*_`~]+/g, "").trim()

/** The server's derived title: the first heading, else the first prose line. */
export function derive(body: string, explicitTitle = false): { title: string; preview: string } {
  const lines = body.split("\n").filter((l) => l.trim() && !/^\s*(```|~~~)/.test(l))
  const heading = lines.find((l) => HEADING.test(l))
  const title = heading ? plain(heading.match(HEADING)![1]!) : plain(lines[0] ?? "")
  const rest = lines.filter((l) => !HEADING.test(l)).map(plain).filter(Boolean)
  if (!heading && !explicitTitle && rest[0] === title) rest.shift()
  const preview = rest.join(" · ")
  return { title, preview: preview.length > 120 ? `${preview.slice(0, 119)}…` : preview }
}

export interface Seed {
  id: string
  title?: string
  body: string
  pinned?: boolean
  scratchpad?: boolean
  workspace?: WorkspaceRef | null
  updated?: number
  created?: number
  by?: LastEdit["actor_kind"]
}

export class NotesServer {
  seq = 0
  notes = new Map<string, Note>()
  keys = new Map<string, string>()
  files = new Map<string, string>()
  written: Array<{ root: string; path: string; text: string }> = []
  private nextId = 1

  constructor(seeds: Seed[] = [], readonly now: () => number = Date.now) {
    for (const s of seeds) this.put(s)
  }

  private put(s: Seed): Note {
    const created = s.created ?? this.now()
    const note: Note = {
      id: s.id,
      doc: s.id.replace(/^note_/, "doc_"),
      title: "",
      title_explicit: !!s.title,
      preview: "",
      pinned: !!s.pinned,
      scratchpad: !!s.scratchpad,
      workspace: s.workspace ?? null,
      lines: 0,
      created_at: created,
      updated_at: s.updated ?? created,
      revision: 1,
      last_edit: { actor_kind: s.by ?? "user", actor: s.by === "agent" ? "agent_1" : "usr_test", at: s.updated ?? created },
      body: s.body
    }
    this.refresh(note, s.title)
    this.notes.set(note.id, note)
    return note
  }

  private refresh(n: Note, explicit?: string) {
    if (explicit !== undefined) n.title_explicit = !!explicit.trim()
    const d = derive(n.body, n.title_explicit)
    n.title = n.title_explicit ? (explicit ?? n.title) : d.title
    n.preview = n.scratchpad ? [d.title, d.preview].filter(Boolean).join(" · ") : d.preview
    n.lines = n.body ? n.body.split("\n").length : 0
  }

  summary(n: Note): NoteSummary {
    const { body: _b, ...rest } = n
    return structuredClone(rest)
  }

  private event(kind: NoteEvent["kind"], n: Note): NoteEvent {
    return { seq: ++this.seq, kind, note: this.summary(n) }
  }

  private change(n: Note, by: LastEdit["actor_kind"], content: boolean) {
    n.revision++
    const at = this.now()
    if (content) n.updated_at = at
    n.last_edit = { actor_kind: by, actor: by === "agent" ? "agent_1" : "usr_test", at }
  }

  resolve(ws: string | null | undefined): WorkspaceRef | null {
    if (!ws) return null
    const hit = ws === "current" ? WORKSPACES.find((w) => w.focused) : (WORKSPACES.find((w) => w.id === ws) ?? WORKSPACES.find((w) => w.name === ws))
    return hit ? { id: hit.id, name: hit.name } : fail("selector.not_found", `no workspace ${ws}`)
  }

  get(id: string): Note {
    return this.notes.get(id) ?? fail("selector.not_found", `no note ${id}`)
  }

  list(p: { query?: string; workspace?: string; limit?: number } = {}) {
    const ws = p.workspace ? this.resolve(p.workspace) : null
    const words = (p.query ?? "").toLowerCase().split(/\s+/).filter(Boolean)
    const notes = [...this.notes.values()]
      .filter((n) => !ws || n.workspace?.id === ws.id)
      .filter((n) => words.every((w) => `${n.title}\n${n.body}`.toLowerCase().includes(w)))
      .sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.updated_at - a.updated_at)
      .slice(0, p.limit ?? 500)
      .map((n) => this.summary(n))
    return { notes, next: null }
  }

  create(p: { title?: string; body?: string; workspace?: string | null; pinned?: boolean; scratchpad?: boolean }, key?: string, by: LastEdit["actor_kind"] = "user") {
    if (key && this.keys.has(key)) return { note: structuredClone(this.get(this.keys.get(key)!)), event: null }
    const workspace = this.resolve(p.workspace)
    if (p.scratchpad && workspace) {
      const pad = [...this.notes.values()].find((n) => n.scratchpad && n.workspace?.id === workspace.id)
      if (pad) return { note: structuredClone(pad), event: null }
    }
    const note = this.put({ id: `note_${String(this.nextId++).padStart(16, "0")}`, title: p.title, body: p.body ?? "", pinned: p.pinned, scratchpad: !!p.scratchpad && !!workspace, workspace, by })
    if (key) this.keys.set(key, note.id)
    return { note: structuredClone(note), event: this.event("created", note) }
  }

  append(p: { note?: string; workspace?: string; text: string }, by: LastEdit["actor_kind"] = "user") {
    let created: NoteEvent | null = null
    let note: Note
    if (p.note) note = this.get(p.note)
    else {
      const r = this.create({ workspace: p.workspace, scratchpad: true }, undefined, by)
      created = r.event
      note = this.get(r.note.id)
    }
    const add = p.text.replace(/\s+$/, "")
    note.body = note.body ? `${note.body.replace(/\n$/, "")}\n${add}` : add
    this.change(note, by, true)
    this.refresh(note)
    return { note: structuredClone(note), events: [created, this.event("updated", note)].filter((e): e is NoteEvent => !!e) }
  }

  update(p: { note: string; title?: string; pinned?: boolean; workspace?: string | null }) {
    const note = this.get(p.note)
    if (p.pinned !== undefined) note.pinned = p.pinned
    if (p.workspace !== undefined) note.workspace = this.resolve(p.workspace)
    this.change(note, "user", p.title !== undefined)
    this.refresh(note, p.title)
    return { note: structuredClone(note), event: this.event("updated", note) }
  }

  delete(p: { note: string }) {
    const note = this.get(p.note)
    this.notes.delete(note.id)
    return this.event("deleted", note)
  }

  /** `document.edit`: the edit applies only to the current revision. */
  edit(p: { doc: string; base_revision: number; edits: TextEdit[] }, by: LastEdit["actor_kind"] = "user") {
    const note = [...this.notes.values()].find((n) => n.doc === p.doc) ?? fail("selector.not_found", `no document ${p.doc}`)
    if (p.base_revision !== note.revision) fail("revision.conflict", "the document changed", { current: { revision: note.revision, text: note.body } })
    for (const e of [...p.edits].sort((a, b) => b.start - a.start)) note.body = note.body.slice(0, e.start) + e.text + note.body.slice(e.end)
    this.change(note, by, true)
    this.refresh(note)
    return { revision: note.revision, event: this.event("updated", note) }
  }

  /** Someone else (another device, the editor pane, an agent) writes the body. */
  external(id: string, body: string, by: LastEdit["actor_kind"] = "agent") {
    const note = this.get(id)
    note.body = body
    this.change(note, by, true)
    this.refresh(note)
    return this.event("updated", note)
  }
}
