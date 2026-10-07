// Derives a listed page's changes from the owner's op events (pure). The
// owner sends one event per committed op ({op, params, actor, at}), never a
// "changed" summary. Ops whose effect is known from their params (answer,
// cancel, read, seen, archive, snooze, expire) patch the listed items with the
// owner's rules; ops that bring in items this page does not hold (post, adopt,
// unarchive, snooze wake-ups) ask for a new list. Kept in step with
// backend/apps/api/src/domains/feed.ts and feed-query.ts.

import type { FeedEvent, FeedFilter, FeedGroup, FeedItem, ListParams } from "./feed.ts"

export interface Page {
  items: FeedItem[]
  groups?: FeedGroup[]
}

export interface Patch {
  page: Page
  /** The page may now miss items the owner would list: list again. */
  relist: boolean
  /** Badge counts may have changed: read `feed.counts` again. */
  recount: boolean
}

const PRIORITY_RANK: Record<string, number> = { urgent: 0, high: 1, normal: 2, low: 3 }

const active = (i: FeedItem) => i.state === "open" && i.archived_at === null

/** The owner's urgent order: open requests (priority, then oldest), then unread active items, then the rest newest first. */
export function urgentCompare(a: FeedItem, b: FeedItem): number {
  const tier = (i: FeedItem) => (i.type === "request" && i.state === "open" ? 0 : active(i) && i.read_at === null ? 1 : 2)
  const ta = tier(a)
  const tb = tier(b)
  if (ta !== tb) return ta - tb
  if (ta === 0) return (PRIORITY_RANK[a.priority] ?? 2) - (PRIORITY_RANK[b.priority] ?? 2) || a.order - b.order
  return b.order - a.order
}

export const matchesFilter = (i: FeedItem, f: FeedFilter) =>
  (f.poster_kind === undefined || i.poster.kind === f.poster_kind) &&
  (f.thread === undefined || i.thread === f.thread) &&
  (f.workspace === undefined || i.context.workspace === f.workspace) &&
  (f.kind === undefined || i.kind === f.kind)

/** Whether the owner would list `i` for `p` (feed-query.ts listItems, without query and paging). */
export function inView(i: FeedItem, p: ListParams, now: number): boolean {
  const stateOk = p.state === undefined || p.state === "all" ? true : p.state === "open" ? i.state === "open" : i.state !== "open"
  return (
    stateOk &&
    (p.type === undefined || i.type === p.type) &&
    matchesFilter(i, p) &&
    (p.unread === undefined || (i.read_at === null) === p.unread) &&
    (p.needs_response === undefined || (i.type === "request" && i.state === "open") === p.needs_response) &&
    (p.archived === true ? i.archived_at !== null : i.archived_at === null) &&
    (p.archived === true || i.snoozed_until === null || i.snoozed_until <= now)
  )
}

const touch = (i: FeedItem, at: number, change: Partial<FeedItem>): FeedItem => ({ ...i, ...change, revision: i.revision + 1, updated_at: at })

type Rule = (i: FeedItem) => FeedItem | null

/** Per-item effect of an op on a listed item, or null when the op does not touch it. */
function ruleFor(ev: FeedEvent): Rule | "relist" | "none" {
  const p = (ev.params ?? {}) as Record<string, unknown>
  const at = ev.at
  const ids = Array.isArray(p.items) ? new Set(p.items as string[]) : null
  const filter = p.filter && typeof p.filter === "object" ? (p.filter as FeedFilter) : null
  const selected = (i: FeedItem) => (ids ? ids.has(i.id) : filter ? matchesFilter(i, filter) : p.all === true)
  const open = (i: FeedItem) => i.type === "request" && i.state === "open"
  switch (ev.op) {
    case "feed.answer":
      return (i) =>
        i.id === p.item && open(i)
          ? touch(i, at, { state: "answered", answer: { value: p.answer, by: ev.actor.identity, device: typeof p.device === "string" ? p.device : null, at }, closed_at: at, read_at: i.read_at ?? at })
          : null
    case "feed.cancel":
      return (i) =>
        i.id === p.item && i.state === "open"
          ? touch(i, at, { state: "cancelled", cancel: { reason: (p.reason as never) ?? "poster", by: ev.actor.identity, at, note: typeof p.note === "string" ? p.note : null }, closed_at: at })
          : null
    case "feed.read":
      return (i) => (i.read_at === null && selected(i) ? touch(i, at, { read_at: at }) : null)
    case "feed.seen":
      return (i) => (i.seen_at === null && selected(i) ? touch(i, at, { seen_at: at }) : null)
    case "feed.archive":
      // A filter archives what it can (open requests are skipped); a list of items with an open request is refused, so never committed.
      return (i) => (i.archived_at === null && selected(i) && !(filter && open(i)) ? touch(i, at, { archived_at: at, read_at: i.read_at ?? at, snoozed_until: null }) : null)
    case "feed.snooze":
      return (i) => (selected(i) && i.snoozed_until !== p.until ? touch(i, at, { snoozed_until: Number(p.until) }) : null)
    case "feed.expire":
      return (i) => (i.state === "open" && i.expires_at <= Number(p.at) ? touch(i, at, { state: "expired", closed_at: i.expires_at }) : null)
    case "feed.push_due":
    case "feed.prefs.set":
      return "none"
    default:
      // feed.post, feed.adopt, feed.unarchive, feed.snooze_wake, feed.prune and any op this view does not know.
      return "relist"
  }
}

/** Ops that can add items to an archived ("done") page. */
const ADDS_TO_DONE = new Set(["feed.archive"])

/** Applies one event to a listed page (pure). */
export function applyEvent(page: Page, ev: FeedEvent, params: ListParams, now: number): Patch {
  const rule = ruleFor(ev)
  const recount = !["feed.seen", "feed.push_due", "feed.prefs.set"].includes(ev.op)
  if (rule === "none") return { page, relist: false, recount: false }
  if (rule === "relist") return { page, relist: true, recount }
  let changed = false
  const patched = page.items.map((i) => {
    const next = rule(i)
    if (next) changed = true
    return next ?? i
  })
  const relist = params.archived === true && ADDS_TO_DONE.has(ev.op)
  if (!changed) return { page, relist, recount }
  const items = patched.filter((i) => inView(i, params, now)).sort(params.order === "recent" ? (a, b) => b.order - a.order : urgentCompare)
  // Groups keep the owner's keys and labels; like the owner's, they follow the
  // first appearance of their items in the page order.
  const position = new Map(items.map((i, n) => [i.id, n]))
  const groups = page.groups
    ?.map((g) => ({ ...g, items: g.items.filter((id) => position.has(id)).sort((a, b) => position.get(a)! - position.get(b)!) }))
    .filter((g) => g.items.length > 0)
    .sort((a, b) => position.get(a.items[0]!)! - position.get(b.items[0]!)!)
  return { page: groups ? { items, groups } : { items }, relist, recount }
}
