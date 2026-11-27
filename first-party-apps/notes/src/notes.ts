/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// The notes server's wire shapes (catalog fragment proposed/notes-server-catalog.json,
// owner app:cmux/notes). Notes are documents owned by the notes server
// (`cmux-notes serve`, one instance per user, durable data): it keeps every
// note's text, revision, title, pin and workspace, derives titles and
// previews, stamps who wrote last, and streams typed changes on `note.watch`.
// This app keeps no copy of its own: it renders what the server sends.

export interface WorkspaceRef {
  id: string
  /** Name when the note was attached or last seen, so a closed workspace still labels it. */
  name: string
}

/** Who wrote last, stamped by the server from the caller's principal (never claimed by the caller). */
export interface LastEdit {
  actor_kind: "user" | "agent" | "app" | "automation"
  actor: string
  at: number
}

/** What lists and events carry: everything but the body. */
export interface NoteSummary {
  /** `note_…` */
  id: string
  /** The note's document handle (`doc_…`); the native editor pane opens it. */
  doc: string
  /** Explicit title, else derived by the server from the body ("" for an empty note). */
  title: string
  title_explicit: boolean
  preview: string
  pinned: boolean
  /** The workspace's scratchpad: at most one per workspace (the server enforces it). */
  scratchpad: boolean
  workspace: WorkspaceRef | null
  lines: number
  created_at: number
  updated_at: number
  /** The document revision: every change to the note increments it. */
  revision: number
  last_edit: LastEdit
}

export interface Note extends NoteSummary {
  body: string
}

export type SortOrder = "updated" | "created" | "title"

/** One text edit in UTF-16 offsets of the base revision's body. */
export interface TextEdit {
  start: number
  end: number
  text: string
}

/** One committed change on the user's notes, in commit order. */
export interface NoteEvent {
  seq: number
  kind: "created" | "updated" | "deleted"
  note: NoteSummary
}

/** The typed stream of the notes server (catalog `note.watch`). */
export const NOTE_STREAM = "note.watch"

const one = (p: Promise<{ note: Note }>) => p.then((r) => r.note)

/**
 * Calls to the notes server and the document host. Mutations return the whole
 * note at its new revision. `workspace` params are selectors (an id, a name or
 * "current"); the op router resolves them to `{id, name}` for the server, as it
 * resolves every selector, so "current" is the caller's own workspace.
 */
export const api = {
  list: (params: { query?: string; workspace?: string; sort?: SortOrder; limit?: number } = {}) => cmux.call<{ notes: NoteSummary[]; next: string | null }>("note.list", params),
  get: (note: string) => one(cmux.call("note.get", { note })),
  create: (params: { title?: string; body?: string; workspace?: string | null; pinned?: boolean; scratchpad?: boolean }, key?: string) =>
    one(cmux.call("note.create", params, key ? { idempotencyKey: key } : undefined)),
  capture: (params: { text: string; workspace?: string | null }) => one(cmux.call("note.capture", params)),
  append: (params: { note?: string; workspace?: string; text: string }) => one(cmux.call("note.append", params)),
  update: (note: string, change: { title?: string; pinned?: boolean; workspace?: string | null }) => one(cmux.call("note.update", { note, ...change })),
  delete: (note: string) => cmux.call("note.delete", { note }),
  search: (query: string, limit?: number) => cmux.call<{ results: SearchResult[] }>("note.search", { query, ...(limit ? { limit } : {}) }),
  /** A body edit on the note's document; a stale base is refused with `revision.conflict` and the current text. */
  edit: (doc: string, base_revision: number, edits: TextEdit[]) => cmux.call<{ revision: number }>("document.edit", { doc, base_revision, edits })
}

/** The search-provider answer (`note.search`). */
export interface SearchResult {
  id: string
  title: string
  subtitle: string | null
  snippet: string
  score: number
  symbol: string
  updated_at: number
  open: { command: string; args: { id: string } }
}
