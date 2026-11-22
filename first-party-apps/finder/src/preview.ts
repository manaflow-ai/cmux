// Preview of the selected entry (finder.md section 6). The real design embeds
// the user's `cmux.viewer/1` app for the file's type; until embeds exist the
// app shows a built-in preview from `fs.read` (text, capped) and
// `fs.thumbnail` (images, PDF first page), and says which viewer would show it.

import { ops, type OpError } from "./data/ops.ts"
import { type Entry, kindGroup, type KindGroup } from "./model/entries.ts"
import { join, type Location, locationKey } from "./model/handles.ts"

export const TEXT_PREVIEW_BYTES = 32 * 1024
export const TEXT_PREVIEW_LINES = 28
export const MAX_TEXT_FILE = 8 * 1000 * 1000

export type PreviewState =
  | { status: "none" }
  | { status: "loading"; entry: Entry; group: KindGroup }
  | { status: "meta"; entry: Entry; group: KindGroup; reason: "folder" | "too_large" | "binary" | "no_viewer" }
  | { status: "text"; entry: Entry; group: KindGroup; lines: string[]; truncated: boolean }
  | { status: "image"; entry: Entry; group: KindGroup; image: string; width: number; height: number; pages: number | null }
  | { status: "error"; entry: Entry; group: KindGroup; error: OpError }

/** First lines of a text preview; long lines are cut so one row stays one row. */
export function previewLines(text: string, maxLines = TEXT_PREVIEW_LINES, maxCols = 160): string[] {
  return text
    .split(/\r?\n/)
    .slice(0, maxLines)
    .map((l) => (l.length > maxCols ? `${l.slice(0, maxCols)}…` : l).replace(/\t/g, "  "))
}

/** Follows any selection source: one browser, or the last column of the column view. */
export function createPreview(b: { selected: () => Entry | null; location: () => Location | null }) {
  const [state, setState] = signal<PreviewState>({ status: "none" })
  let token = 0

  // Same object while the selected entry is unchanged, so watch events on other rows do not refetch the preview.
  let last: { key: string; entry: Entry | null; loc: Location | null } = { key: "", entry: null, loc: null }
  const target = computed(() => {
    const entry = b.selected()
    const loc = b.location()
    const key = entry && loc ? `${locationKey(loc)}|${entry.name}|${entry.mtime}|${entry.size}` : ""
    if (key !== last.key) last = { key, entry, loc }
    return last
  })

  effect(() => {
    const { entry, loc } = target()
    const my = ++token
    if (!entry || !loc) {
      setState({ status: "none" })
      return
    }
    const group = kindGroup(entry)
    if (group === "folder") return setState({ status: "meta", entry, group, reason: "folder" })
    const where = { ...loc, path: join(loc.path, entry.name) }
    if (group === "text" || group === "markdown" || group === "code") {
      if ((entry.size ?? 0) > MAX_TEXT_FILE) return setState({ status: "meta", entry, group, reason: "too_large" })
      setState({ status: "loading", entry, group })
      void ops.read(where, TEXT_PREVIEW_BYTES).then((r) => {
        if (my !== token) return
        if (!r.ok) return setState({ status: "error", entry, group, error: r.error })
        if (r.value.text === null) return setState({ status: "meta", entry, group, reason: "binary" })
        setState({ status: "text", entry, group, lines: previewLines(r.value.text), truncated: r.value.truncated })
      })
      return
    }
    if (group === "image" || group === "pdf") {
      setState({ status: "loading", entry, group })
      void ops.thumbnail(where, 512).then((r) => {
        if (my !== token) return
        if (!r.ok) return setState({ status: "error", entry, group, error: r.error })
        setState({ status: "image", entry, group, image: r.value.image, width: r.value.width, height: r.value.height, pages: r.value.pages ?? null })
      })
      return
    }
    setState({ status: "meta", entry, group, reason: "no_viewer" })
  })

  return state
}
