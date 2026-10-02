/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Palette Notes: notes as palette scopes (plans/cmux-next/palette-scopes.md
// section 6). `notes` is a snapshot over app storage: the host ranks it with
// no app code per keystroke and paints the last snapshot first, so the scope
// opens instantly even when this VM is cold. `search` is a query source that
// streams title matches, then body matches. Item actions are typed
// ActionRefs; the host renders their titles from the catalog.

interface Note {
  id: string
  title: string
  body: string
  folder?: string
  tags?: string[]
  pinned?: boolean
  updatedAt: number
}

const APP = "app:cmux/palette-notes"
/** Bodies up to this length are copied by `clipboard.write` straight from the row; longer ones through the `copy` command (an item is at most 2 KiB). */
const INLINE_COPY = 300

const readNotes = async (options?: CmuxCallOptions): Promise<Note[]> => (await cmux.call<Note[] | null>("app.storage.get", { key: "notes" }, options)) ?? []

const firstLine = (text: string) => text.split("\n", 1)[0]!.slice(0, 120)

function excerpt(body: string, needle: string): string {
  const at = body.toLowerCase().indexOf(needle)
  if (at < 0) return firstLine(body)
  const start = Math.max(0, at - 30)
  return `${start > 0 ? "…" : ""}${body.slice(start, at + needle.length + 60).replace(/\s+/g, " ")}`
}

function toItem(n: Note, subtitle?: string): CmuxPaletteItem {
  return {
    id: n.id,
    title: n.title,
    subtitle: subtitle ?? n.folder ?? firstLine(n.body),
    symbol: n.pinned ? "pin.fill" : "note.text",
    keywords: n.tags ?? [],
    accessory: { date: n.updatedAt },
    actions: [act(`${APP}#open`, { id: n.id }), n.body.length <= INLINE_COPY ? act("clipboard.write", { text: n.body }, { symbol: "doc.on.doc" }) : act(`${APP}#copy`, { id: n.id })]
  }
}

const byPinnedThenRecent = (a: Note, b: Note) => Number(!!b.pinned) - Number(!!a.pinned) || b.updatedAt - a.updatedAt

/** The `notes` scope: every note, pinned first, then most recent. */
export const noteCorpus = palette.snapshot(async () => (await readNotes()).sort(byPinnedThenRecent).slice(0, 10_000).map((n) => toItem(n)))

/** The `search` scope: title matches first, then body matches, as two batches. */
export const searchNotes = palette.query(async function* (query, { signal }) {
  // Offline or slow storage: the last result for this query prefix first.
  yield palette.cached()
  const notes = (await readNotes({ signal })).sort(byPinnedThenRecent)
  const needle = query.trim().toLowerCase()
  const inTitle = notes.filter((n) => n.title.toLowerCase().includes(needle))
  yield inTitle.slice(0, 200).map((n) => toItem(n))
  const inBody = notes.filter((n) => !inTitle.includes(n) && n.body.toLowerCase().includes(needle))
  yield inBody.slice(0, 200).map((n) => toItem(n, excerpt(n.body, needle)))
})

/** Detail pane of `notes` (listWithDetail): the note as markdown. */
export const noteDetail = palette.detail(async (id) => {
  const note = (await readNotes()).find((n) => n.id === id)
  return note ? { markdown: `# ${note.title}\n\n${note.body}`, actions: toItem(note).actions } : null
})

/** `new` (mode form): the palette renders the arguments schema as a form; the CLI and MCP pass the same arguments. */
export async function newNote(args: { title: string; body?: string }, ctx: CmuxCommandContext) {
  const notes = await readNotes()
  const next = Number((await ctx.cmux.storage.get("nextId")) ?? notes.length + 1)
  const note: Note = { id: `n${next}`, title: args.title.trim(), body: args.body ?? "", updatedAt: Date.now() }
  // Through ctx.cmux, so the writes carry the user's gesture (origin user).
  await ctx.cmux.storage.set("notes", [...notes, note])
  await ctx.cmux.storage.set("nextId", next + 1)
  return { id: note.id }
}

/** `open`: the rows' primary action. Remembers the note as recent. */
export async function openNote(args: { id: string }, ctx: CmuxCommandContext) {
  const note = (await readNotes()).find((n) => n.id === args.id)
  if (!note) throw new CmuxError("note.missing", `no note ${args.id}`)
  const recent = ((await ctx.cmux.storage.get("recent")) as string[] | null) ?? []
  await ctx.cmux.storage.set("recent", [note.id, ...recent.filter((id) => id !== note.id)].slice(0, 20))
  return { id: note.id, title: note.title }
}

/** `copy`: copies a long body that does not fit in an item. */
export async function copyNote(args: { id: string }, ctx: CmuxCommandContext) {
  const note = (await readNotes()).find((n) => n.id === args.id)
  if (!note) throw new CmuxError("note.missing", `no note ${args.id}`)
  await ctx.cmux.call("clipboard.write", { text: note.body })
  return { id: note.id }
}
