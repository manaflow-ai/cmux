// A tiny in-memory feed owner for tests and preview fixtures. It stands in
// for the real owner (filtering, ordering, grouping, counts, seen/done/snooze
// state); the app under test keeps none of that.
import type { FeedCounts, FeedFilter, FeedGroup, FeedItem, FeedListParams, FeedListResult, FeedMutation } from "../src/feed.ts"

const URGENCY = { critical: 0, high: 1, normal: 2, low: 3 }
const SOURCE_ORDER = ["agent", "integration", "run", "app", "user"]

export class MockFeed {
  revision = 1
  readonly responses: Array<{ item: string; value: unknown }> = []
  constructor(
    public items: FeedItem[],
    private now: () => number = Date.now
  ) {}

  private bump(ids: string[]): FeedMutation & { changedIds: string[] } {
    this.revision++
    const rev = String(this.revision)
    for (const i of this.items) if (ids.includes(i.id)) i.revision = rev
    return { revision: rev, changed: ids.length, changedIds: ids }
  }

  /** Snoozes past their time are open again (the owner fires wake-ups). */
  private wake() {
    for (const i of this.items) {
      if (i.status === "snoozed" && i.snoozedUntil && Date.parse(i.snoozedUntil) <= this.now()) {
        i.status = "open"
        i.snoozedUntil = null
        i.seenAt = null
      }
    }
  }

  private matches(i: FeedItem, f: FeedFilter) {
    return (
      (!f.status || f.status.includes(i.status)) &&
      (!f.kinds || f.kinds.includes(i.kind)) &&
      (!f.sources || f.sources.includes(i.source.kind)) &&
      (!f.workspace || i.subject.workspace === f.workspace) &&
      (f.needsResponse === undefined || i.needsResponse === f.needsResponse) &&
      (!f.unseen || i.seenAt === null) &&
      (!f.query || i.title.toLowerCase().includes(f.query.toLowerCase()))
    )
  }

  counts(): FeedCounts {
    this.wake()
    const open = this.items.filter((i) => i.status === "open")
    return {
      unseen: open.filter((i) => i.seenAt === null).length,
      open: open.length,
      needsResponse: open.filter((i) => i.needsResponse).length,
      urgent: open.filter((i) => i.urgency === "high" || i.urgency === "critical").length,
      snoozed: this.items.filter((i) => i.status === "snoozed").length
    }
  }

  list(p: FeedListParams): FeedListResult {
    this.wake()
    const items = this.items
      .filter((i) => this.matches(i, p.filter ?? {}))
      .sort((a, b) => Number(b.needsResponse) - Number(a.needsResponse) || URGENCY[a.urgency] - URGENCY[b.urgency] || Date.parse(b.updatedAt) - Date.parse(a.updatedAt))
      .slice(0, p.limit ?? 100)
    return { items, groups: p.groupBy ? this.group(items, p.groupBy) : undefined, cursor: null, revision: String(this.revision), counts: this.counts() }
  }

  private group(items: FeedItem[], by: "source" | "workspace" | "thread"): FeedGroup[] {
    const groups = new Map<string, FeedGroup>()
    for (const i of items) {
      const [key, label, sourceKind] =
        by === "source"
          ? i.source.kind === "integration"
            ? [`integration:${i.source.id}`, i.source.name, i.source.kind]
            : [i.source.kind, i.source.kind, i.source.kind]
          : by === "workspace"
            ? [i.subject.workspace ?? "none", i.subject.workspaceName ?? "Other", undefined]
            : [i.thread ?? i.id, i.thread ? i.title : i.title, undefined]
      let g = groups.get(key)
      if (!g) groups.set(key, (g = { key, label, ...(sourceKind ? { sourceKind: sourceKind as FeedGroup["sourceKind"] } : {}), itemIds: [] }))
      g.itemIds.push(i.id)
    }
    const list = [...groups.values()]
    if (by === "source") list.sort((a, b) => SOURCE_ORDER.indexOf(a.sourceKind ?? "") - SOURCE_ORDER.indexOf(b.sourceKind ?? ""))
    return list
  }

  get(id: string): FeedItem | undefined {
    return this.items.find((i) => i.id === id)
  }

  mark(p: { items?: string[]; filter?: FeedFilter; state: "seen" | "done" | "open" }) {
    const targets = p.items ? this.items.filter((i) => p.items!.includes(i.id)) : this.items.filter((i) => this.matches(i, p.filter ?? {}))
    const at = new Date(this.now()).toISOString()
    for (const i of targets) {
      if (p.state === "seen") i.seenAt ??= at
      if (p.state === "done") i.status = "done"
      if (p.state === "open") {
        i.status = "open"
        i.snoozedUntil = null
      }
    }
    return this.bump(targets.map((i) => i.id))
  }

  snooze(p: { item: string; until: string }) {
    const i = this.get(p.item)
    if (i) {
      i.status = "snoozed"
      i.snoozedUntil = p.until
    }
    return this.bump(i ? [i.id] : [])
  }

  respond(p: { item: string; value: unknown }) {
    const i = this.get(p.item)
    this.responses.push({ item: p.item, value: p.value })
    if (i) {
      i.status = "done"
      i.needsResponse = false
    }
    return this.bump(i ? [i.id] : [])
  }
}
