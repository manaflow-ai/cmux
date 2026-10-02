// View state. It belongs to one mounted surface (client view state stays
// client): selection, query, the line being edited, expanded notes. Writes
// from commands never touch it; only `requestSelect` from a user command does.

import { type Workspaces, watchWorkspaces } from "../workspace.ts"

export interface ViewState {
  selected: () => string | null
  select: (id: string | null) => void
  toggle: (id: string) => void
  query: () => string
  setQuery: (q: string) => void
  editingLine: () => { id: string; index: number } | null
  setEditingLine: (v: { id: string; index: number } | null) => void
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

export function createViewState(ctx: Record<string, unknown>): ViewState {
  const [selected, select] = signal<string | null>(null)
  const [query, setQuery] = signal("")
  const [editingLine, setEditingLine] = signal<{ id: string; index: number } | null>(null)
  const [expanded, setExpandedSet] = signal<ReadonlySet<string>>(new Set())
  const [fieldGeneration, setFieldGeneration] = signal(0)
  let seen = selectRequest()?.seq ?? 0 // render runs untracked; older requests are ignored
  effect(() => {
    const r = selectRequest()
    if (!r || r.seq === seen) return
    seen = r.seq
    // Writes do not track reads, so this effect depends on selectRequest only.
    select(r.id)
    setQuery("")
    setFieldGeneration((g) => g + 1)
  })
  return {
    selected,
    select: (id) => {
      select(id)
      setEditingLine(null)
    },
    toggle: (id) => {
      select((cur) => (cur === id ? null : id))
      setEditingLine(null)
    },
    query,
    setQuery,
    editingLine,
    setEditingLine,
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
