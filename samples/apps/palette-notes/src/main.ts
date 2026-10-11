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
/** An item is at most 2 KiB of UTF-8 JSON; the runtime refuses a bigger one and the whole snapshot with it. */
const ITEM_BYTES = 2048
/** Bodies up to this many UTF-8 bytes are copied by `clipboard.write` straight from the row; longer ones through the `copy` command. */
const INLINE_COPY_BYTES = 600
const MAX_TAGS = 8
const MAX_TAG = 32
const MAX_TEXT = 120

/** UTF-8 bytes of a string (no TextEncoder in every engine). */
function utf8Bytes(text: string): number {
  let n = 0
  for (const ch of text) {
    const c = ch.codePointAt(0)!
    n += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4
  }
  return n
}

const clip = (text: string, max: number) => (Array.from(text).length > max ? `${Array.from(text).slice(0, max - 1).join("")}…` : text)

const readNotes = async (options?: CmuxCallOptions): Promise<Note[]> => (await cmux.call<Note[] | null>("app.storage.get", { key: "notes" }, options)) ?? []

const firstLine = (text: string) => clip(text.split("\n", 1)[0]!, MAX_TEXT)

function excerpt(body: string, needle: string): string {
  const at = body.toLowerCase().indexOf(needle)
  if (at < 0) return firstLine(body)
  const start = Math.max(0, at - 30)
  return `${start > 0 ? "…" : ""}${body.slice(start, at + needle.length + 60).replace(/\s+/g, " ")}`
}

/**
 * One row, within the item budget: titles, subtitles and tags are clipped; a body is copied
 * inline only when it is small, else through the `copy` command; a row that still does not
 * fit is dropped (null) so one big note never fails the whole snapshot.
 */
function toItem(n: Note, subtitle?: string): CmuxPaletteItem | null {
  const copy = utf8Bytes(n.body) <= INLINE_COPY_BYTES ? act("clipboard.write", { text: n.body }, { symbol: "doc.on.doc" }) : act(`${APP}#copy`, { id: n.id })
  const item: CmuxPaletteItem = {
    id: n.id,
    title: clip(n.title, MAX_TEXT),
    subtitle: clip(subtitle ?? n.folder ?? firstLine(n.body), MAX_TEXT),
    symbol: n.pinned ? "pin.fill" : "note.text",
    keywords: (n.tags ?? []).slice(0, MAX_TAGS).map((t) => clip(t, MAX_TAG)),
    accessory: { date: n.updatedAt },
    actions: [act(`${APP}#open`, { id: n.id }), copy]
  }
  if (utf8Bytes(JSON.stringify(item)) <= ITEM_BYTES) return item
  // The inline copy was the large part: fall back to the command.
  item.actions = [act(`${APP}#open`, { id: n.id }), act(`${APP}#copy`, { id: n.id })]
  return utf8Bytes(JSON.stringify(item)) <= ITEM_BYTES ? item : null
}

const rows = (notes: Note[], subtitle?: (n: Note) => string) => notes.map((n) => toItem(n, subtitle?.(n))).filter((i): i is CmuxPaletteItem => i !== null)

const byPinnedThenRecent = (a: Note, b: Note) => Number(!!b.pinned) - Number(!!a.pinned) || b.updatedAt - a.updatedAt

/** The `notes` scope: every note, pinned first, then most recent. */
export const noteCorpus = palette.snapshot(async () => rows((await readNotes()).sort(byPinnedThenRecent).slice(0, 10_000)))

/** The `search` scope: title matches first, then body matches, as two batches. */
export const searchNotes = palette.query(async function* (query, { signal }) {
  // Offline or slow storage: the last result for this query prefix first.
  yield palette.cached()
  const notes = (await readNotes({ signal })).sort(byPinnedThenRecent)
  const needle = query.trim().toLowerCase()
  const inTitle = notes.filter((n) => n.title.toLowerCase().includes(needle))
  yield rows(inTitle.slice(0, 200))
  const inBody = notes.filter((n) => !inTitle.includes(n) && n.body.toLowerCase().includes(needle))
  yield rows(inBody.slice(0, 200), (n) => excerpt(n.body, needle))
})

/** Detail pane of `notes` (listWithDetail): the note as markdown. */
export const noteDetail = palette.detail(async (id) => {
  const note = (await readNotes()).find((n) => n.id === id)
  return note ? { markdown: `# ${note.title}\n\n${note.body}`, actions: toItem(note)?.actions ?? [act(`${APP}#open`, { id: note.id })] } : null
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
