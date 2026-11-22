// One directory browser: a location, its listing (cursor batches + watch
// events through the pure reducer), the selection and the row window. Each
// list, column or side of the dual pane owns one.

import { type Conn, ops, type Root } from "./data/ops.ts"
import { DEFAULT_FILTER, DEFAULT_SORT, type Entry, type Sort, type SortKey } from "./model/entries.ts"
import { join, type Location, locationKey, parent } from "./model/handles.ts"
import { canLoadMore, initialListing, type ListingAction, type ListingState, reduceListing, visibleEntries, type WatchEvent } from "./model/listing.ts"
import { connById, rootById } from "./store.ts"
import { cleanup } from "./runtime.ts"

export const PAGE = 200

export type Browser = ReturnType<typeof createBrowser>

/**
 * `pageRows`: rows per page. The scene has no scroll container and reports no
 * visible range (finder.md gaps G1, G2), so the list pages through the loaded
 * rows and asks the owner for the next batch when a page reaches past them.
 */
export function createBrowser(opts: { pageRows?: number } = {}) {
  const pageRows = opts.pageRows ?? 24
  const [location, setLocation] = signal<Location | null>(null)
  const [state, setState] = signal<ListingState>(initialListing())
  const [selection, setSelection] = signal<string[]>([])
  const [offset, setOffset] = signal(0)
  // A plain mirror of the state: reading the signal here would subscribe the caller (the pane's render) to every listing change.
  let current = initialListing()
  let unwatch: (() => void) | null = null
  let lastConnState: string | null = null

  const apply = (a: ListingAction) => {
    current = reduceListing(current, a)
    setState(current)
  }

  const conn = (): Conn | null => {
    const l = location()
    return l ? connById(l.conn) : null
  }
  const root = (): Root | null => {
    const l = location()
    return l ? rootById(l.root) : null
  }
  const connected = (): boolean => (conn()?.state ?? "connected") === "connected"

  async function fetchPage(loc: Location, key: string, cursor: string | null) {
    const s = current
    const r = await ops.list(loc, s.sort, s.filter, PAGE, cursor, s.listing)
    if (r.ok) apply({ type: "batch", key, batch: r.value })
    else apply({ type: "error", key, error: r.error })
  }

  function watch(loc: Location, key: string) {
    unwatch?.()
    unwatch = cmux.events.on(
      "fs.watch",
      (p) => {
        const m = p as { conn?: string; root?: string; path?: string; event?: WatchEvent } | null
        if (!m?.event) return
        if (m.conn !== undefined && locationKey({ conn: m.conn, root: m.root ?? "", path: m.path ?? "" }) !== key) return
        apply({ type: "watch", key, event: m.event })
        if (current.status === "stale") void relist()
      },
      { conn: loc.conn, root: loc.root, path: loc.path }
    )
  }

  async function load(keepRows = false) {
    const loc = location()
    if (!loc) return
    const key = locationKey(loc)
    apply({ type: "open", key, keepRows })
    if (!connected()) return
    // Subscribe before listing: events that beat the first batch are buffered by the reducer and replayed against its revision.
    watch(loc, key)
    await fetchPage(loc, key, null)
  }

  function open(loc: Location) {
    setLocation(loc)
    setSelection([])
    setOffset(0)
    lastConnState = connById(loc.conn)?.state ?? "connected"
    void load()
  }

  const relist = () => load(true)

  // A connection that comes up (connect sheet finished, link reconnected) starts the listing it was waiting for.
  effect(() => {
    const l = location()
    const st = l ? (connById(l.conn)?.state ?? "connected") : null
    if (st === "connected" && lastConnState !== null && lastConnState !== "connected") void load(current.status !== "idle")
    lastConnState = st
  })

  cleanup(() => unwatch?.())

  const allRows = (): Entry[] => visibleEntries(state())
  const rows = (): Entry[] => allRows().slice(offset(), offset() + pageRows)

  return {
    location,
    state,
    selection,
    conn,
    root,
    connected,
    rows,
    allRows,
    offset,
    pageRows,
    open,
    relist,
    up() {
      const l = location()
      const p = l ? parent(l.path) : null
      if (l && p !== null) open({ ...l, path: p })
    },
    into(name: string) {
      const l = location()
      if (l) open({ ...l, path: join(l.path, name) })
    },
    select(name: string | null) {
      setSelection(name ? [name] : [])
    },
    selectAll() {
      setSelection(allRows().map((e) => e.name))
    },
    selected: (): Entry | null => {
      const names = selection()
      if (names.length !== 1) return null
      return allRows().find((e) => e.name === names[0]) ?? null
    },
    hasPrev: () => offset() > 0,
    hasNext: () => offset() + pageRows < allRows().length || canLoadMore(state()),
    prev() {
      setOffset((o) => Math.max(0, o - pageRows))
    },
    /** Next page; asks the owner for the next batch when the page reaches past the loaded rows. */
    async next() {
      const l = location()
      const target = offset() + pageRows
      if (l && canLoadMore(current) && allRows().length < target + pageRows) await fetchPage(l, locationKey(l), current.cursor)
      if (target < allRows().length) setOffset(target)
    },
    setSort(key: SortKey) {
      const s = current.sort
      const sort: Sort = s.key === key ? { ...s, dir: s.dir === "asc" ? "desc" : "asc" } : { ...s, key, dir: key === "name" || key === "kind" ? "asc" : "desc" }
      apply({ type: "sort", sort })
      if (current.status === "stale") void relist()
    },
    toggleHidden() {
      apply({ type: "filter", filter: { ...current.filter, hidden: !current.filter.hidden } })
      if (current.status === "stale") void relist()
    },
    setQuery(query: string) {
      apply({ type: "filter", filter: { ...current.filter, query } })
      if (current.status === "stale") void relist()
    },
    /** Closes the location (a column the user navigated away from). */
    reset() {
      unwatch?.()
      unwatch = null
      lastConnState = null
      setLocation(null)
      setSelection([])
      current = initialListing(DEFAULT_SORT, DEFAULT_FILTER)
      setState(current)
    }
  }
}
