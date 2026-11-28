/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// View state only: the listed page, the filters the user chose, the
// selection and transient notices. Items, lifecycle, triage, order, groups and
// counts belong to the feed owner. A listed page follows the owner's op
// events (src/events.ts); it lists again only when an event brings items the
// page cannot know.

import { applyEvent, type Page } from "./events.ts"
import { feed, FEED_STREAM, type Counts, type FeedEvent, type FeedItem, type GroupBy, type ListParams, type PosterKind } from "./feed.ts"
import { t } from "./l10n.ts"
import { asGroupBy, settings, VARIANTS, type Variant } from "./settings.ts"

export const codeOf = (e: unknown) => (e && typeof e === "object" && "code" in e ? String((e as { code: unknown }).code) : "")

/** A readable reason for a failed call. */
export function describe(e: unknown): string {
  const code = codeOf(e)
  if (code === "scope.missing") return t("reason.scope")
  if (code === "operation.unsupported") return t("reason.unsupported")
  if (code === "feed.closed") return t("reason.closed")
  return e instanceof Error ? e.message : String(e)
}

// Filters the user picks; they map onto `feed.list` params.

export type SourceFilter = "all" | "agent" | "integration" | "automation" | "app" | "system"
export const SOURCES: readonly SourceFilter[] = ["all", "agent", "integration", "automation", "app", "system"]

export interface ViewFilters {
  source: SourceFilter
  unreadOnly: boolean
  needsResponseOnly: boolean
  /** The archived ("done") list instead of the active one. */
  showDone: boolean
}

export const DEFAULT_FILTERS: ViewFilters = { source: "all", unreadOnly: false, needsResponseOnly: false, showDone: false }

export const LIST_LIMIT = 100

export function listParamsFor(f: ViewFilters, groupBy: GroupBy | null, limit = LIST_LIMIT): ListParams {
  const p: ListParams = f.showDone ? { state: "all", archived: true, order: "recent" } : { state: "open", order: "urgent" }
  if (f.source !== "all") p.poster_kind = f.source as PosterKind
  if (f.unreadOnly) p.unread = true
  if (f.needsResponseOnly && !f.showDone) p.needs_response = true
  if (groupBy) p.group_by = groupBy
  p.limit = limit
  return p
}

export const [filters, setFiltersSignal] = signal<ViewFilters>(DEFAULT_FILTERS)
const [groupOverride, setGroupOverride] = signal<GroupBy | null>(null)
export const groupBy = computed<GroupBy>(() => groupOverride() ?? settings().groupBy)
export const variant = computed<Variant>(() => settings().variant)
export const [selected, setSelected] = signal<string | null>(null)
export const [notice, setNotice] = signal<string | null>(null)

// View preferences in app storage (per viewer; never item state).

let viewLoading: Promise<void> | null = null
const persist = (key: string, value: unknown) => cmux.storage.set(key, value).catch((e: unknown) => cmux.log(`storage ${key}: ${describe(e)}`))

export function ensureView(): Promise<void> {
  viewLoading ??= cmux.storage
    .get<{ filters?: Partial<ViewFilters>; groupBy?: string }>("view")
    .catch(() => null)
    .then((view) => {
      if (view?.filters) setFiltersSignal({ ...DEFAULT_FILTERS, ...view.filters, showDone: false })
      if (view?.groupBy) setGroupOverride(asGroupBy(view.groupBy))
    })
  return viewLoading
}

const saveView = () => void persist("view", { filters: { ...filters(), showDone: false }, groupBy: groupOverride() })

export function setFilters(change: Partial<ViewFilters>): void {
  setFiltersSignal({ ...filters(), ...change })
  saveView()
}

export function setGrouping(by: GroupBy): void {
  setGroupOverride(by)
  saveView()
}

// A listed page that follows the owner's events.

export interface FeedView {
  page: () => Page | null
  items: () => FeedItem[]
  error: () => { code: string; message: string } | null
  loaded: () => boolean
  /** Lists now (commands with nothing mounted, and the first read). */
  reload: () => Promise<Page>
}

const [counts, setCounts] = signal<Counts | null>(null)
export { counts }
let countsLoading = false
let countsAgain = false

/** Reads `feed.counts`; a read asked for while one is in flight runs once after it. */
function loadCounts(): void {
  if (countsLoading) {
    countsAgain = true
    return
  }
  countsLoading = true
  feed
    .counts()
    .then(setCounts)
    .catch((e: unknown) => cmux.log(`feed.counts: ${describe(e)}`))
    .finally(() => {
      countsLoading = false
      if (countsAgain) {
        countsAgain = false
        loadCounts()
      }
    })
}

/**
 * A page for `params` in the calling mount: it lists when params change and
 * patches itself from the owner's op events. The subscription and the effect
 * belong to the mount and end with it.
 */
export function createFeedView(params: () => ListParams, options: { primary?: boolean } = {}): FeedView {
  const [page, setPageSignal] = signal<Page | null>(null)
  const [error, setError] = signal<{ code: string; message: string } | null>(null)
  const setPage = (p: Page) => {
    setPageSignal(p)
    if (options.primary) setLatest(p.items)
  }
  let seq = 0
  let lastSeq = 0
  let queued = false
  const reload = () => {
    const mine = ++seq
    return feed.list(params()).then(
      (r) => {
        const next: Page = r.groups ? { items: r.items, groups: r.groups } : { items: r.items }
        if (mine === seq) {
          setPage(next)
          setError(null)
        }
        return next
      },
      (e: unknown) => {
        if (mine === seq) setError({ code: codeOf(e), message: describe(e) })
        throw e
      }
    )
  }
  // Several events in one turn cost one list.
  const relistSoon = () => {
    if (queued) return
    queued = true
    void Promise.resolve().then(() => {
      queued = false
      reload().catch(() => undefined)
    })
  }
  cmux.events.on(FEED_STREAM, (payload) => {
    const ev = payload as FeedEvent
    if (!ev || typeof ev.op !== "string") return
    // The stream is at-least-once: an event seen twice changes nothing.
    if (typeof ev.seq === "number") {
      if (ev.seq <= lastSeq) return
      lastSeq = ev.seq
    }
    const current = page()
    if (current) {
      const patch = applyEvent(current, ev, params(), Date.now())
      if (patch.page !== current) setPage(patch.page)
      if (patch.relist) relistSoon()
    }
    if (!["feed.seen", "feed.push_due", "feed.prefs.set"].includes(ev.op)) loadCounts()
  })
  if (counts() === null) loadCounts()
  effect(() => {
    params()
    reload().catch(() => undefined)
  })
  return {
    page,
    items: computed(() => page()?.items ?? []),
    error,
    loaded: computed(() => page() !== null || error() !== null),
    reload
  }
}

/** The main list's params (sections and panes share one filter set). */
export const mainParams = () => listParamsFor(filters(), variant() === "grouped" ? groupBy() : null)

/** The most recent main page, for commands (palette, keyboard) that run with or without a mounted list. */
const [latest, setLatest] = signal<FeedItem[]>([])
export const items = latest
export const current = computed<FeedItem | null>(() => latest().find((i) => i.id === selected()) ?? latest()[0] ?? null)

/** Lists once without subscribing (commands with nothing mounted). */
export async function listNow(): Promise<FeedItem[]> {
  await ensureView()
  const r = await feed.list(listParamsFor(filters(), null))
  setLatest(r.items)
  return r.items
}

/** The owner's groups resolved to items (the view never groups by itself). */
export function groupsOf(view: FeedView) {
  return computed(() => {
    const p = view.page()
    if (!p?.groups) return [{ key: "all", label: "", items: p?.items ?? [] }]
    const byId = new Map(p.items.map((i) => [i.id, i]))
    return p.groups.map((g) => ({ key: g.key, label: g.label, items: g.items.map((id) => byId.get(id)).filter((i): i is FeedItem => !!i) })).filter((g) => g.items.length > 0)
  })
}

// Variant switching (dogfood only): the config layer owns the setting.

export async function cycleVariant(): Promise<Variant> {
  const next = VARIANTS[(VARIANTS.indexOf(variant()) + 1) % VARIANTS.length]!
  await cmux.app.settings.set({ variant: next })
  return next
}

export function noticeFor(message: string): void {
  setNotice(message)
  cmux.timer.after(6000, () => setNotice(null))
}
