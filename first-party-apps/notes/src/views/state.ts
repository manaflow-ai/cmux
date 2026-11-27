/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// View state. It belongs to one mounted surface (client view state stays
// client): selection, query and search results, expanded notes. Writes from
// commands and agents never touch it; only `requestSelect` from a user
// command does.

import { api, type NoteSummary } from "../notes.ts"
import { type Workspaces, watchWorkspaces } from "../workspace.ts"

export interface ViewState {
  selected: () => string | null
  select: (id: string | null) => void
  toggle: (id: string) => void
  query: () => string
  setQuery: (q: string) => void
  /** The server's answer for the current query (null while there is no query). */
  results: () => NoteSummary[] | null
  isExpanded: (id: string) => boolean
  setExpanded: (id: string, on: boolean) => void
  ws: Workspaces
  /** Bumped to rebuild the search field when the query is cleared from code (the renderer keeps typed text otherwise). */
  searchGeneration: () => number
  clearSearch: () => void
}

const [selectRequest, setSelectRequest] = signal<{ id: string; seq: number } | null>(null)
let seq = 0

/** A user command (New Note, Open Note) asks every mounted surface to show a note. */
export function requestSelect(id: string): void {
  setSelectRequest({ id, seq: ++seq })
}

const [notice, setNotice] = signal<string | null>(null)
export { notice }

/** A transient one-line message (export done, a refused edit). */
export function noticeFor(message: string): void {
  setNotice(message)
  cmux.timer.after(6000, () => setNotice(null))
}

export function createViewState(ctx: Record<string, unknown>): ViewState {
  const [selected, select] = signal<string | null>(null)
  const [query, setQuery] = signal("")
  const [results, setResults] = signal<NoteSummary[] | null>(null)
  const [expanded, setExpandedSet] = signal<ReadonlySet<string>>(new Set())
  const [fieldGeneration, setFieldGeneration] = signal(0)
  let seen = selectRequest()?.seq ?? 0 // render runs untracked; older requests are ignored
  effect(() => {
    const r = selectRequest()
    if (!r || r.seq === seen) return
    seen = r.seq
    select(r.id)
    setQuery("")
    setFieldGeneration((g) => g + 1)
  })
  // The server searches (it indexes every note); the latest query wins.
  let asked = 0
  effect(() => {
    const q = query().trim()
    const mine = ++asked
    if (!q) return setResults(null)
    api.list({ query: q, limit: 50 }).then(
      (r) => mine === asked && setResults(r.notes),
      () => mine === asked && setResults([])
    )
  })
  return {
    selected,
    select,
    toggle: (id) => select((cur) => (cur === id ? null : id)),
    query,
    setQuery,
    results,
    isExpanded: (id) => expanded().has(id),
    setExpanded: (id, on) =>
      setExpandedSet((set) => {
        const next = new Set(set)
        if (on) next.add(id)
        else next.delete(id)
        return next
      }),
    ws: watchWorkspaces(ctx),
    searchGeneration: fieldGeneration,
    clearSearch: () => {
      setQuery("")
      setFieldGeneration((g) => g + 1)
    }
  }
}
