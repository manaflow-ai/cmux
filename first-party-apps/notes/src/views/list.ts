// The note list: search field, rows (pinned first), and optionally the
// selected note's body inline under its row. Used by the "list" variant, the
// lower half of the "scratchpad" variant and the left column of "split".

import { t } from "../l10n.ts"
import { emptyNote, searchNotes, sortNotes, type Note } from "../model.ts"
import { sortOrder } from "../settings.ts"
import { findNote, notes, ready } from "../store.ts"
import { newNoteHere, noteBody, noteRow, searchField } from "./common.ts"
import type { ViewState } from "./state.ts"

/** Reads a note by id; keeps the last copy so a row being removed in this flush never sees null. */
export function noteById(id: () => string): () => Note {
  let last: Note = emptyNote(id(), 0)
  return () => {
    const n = findNote(id())
    if (n) last = n
    return last
  }
}

export function listHeader(vs: ViewState) {
  return HStack({ spacing: 6 }, [
    searchField(vs).layoutPriority(1),
    Button(Icon("square.and.pencil").secondary(), () => newNoteHere(vs)).help(t("action.new", "New Note"))
  ])
}

export interface ListOptions {
  /** Hide this note (the scratchpad shown above the list). */
  exclude?: () => string | null
  /** Show the selected note's body under its row. */
  inlineDetail: boolean
  showWorkspace: boolean
  /** Show nothing (instead of the onboarding empty state) when there are no notes. */
  quietWhenEmpty?: boolean
}

export function visibleNotes(vs: ViewState, exclude?: () => string | null) {
  return computed(() => {
    const skip = exclude?.() ?? null
    const all = notes().filter((n) => n.id !== skip)
    const q = vs.query()
    return q.trim() ? searchNotes(all, q).map((h) => h.note) : sortNotes(all, sortOrder())
  })
}

export function notesList(vs: ViewState, opts: ListOptions) {
  const visible = visibleNotes(vs, opts.exclude)
  const items = computed(() => {
    const out: Array<{ key: string; id: string; detail: boolean }> = []
    const selected = vs.selected()
    for (const n of visible()) {
      out.push({ key: `row:${n.id}`, id: n.id, detail: false })
      if (opts.inlineDetail && n.id === selected) out.push({ key: `detail:${n.id}`, id: n.id, detail: true })
    }
    return out
  })
  // A string, so the empty state is rebuilt only when it changes kind.
  const empty = computed(() => {
    if (!ready() || visible().length) return "none"
    if (vs.query().trim()) return "search"
    return opts.quietWhenEmpty ? "none" : "empty"
  })
  return VStack({ spacing: 1 }, [
    ForEach({ items, key: (i) => i.key }, (item) => {
      const id = () => item().id
      return item().detail
        ? VStack({ spacing: 0 }, [noteBody(id, vs)]).padding({ top: 2, leading: 30, bottom: 8, trailing: 6 })
        : noteRow(noteById(id), vs, { showWorkspace: opts.showWorkspace })
    }),
    () => {
      const state = empty()
      if (state === "search") return EmptyState({ title: t("empty.search", "No matching notes"), symbol: "magnifyingglass" })
      if (state === "empty") return EmptyState({ title: t("empty.title", "No notes"), message: t("empty.message", "Create one with New Note, or ask an agent to keep notes for you."), symbol: "note.text" })
      return null
    }
  ])
}
