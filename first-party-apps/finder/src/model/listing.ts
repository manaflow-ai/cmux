// Listing reducer: cursor batches from `fs.list` plus `fs.watch` events
// (finder.md section 4.2 and 4.3). Pure, so the same code runs in tests and in
// the app VM.
//
// The owner sorts and filters, takes a snapshot of the directory at revision R
// and hands it out in batches behind a cursor. Watch events after R arrive in
// an overlay (name -> entry, or null when deleted) that the view merges over
// the batches. This keeps three hard cases right without a relist:
//   - a batch that arrives after a watch event for the same name (overlay wins),
//   - an event that arrives before the first batch (buffered, replayed if newer than R),
//   - a file created after R that sorts past the loaded window (shown once loading reaches it).
// overflow, reset and cursor.expired mark the listing stale; the app relists and
// keeps showing the old rows until the new first batch lands.

import { compareEntries, DEFAULT_FILTER, DEFAULT_SORT, type Entry, type Filter, insertionIndex, matchesFilter, type Sort } from "./entries.ts"

export type WatchEvent =
  | { kind: "created" | "modified"; revision: string; entry: Entry }
  | { kind: "deleted"; revision: string; name: string }
  | { kind: "renamed"; revision: string; from: string; entry: Entry }
  | { kind: "overflow" | "reset"; revision: string }

export type Batch = { listing: string; entries: Entry[]; cursor: string | null; total: number | null; revision: string }

export type ListingStatus = "idle" | "loading" | "partial" | "complete" | "stale" | "error"

export type ListingState = {
  key: string | null
  status: ListingStatus
  listing: string | null
  revision: string | null
  base: Entry[]
  overlay: Record<string, Entry | null>
  delta: number
  cursor: string | null
  total: number | null
  error: { code: string; message: string } | null
  sort: Sort
  filter: Filter
  lastWatch: string | null
  early: WatchEvent[]
}

export type ListingAction =
  | { type: "open"; key: string; sort?: Sort; filter?: Filter; keepRows?: boolean }
  | { type: "batch"; key: string; batch: Batch }
  | { type: "watch"; key: string; event: WatchEvent }
  | { type: "error"; key: string; error: { code: string; message: string } }
  | { type: "sort"; sort: Sort }
  | { type: "filter"; filter: Filter }

export const initialListing = (sort: Sort = DEFAULT_SORT, filter: Filter = DEFAULT_FILTER): ListingState => ({
  key: null,
  status: "idle",
  listing: null,
  revision: null,
  base: [],
  overlay: {},
  delta: 0,
  cursor: null,
  total: null,
  error: null,
  sort,
  filter,
  lastWatch: null,
  early: []
})

/** Revisions are decimal strings of unbounded size: compare by length, then text. */
export function revisionCompare(a: string, b: string): number {
  const x = a.replace(/^0+/, "")
  const y = b.replace(/^0+/, "")
  if (x.length !== y.length) return x.length < y.length ? -1 : 1
  return x < y ? -1 : x > y ? 1 : 0
}

function mergeSorted(base: Entry[], add: Entry[], sort: Sort): Entry[] {
  const cmp = compareEntries(sort)
  const names = new Set(base.map((e) => e.name))
  const out = base.slice()
  for (const e of add) {
    if (names.has(e.name)) continue
    names.add(e.name)
    out.splice(insertionIndex(out, e, cmp), 0, e)
  }
  return out
}

/** Folds the overlay into the base (only valid when the listing is complete). */
function fold(s: ListingState): ListingState {
  const names = Object.keys(s.overlay)
  if (names.length === 0) return s
  const kept = s.base.filter((e) => !(e.name in s.overlay))
  const added = names.map((n) => s.overlay[n]).filter((e): e is Entry => !!e)
  return { ...s, base: mergeSorted(kept, added, s.sort), overlay: {}, total: s.total === null ? null : s.total + s.delta, delta: 0 }
}

function applyEvent(s: ListingState, ev: WatchEvent): ListingState {
  if (ev.kind === "overflow" || ev.kind === "reset") return { ...s, status: "stale", lastWatch: ev.revision }
  const overlay = { ...s.overlay }
  let delta = s.delta
  // The owner says "created" only for a name that did not exist, so the count trusts it; a repeated event changes nothing.
  switch (ev.kind) {
    case "created":
      if (!overlay[ev.entry.name]) delta += 1
      overlay[ev.entry.name] = ev.entry
      break
    case "modified":
      overlay[ev.entry.name] = ev.entry
      break
    case "deleted":
      if (overlay[ev.name] !== null || !(ev.name in overlay)) delta -= 1
      overlay[ev.name] = null
      break
    case "renamed":
      overlay[ev.from] = null
      overlay[ev.entry.name] = ev.entry
      break
  }
  const next = { ...s, overlay, delta, lastWatch: ev.revision }
  return next.status === "complete" ? fold(next) : next
}

export function reduceListing(s: ListingState, a: ListingAction): ListingState {
  switch (a.type) {
    case "open": {
      const sort = a.sort ?? s.sort
      const filter = a.filter ?? s.filter
      if (a.keepRows && s.key === a.key) return { ...s, status: "loading", listing: null, cursor: null, error: null, sort, filter, early: [] }
      return { ...initialListing(sort, filter), key: a.key, status: "loading" }
    }
    case "batch": {
      if (a.key !== s.key || s.status === "idle") return s
      const b = a.batch
      const first = s.listing === null
      if (!first && b.listing !== s.listing) return s
      let next: ListingState = first
        ? { ...s, listing: b.listing, revision: b.revision, base: mergeSorted([], b.entries, s.sort), overlay: {}, delta: 0, lastWatch: null, error: null }
        : { ...s, base: mergeSorted(s.base, b.entries, s.sort) }
      next = { ...next, cursor: b.cursor, total: b.total, status: b.cursor ? "partial" : "complete" }
      if (first) {
        const early = s.early
        next = { ...next, early: [] }
        for (const ev of early) if (revisionCompare(ev.revision, b.revision) > 0) next = applyEvent(next, ev)
      }
      return next.status === "complete" ? fold(next) : next
    }
    case "watch": {
      if (a.key !== s.key || s.status === "idle" || s.status === "error") return s
      if (s.revision === null) return { ...s, early: [...s.early, a.event] }
      if (revisionCompare(a.event.revision, s.revision) <= 0) return s
      if (s.lastWatch !== null && revisionCompare(a.event.revision, s.lastWatch) <= 0) return s
      return applyEvent(s, a.event)
    }
    case "error":
      if (a.key !== s.key) return s
      if (a.error.code === "cursor.expired") return { ...s, status: "stale" }
      return { ...s, status: "error", error: a.error }
    case "sort":
    case "filter": {
      const next = a.type === "sort" ? { ...s, sort: a.sort } : { ...s, filter: a.filter }
      // A complete listing is re-sorted here; a partial one must be re-sorted by the owner (it holds the rows we lack).
      if (s.status === "complete") return { ...next, base: mergeSorted([], s.base, next.sort) }
      return s.status === "idle" ? next : { ...next, status: "stale" }
    }
  }
}

/** Rows to show: batches minus overlay deletions plus overlay entries that sort inside the loaded window, then the filter. */
export function visibleEntries(s: ListingState): Entry[] {
  const cmp = compareEntries(s.sort)
  const kept = s.base.filter((e) => !(e.name in s.overlay))
  const last = s.base[s.base.length - 1]
  const added = Object.values(s.overlay).filter((e): e is Entry => !!e && (s.status === "complete" || s.cursor === null || !last || cmp(e, last) <= 0))
  return mergeSorted(kept, added, s.sort).filter((e) => matchesFilter(e, s.filter))
}

/** Owner's total adjusted by watch events since the snapshot; null when the owner did not count. */
export const displayTotal = (s: ListingState): number | null => (s.total === null ? null : s.total + s.delta)

export const needsRelist = (s: ListingState) => s.status === "stale"
export const canLoadMore = (s: ListingState) => s.status === "partial" && s.cursor !== null
