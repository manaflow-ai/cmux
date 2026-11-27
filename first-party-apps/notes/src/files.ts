/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Markdown export and import through folder and file handles the user picks.
// `fs.pick` (origin user: it needs the gesture token of a tap) shows the
// system panel and returns an opaque root handle (`root_…`) plus the picked
// entries; `fs.write` and `fs.read` take that handle and a path inside it. The
// app never sees or sends an absolute path, and a handle reaches nothing
// outside what the user picked.

import { fromMarkdown, toMarkdown, uniqueFileNames } from "./model.ts"
import { api, type Note } from "./notes.ts"
import { createNote, summaries } from "./store.ts"

export interface PickedFolder {
  root: string
  /** What the panel shows the user ("Notes export"), for messages only. */
  name: string
}

export interface PickedFiles extends PickedFolder {
  entries: Array<{ path: string; name: string; size: number }>
}

/** Thrown when the user closes the panel without picking (not an error to show). */
export const CANCELLED = "fs.cancelled"

const pick = <T>(params: Record<string, unknown>, gesture: string | null) => cmux.call<T>("fs.pick", params, gesture ? { gesture } : undefined)

/**
 * Writes notes as `.md` files into a folder the user picks: one note, or all
 * notes (oldest first) when `ids` is absent. Existing files are never
 * overwritten: the host picks a free name (`exists: "unique"`).
 */
export async function exportNotes(ids: string[] | null, gesture: string | null): Promise<{ folder: string; files: string[] }> {
  const folder = await pick<PickedFolder>({ mode: "folder", purpose: "export", create: true }, gesture)
  const chosen = ids ? ids : summaries().slice().sort((a, b) => a.created_at - b.created_at).map((n) => n.id)
  const notes: Note[] = []
  for (const id of chosen) notes.push(await api.get(id))
  const names = uniqueFileNames(notes)
  const files: string[] = []
  for (const [i, note] of notes.entries()) {
    const r = await cmux.call<{ path: string }>("fs.write", { root: folder.root, path: names[i], text: toMarkdown(note), exists: "unique" }, { idempotencyKey: `export:${folder.root}:${note.id}:${note.revision}` })
    files.push(r.path)
  }
  return { folder: folder.name, files }
}

const MAX_IMPORT_BYTES = 1_000_000

/**
 * Imports `.md` files the user picks, one note each. A leading `# Title`
 * becomes the note's title. Files larger than a note may hold are skipped.
 */
export async function importNotes(gesture: string | null): Promise<{ imported: string[]; skipped: string[] }> {
  const picked = await pick<PickedFiles>({ mode: "files", purpose: "import", accept: [".md", ".markdown", ".txt"], multiple: true }, gesture)
  const imported: string[] = []
  const skipped: string[] = []
  for (const entry of picked.entries) {
    if (entry.size > MAX_IMPORT_BYTES) {
      skipped.push(entry.name)
      continue
    }
    const file = await cmux.call<{ text: string }>("fs.read", { root: picked.root, path: entry.path, max_bytes: MAX_IMPORT_BYTES })
    // The key makes a retried import create each note once.
    const note = await createNote(fromMarkdown(file.text), `import:${picked.root}:${entry.path}`)
    if (note) imported.push(note.id)
  }
  return { imported, skipped }
}
