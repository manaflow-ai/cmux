/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Command handlers for today's runtime. The agent tools (list, read, create,
// append, capture, search) forward to the notes server's catalog ops; on
// manifest v2 they are those ops themselves (proposed/notes-server-catalog.json) and
// these wrappers go away. Commands never move focus or selection: only
// `newNote` and `open` (user commands, not MCP tools) select a note in the
// app's own surfaces. The server stamps who wrote (an agent's append shows
// as an agent edit), so no command claims an actor.

import { appError } from "./errors.ts"
import { CANCELLED, exportNotes as exportFiles, importNotes as importFiles } from "./files.ts"
import { api, type Note, type NoteSummary } from "./notes.ts"
import { cycleVariant as cycle } from "./settings.ts"
import { appendTo, codeOf, createNote, ensureLoaded, findSummary, messageOf } from "./store.ts"
import { requestSelect } from "./views/state.ts"

type Args = Record<string, unknown>

const fail = (code: string, message: string): never => {
  throw appError(code, message)
}

function str(args: Args, key: string, required = false): string | undefined {
  const v = args[key]
  if (v === undefined || v === null) return required ? fail("invalid_params", `${key} is required`) : undefined
  if (typeof v !== "string") return fail("invalid_params", `${key} must be a string`)
  if (required && !v.trim()) return fail("invalid_params", `${key} must not be empty`)
  return v
}

/** Server errors reach the caller with their own code (agents branch on it). */
async function run<T>(fn: () => Promise<T>): Promise<T> {
  try {
    return await fn()
  } catch (e) {
    if (e instanceof Error && codeOf(e)) throw e
    throw appError("command.failed", messageOf(e))
  }
}

const summary = (n: Note): NoteSummary => {
  const { body: _body, ...rest } = n
  return rest
}

/** `list {query?, workspace?, limit?}`: titles and short previews, never bodies. */
export const list = (args: Args = {}) =>
  run(async () => {
    const query = str(args, "query")
    const workspace = str(args, "workspace")
    const limit = Math.min(200, Math.max(1, Number(args.limit ?? 50) || 50))
    const r = await api.list({ ...(query ? { query } : {}), ...(workspace ? { workspace } : {}), limit })
    return { notes: r.notes }
  })

/** `read {id}`: one full note. */
export const read = (args: Args = {}) => run(() => api.get(str(args, "id", true)!))

/** `create {title?, body?, workspace?, pinned?}`. */
export const create = (args: Args = {}) =>
  run(async () => {
    const title = str(args, "title") ?? ""
    const body = str(args, "body") ?? ""
    if (!title.trim() && !body.trim()) fail("invalid_params", "give a title or a body")
    const workspace = str(args, "workspace") ?? null
    return summary((await createNote({ title, body, workspace, pinned: args.pinned === true }))!)
  })

/** `capture {text, workspace?}`: a new note from text; the server makes its first line the title. */
export const capture = (args: Args = {}) =>
  run(async () => {
    const text = str(args, "text", true)!
    const workspace = str(args, "workspace") ?? null
    return summary(await api.capture({ text, workspace }))
  })

/** `append {id | workspace, text}`: adds lines to a note, or to a workspace's scratchpad (the server creates it on first use). */
export const append = (args: Args = {}) =>
  run(async () => {
    const text = str(args, "text", true)!
    const id = str(args, "id")
    if (!!id === (args.workspace !== undefined)) fail("invalid_params", "give exactly one of id or workspace")
    const target = id ? { note: id } : { workspace: str(args, "workspace", true)! }
    return summary((await appendTo(target, text))!)
  })

/** `search {query, limit?}`: the search-provider answer (README, "Search provider"). */
export const search = (args: Args = {}) =>
  run(async () => {
    const limit = Math.min(50, Math.max(1, Number(args.limit ?? 20) || 20))
    return api.search(str(args, "query", true)!, limit)
  })

/**
 * `exportNotes {id?}` and `importNotes {}` (palette, not MCP tools): the
 * system panel needs a user gesture; a palette or menu invocation carries the
 * command's token in `ctx.gesture` (ABI "Gesture tokens"), and the section's
 * menu runs the same flows from a tap.
 */
export const exportNotes = (args: Args = {}, ctx?: CmuxCommandContext) =>
  run(async () => {
    const id = str(args, "id")
    try {
      return await exportFiles(id ? [id] : null, ctx?.gesture ?? null)
    } catch (e) {
      if (codeOf(e) === CANCELLED) return { folder: null, files: [] }
      throw e
    }
  })

export const importNotes = (_args: Args = {}, ctx?: CmuxCommandContext) =>
  run(async () => {
    try {
      return await importFiles(ctx?.gesture ?? null)
    } catch (e) {
      if (codeOf(e) === CANCELLED) return { imported: [], skipped: [] }
      throw e
    }
  })

/** `newNote` (palette only): an empty note, shown in the app's surfaces. */
export const newNote = () =>
  run(async () => {
    const note = (await createNote({}))!
    requestSelect(note.id)
    return { id: note.id }
  })

/** `open {id}` (palette and search results, not an MCP tool): shows the note in the app's surfaces. */
export const open = (args: Args = {}) =>
  run(async () => {
    const id = str(args, "id", true)!
    await ensureLoaded()
    if (!findSummary(id)) fail("note.not_found", `no note ${id}`)
    requestSelect(id)
    return { id }
  })

export const cycleVariant = () => cycle()
