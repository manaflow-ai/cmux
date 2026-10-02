/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// View state only: the last `feed.list` answer, the filters the user chose,
// the selection and transient notices. Items, order, groups, counts, seen,
// done and snooze state belong to the feed owner; this view re-lists when
// the owner says the feed changed.

import { feed, FEED_CHANGED, type FeedChanged, type FeedCounts, type FeedFilter, type FeedGroupBy, type FeedItem, type FeedListParams, type FeedListResult, type SourceKind } from "./feed.ts"
import { t } from "./l10n.ts"
import { asGroupBy, asVariant, settings, VARIANTS, type Variant } from "./settings.ts"

/** A readable reason for a failed call. */
export function describe(e: unknown): string {
  const code = e && typeof e === "object" && "code" in e ? String((e as { code: unknown }).code) : ""
  if (code === "scope.missing") return t("reason.scope", "permission not granted")
  if (code === "operation.unsupported") return t("reason.unsupported", "not supported by this version of cmux")
  return e instanceof Error ? e.message : String(e)
}

export const codeOf = (e: unknown) => (e && typeof e === "object" && "code" in e ? String((e as { code: unknown }).code) : "")

// Filters the user picks; they map onto the owner's `FeedFilter`.

export type SourceFilter = "all" | "agent" | "integration" | "other"

export interface ViewFilters {
  source: SourceFilter
  unseenOnly: boolean
  needsResponseOnly: boolean
  showSnoozed: boolean
}

export const DEFAULT_FILTERS: ViewFilters = { source: "all", unseenOnly: false, needsResponseOnly: false, showSnoozed: false }

const SOURCE_KINDS: Record<Exclude<SourceFilter, "all">, SourceKind[]> = { agent: ["agent"], integration: ["integration"], other: ["app", "run", "user"] }

export function toFeedFilter(f: ViewFilters): FeedFilter {
  const filter: FeedFilter = { status: [f.showSnoozed ? "snoozed" : "open"] }
  if (f.source !== "all") filter.sources = SOURCE_KINDS[f.source]
  if (f.unseenOnly) filter.unseen = true
  if (f.needsResponseOnly) filter.needsResponse = true
  return filter
}

export const LIST_LIMIT = 100

export const [filters, setFiltersSignal] = signal<ViewFilters>(DEFAULT_FILTERS)
const [groupOverride, setGroupOverride] = signal<FeedGroupBy | null>(null)
export const groupBy = computed<FeedGroupBy>(() => groupOverride() ?? settings().groupBy)
export const [selected, setSelected] = signal<string | null>(null)
export const [notice, setNotice] = signal<string | null>(null)
const [variantOverride, setVariantOverride] = signal<{ variant: Variant; base: Variant } | null>(null)
export const variant = computed<Variant>(() => {
  const base = settings().variant
  const o = variantOverride()
  return o && o.base === base ? o.variant : base
})

// The owner's answers.
export const [result, setResult] = signal<FeedListResult | null>(null)
export const [counts, setCounts] = signal<FeedCounts | null>(null)
export const [feedError, setFeedError] = signal<{ code: string; message: string } | null>(null)

export const items = computed<FeedItem[]>(() => result()?.items ?? [])
export const current = computed<FeedItem | null>(() => items().find((i) => i.id === selected()) ?? items()[0] ?? null)
export const loaded = computed(() => result() !== null || feedError() !== null)

/** Groups from the owner, resolved to items (the view never groups by itself). */
export const groups = computed(() => {
  const r = result()
  if (!r?.groups) return [{ key: "all", label: "", sourceKind: undefined as SourceKind | undefined, items: r?.items ?? [] }]
  const byId = new Map(r.items.map((i) => [i.id, i]))
  return r.groups.map((g) => ({ key: g.key, label: g.label, sourceKind: g.sourceKind, items: g.itemIds.map((id) => byId.get(id)).filter((i): i is FeedItem => !!i) })).filter((g) => g.items.length > 0)
})

// View preferences in app storage (per viewer; never item state).

let viewLoading: Promise<void> | null = null
const persist = (key: string, value: unknown) => cmux.storage.set(key, value).catch((e: unknown) => cmux.log(`storage ${key}: ${describe(e)}`))

export function ensureView(): Promise<void> {
  viewLoading ??= Promise.all([
    cmux.storage.get<{ filters?: Partial<ViewFilters>; groupBy?: string }>("view").catch(() => null),
    cmux.storage.get<{ variant?: string; base?: string }>("variantOverride").catch(() => null)
  ]).then(([view, override]) => {
    if (view?.filters) setFiltersSignal({ ...DEFAULT_FILTERS, ...view.filters, showSnoozed: false })
    if (view?.groupBy) setGroupOverride(asGroupBy(view.groupBy))
    if (override?.variant) setVariantOverride({ variant: asVariant(override.variant), base: asVariant(override.base) })
  })
  return viewLoading
}

export function setFilters(change: Partial<ViewFilters>): void {
  const next = { ...filters(), ...change }
  setFiltersSignal(next)
  void persist("view", { filters: { ...next, showSnoozed: false }, groupBy: groupOverride() })
}

export function setGrouping(by: FeedGroupBy): void {
  setGroupOverride(by)
  void persist("view", { filters: { ...filters(), showSnoozed: false }, groupBy: by })
}

// Reading the feed.

export const listParams = (grouped: boolean): FeedListParams => ({ filter: toFeedFilter(filters()), ...(grouped ? { groupBy: groupBy() } : {}), limit: LIST_LIMIT })

/** Bumped to make every mounted list re-read (mounts that went away dropped their effects). */
const [reloadTick, setReloadTick] = signal(0)

/**
 * Lists the feed for the calling mount: now, whenever its filters change, and
 * on every `feed.changed`. `grouped` asks the owner for groups. Call from a render.
 */
export function attachList(grouped: boolean): void {
  void ensureView()
  let seq = 0
  const load = () => {
    const params = listParams(grouped)
    const mine = ++seq
    feed
      .list(params)
      .then((r) => {
        if (mine !== seq) return
        setResult(r)
        setCounts(r.counts)
        setFeedError(null)
      })
      .catch((e: unknown) => {
        if (mine === seq) setFeedError({ code: codeOf(e), message: describe(e) })
      })
  }
  effect(() => {
    filters()
    groupBy()
    reloadTick()
    load()
  })
  cmux.events.on(FEED_CHANGED, (payload) => {
    const p = payload as Partial<FeedChanged> | null
    if (p?.counts) setCounts(p.counts)
    load()
  })
}

/** Counts only (the status item): one read, then the counts each `feed.changed` carries. */
export function attachCounts(): void {
  feed
    .counts()
    .then(setCounts)
    .catch((e: unknown) => setFeedError({ code: codeOf(e), message: describe(e) }))
  cmux.events.on(FEED_CHANGED, (payload) => {
    const p = payload as Partial<FeedChanged> | null
    if (p?.counts) setCounts(p.counts)
  })
}

/**
 * After this view's own mutation: re-list when the owner's revision moved and
 * its `feed.changed` has not arrived yet (the event re-lists too).
 */
export function noteRevision(revision: string | undefined): void {
  if (!revision || result()?.revision === revision) return
  setReloadTick((n) => n + 1)
}

/** Reads once without subscribing (commands run with nothing mounted). */
export async function listNow(params: FeedListParams = listParams(false)): Promise<FeedListResult> {
  await ensureView()
  const r = await feed.list(params)
  setResult(r)
  setCounts(r.counts)
  return r
}

// Variant switching (dogfood only).

export async function cycleVariant(): Promise<Variant> {
  const next = VARIANTS[(VARIANTS.indexOf(variant()) + 1) % VARIANTS.length]!
  const base = settings().variant
  setVariantOverride({ variant: next, base })
  try {
    // Proposed op: the config layer owns settings; apps cannot write them yet.
    await cmux.call("app.settings.set", { key: "variant", value: next })
  } catch {
    await persist("variantOverride", { variant: next, base })
  }
  return next
}

export function noticeFor(message: string): void {
  setNotice(message)
  cmux.timer.after(6000, () => setNotice(null))
}
