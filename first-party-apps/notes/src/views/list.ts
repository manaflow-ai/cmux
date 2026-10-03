/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// The note list: search field, rows (pinned first), and optionally the
// selected note's body inline under its row. Used by the "list" variant, the
// lower half of "scratchpad", and "editor" (rows only; a click opens the editor pane).

import { t } from "../l10n.ts"
import type { NoteSummary } from "../notes.ts"
import { sortOrder } from "../settings.ts"
import { findSummary, ready, sorted, summaries } from "../store.ts"
import { newNoteHere, noteBody, noteRow, searchField, sectionMenu } from "./common.ts"
import type { ViewState } from "./state.ts"

const BLANK: NoteSummary = {
  id: "",
  doc: "",
  title: "",
  title_explicit: false,
  preview: "",
  pinned: false,
  scratchpad: false,
  workspace: null,
  lines: 0,
  created_at: 0,
  updated_at: 0,
  revision: 0,
  last_edit: { actor_kind: "user", actor: "", at: 0 }
}

/** Reads a note by id; keeps the last copy so a row being removed in this flush never sees null. */
export function noteById(id: () => string): () => NoteSummary {
  let last: NoteSummary = BLANK
  return () => {
    const n = findSummary(id())
    if (n) last = n
    return last
  }
}

/** Import and export (right-click: a pull-down Menu takes only a text title, README gaps). */
export const moreButton = (vs: ViewState) =>
  Button(Icon("ellipsis.circle").secondary())
    .help(t("action.more"))
    .contextMenu(() => sectionMenu(vs))

export function listHeader(vs: ViewState) {
  return HStack({ spacing: 6 }, [
    searchField(vs).layoutPriority(1),
    Button(Icon("square.and.pencil").secondary(), () => newNoteHere(vs)).help(t("action.new")),
    moreButton(vs)
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
  /** What a click does instead of toggling the inline body. */
  onTap?: (n: NoteSummary) => unknown
}

/** Every note in order, or the server's search results (kept live by id). */
export function visibleNotes(vs: ViewState, exclude?: () => string | null) {
  return computed(() => {
    const skip = exclude?.() ?? null
    const found = vs.results()
    const pool = found ? found.map((n) => findSummary(n.id) ?? n) : sorted(summaries(), sortOrder())
    return pool.filter((n) => n.id !== skip)
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
    if (vs.query().trim()) return vs.results() ? "search" : "none"
    return opts.quietWhenEmpty ? "none" : "empty"
  })
  return VStack({ spacing: 1 }, [
    ForEach({ items, key: (i) => i.key }, (item) => {
      const note = noteById(() => item().id)
      return item().detail
        ? VStack({ spacing: 0 }, [noteBody(note, vs)]).padding({ top: 2, leading: 30, bottom: 8, trailing: 6 })
        : noteRow(note, vs, { showWorkspace: opts.showWorkspace, onTap: opts.onTap })
    }),
    () => {
      const state = empty()
      if (state === "search") return EmptyState({ title: t("empty.search"), symbol: "magnifyingglass" })
      if (state === "empty") return EmptyState({ title: t("empty.title"), message: t("empty.message"), symbol: "note.text" })
      return null
    }
  ])
}
