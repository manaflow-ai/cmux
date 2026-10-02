// Command handlers. Every command is a palette entry, `cmux apps run
// cmux/notes#<id>`, and (with `mcp:expose`) an MCP tool, so agents keep notes
// with the same code path as people. Commands never move focus or selection:
// only `newNote` and `open` (user commands, not MCP tools) select a note in
// the app's own surfaces.

import { appError } from "./errors.ts"
import { appendToScratchpad } from "./views/scratchpad.ts"
import { requestSelect } from "./views/state.ts"
import { LIMITS, NoteError, fileNameOf, previewOf, searchNotes, sortNotes, summaryOf, titleOf, toMarkdown, type Note, type Stamp } from "./model.ts"
import { cycleVariant as cycle, sortOrder } from "./settings.ts"
import { backend, commit, ensureLoaded, findNote, newNoteId, notes } from "./store.ts"
import { resolveWorkspace } from "./workspace.ts"

/** What the host passes to a command today (`{app}`) plus the fields README proposes. */
export interface CommandContext {
  app?: { id: string; version: string }
  /** Proposed: principal that invoked the command (`user:…`, `agent:…`, `app:…`). */
  actor?: string
  /** Proposed: `user` from the palette or a keybinding, `script` from CLI, MCP and other apps. */
  origin?: "user" | "script"
}

type Args = Record<string, unknown>

const stampOf = (ctx: CommandContext | undefined): Stamp => (ctx?.actor ? { now: Date.now(), via: "command", actor: ctx.actor } : { now: Date.now(), via: "command" })

const fail = (code: string, message: string): never => {
  throw appError(code, message)
}

function str(args: Args, key: string, opts: { required?: boolean; max?: number } = {}): string | undefined {
  const v = args[key]
  if (v === undefined || v === null) return opts.required ? fail("invalid_params", `${key} is required`) : undefined
  if (typeof v !== "string") return fail("invalid_params", `${key} must be a string`)
  if (opts.required && !v.trim()) return fail("invalid_params", `${key} must not be empty`)
  if (opts.max !== undefined && v.length > opts.max) return fail("note.too_large", `${key} is longer than ${opts.max} characters`)
  return v
}

/** Store and model errors become CmuxErrors with their own code (agents branch on it). */
async function run<T>(fn: () => Promise<T>): Promise<T> {
  try {
    await ensureLoaded()
    return await fn()
  } catch (e) {
    if (e instanceof NoteError) throw appError(e.code, e.message)
    throw e
  }
}

const noteOrFail = (id: string): Note => findNote(id) ?? fail("note.not_found", `no note ${id}`)

const full = (n: Note) => ({ ...summaryOf(n), body: n.body, created_at: n.createdAt, last_edit: n.lastEdit })

/** `list {query?, workspace?, limit?}`: titles and short previews, never bodies. */
export const list = (args: Args = {}) =>
  run(async () => {
    const query = str(args, "query") ?? ""
    const ws = args.workspace === undefined ? null : await resolveWorkspace(args.workspace)
    const limit = Math.min(200, Math.max(1, Number(args.limit ?? 50) || 50))
    const pool = ws ? notes().filter((n) => n.workspace?.id === ws.id) : notes()
    const picked = query.trim() ? searchNotes(pool, query, limit).map((h) => h.note) : sortNotes(pool, sortOrder()).slice(0, limit)
    return { notes: picked.map(summaryOf), total: pool.length, storage: backend() }
  })

/** `read {id}`: one full note. */
export const read = (args: Args = {}) => run(async () => full(noteOrFail(str(args, "id", { required: true })!)))

/** `create {title?, body?, workspace?, pinned?}`. */
export const create = (args: Args = {}, ctx?: CommandContext) =>
  run(async () => {
    const title = str(args, "title", { max: LIMITS.titleChars }) ?? ""
    const body = str(args, "body", { max: LIMITS.bodyChars }) ?? ""
    if (!title.trim() && !body.trim()) fail("invalid_params", "give a title or a body")
    const workspace = await resolveWorkspace(args.workspace)
    const note = await commit({ kind: "create", id: newNoteId(), title, body, workspace, pinned: args.pinned === true }, stampOf(ctx))
    return summaryOf(note!)
  })

/** `capture {text, workspace?}`: a new note from text; the first line becomes its title. */
export const capture = (args: Args = {}, ctx?: CommandContext) =>
  run(async () => {
    const text = str(args, "text", { required: true, max: LIMITS.bodyChars })!
    const workspace = await resolveWorkspace(args.workspace)
    const note = await commit({ kind: "create", id: newNoteId(), body: text.trim(), workspace }, stampOf(ctx))
    return summaryOf(note!)
  })

/** `append {id | workspace, text}`: adds lines to a note, or to a workspace's scratchpad (created on first use). */
export const append = (args: Args = {}, ctx?: CommandContext) =>
  run(async () => {
    const text = str(args, "text", { required: true, max: LIMITS.appendChars })!
    const id = str(args, "id")
    if (!!id === (args.workspace !== undefined)) fail("invalid_params", "give exactly one of id or workspace")
    const stamp = stampOf(ctx)
    let note: Note | null
    if (id) note = await commit({ kind: "append", id, text }, stamp)
    else {
      const ws = await resolveWorkspace(args.workspace)
      note = await appendToScratchpad(ws!, text, stamp)
    }
    return summaryOf(note!)
  })

/** `pin {id, pinned?}`: pins (default) or unpins. */
export const pin = (args: Args = {}, ctx?: CommandContext) =>
  run(async () => {
    const id = str(args, "id", { required: true })!
    noteOrFail(id)
    const note = await commit({ kind: "setPinned", id, pinned: args.pinned !== false }, stampOf(ctx))
    return summaryOf(note!)
  })

/**
 * `search {query, limit?}`: the answer a search provider gives (README,
 * "searchProviders"): ranked results with a snippet and how to open each.
 */
export const search = (args: Args = {}) =>
  run(async () => {
    const query = str(args, "query", { required: true })!
    const limit = Math.min(50, Math.max(1, Number(args.limit ?? 20) || 20))
    return {
      results: searchNotes(notes(), query, limit).map((h) => ({
        id: h.note.id,
        title: titleOf(h.note),
        subtitle: h.note.workspace?.name ?? null,
        snippet: h.snippet || previewOf(h.note, 80),
        score: h.score,
        symbol: h.note.pinned ? "pin.fill" : "note.text",
        updated_at: h.note.updatedAt,
        open: { command: "cmux/notes#open", args: { id: h.note.id } }
      }))
    }
  })

/** `export {id?}`: markdown files (name + text); every note when id is absent. Writing them to disk is a platform gap. */
export const exportNotes = (args: Args = {}) =>
  run(async () => {
    const id = str(args, "id")
    const picked = id ? [noteOrFail(id)] : notes().slice().sort((a, b) => a.createdAt - b.createdAt || (a.id < b.id ? -1 : 1))
    const used = new Set<string>()
    const files = picked.map((n) => {
      let name = fileNameOf(n)
      for (let i = 2; used.has(name); i++) name = fileNameOf(n).replace(/\.md$/, `-${i}.md`)
      used.add(name)
      return { id: n.id, name, text: toMarkdown(n) }
    })
    return { files }
  })

/** `newNote` (palette only): an empty note, shown in the app's surfaces. */
export const newNote = (_args: Args = {}, ctx?: CommandContext) =>
  run(async () => {
    const note = await commit({ kind: "create", id: newNoteId() }, stampOf(ctx))
    requestSelect(note!.id)
    return { id: note!.id }
  })

/** `open {id}` (palette and search results, not an MCP tool): shows the note in the app's surfaces. */
export const open = (args: Args = {}) =>
  run(async () => {
    const id = str(args, "id", { required: true })!
    noteOrFail(id)
    requestSelect(id)
    return { id }
  })

export const cycleVariant = () => cycle()
