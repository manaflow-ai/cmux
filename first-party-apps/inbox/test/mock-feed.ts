// A small in-memory feed owner for tests and preview fixtures, written from
// the owner's rules (plans/cmux-next/feed.md 3.6, backend reducer): lifecycle,
// triage, the "open requests cannot be archived or snoozed" rule, user-only
// answers. Every committed op returns its event in the wire form
// ({stream, seq, tx, op, params, actor, origin, at}), never a summary.
import type { Counts, FeedEvent, FeedFilter, FeedGroup, FeedItem, ListParams } from "../src/feed.ts"

export const USER = "usr_test"
const PRIORITY: Record<string, number> = { urgent: 0, high: 1, normal: 2, low: 3 }

export class OwnerReject extends Error {
  constructor(
    readonly code: string,
    message: string
  ) {
    super(message)
  }
}

export class MockFeed {
  seq = 0
  readonly answers: Array<{ item: string; answer: unknown }> = []
  constructor(
    public items: FeedItem[],
    public now: () => number = Date.now
  ) {}

  get(id: string) {
    return this.items.find((i) => i.id === id)
  }

  private active = (i: FeedItem) => i.state === "open" && i.archived_at === null
  private openRequest = (i: FeedItem) => i.type === "request" && i.state === "open"
  private matches = (i: FeedItem, f: FeedFilter) =>
    (f.poster_kind === undefined || i.poster.kind === f.poster_kind) && (f.thread === undefined || i.thread === f.thread) && (f.workspace === undefined || i.context.workspace === f.workspace) && (f.kind === undefined || i.kind === f.kind)

  list(p: ListParams): { items: FeedItem[]; groups?: FeedGroup[]; next: string | null; revision: string } {
    const now = this.now()
    const tier = (i: FeedItem) => (this.openRequest(i) ? 0 : this.active(i) && i.read_at === null ? 1 : 2)
    const urgent = (a: FeedItem, b: FeedItem) => tier(a) - tier(b) || (tier(a) === 0 ? PRIORITY[a.priority]! - PRIORITY[b.priority]! || a.order - b.order : b.order - a.order)
    const items = this.items
      .filter((i) => (p.state === undefined || p.state === "all" ? true : p.state === "open" ? i.state === "open" : i.state !== "open"))
      .filter((i) => p.type === undefined || i.type === p.type)
      .filter((i) => this.matches(i, p))
      .filter((i) => p.unread === undefined || (i.read_at === null) === p.unread)
      .filter((i) => p.needs_response === undefined || this.openRequest(i) === p.needs_response)
      .filter((i) => (p.archived === true ? i.archived_at !== null : i.archived_at === null))
      .filter((i) => p.archived === true || i.snoozed_until === null || i.snoozed_until <= now)
      .sort(p.order === "recent" ? (a, b) => b.order - a.order : urgent)
      .slice(0, p.limit ?? 100)
      .map((i) => structuredClone(i))
    const out: { items: FeedItem[]; groups?: FeedGroup[]; next: string | null; revision: string } = { items, next: null, revision: "" }
    if (p.group_by) {
      const groups = new Map<string, FeedGroup>()
      for (const i of items) {
        const key = p.group_by === "thread" ? (i.thread === null ? `item:${i.id}` : `thread:${i.poster.scope}:${i.thread}`) : p.group_by === "poster" ? i.poster.scope : (i.context.workspace ?? "")
        const label = p.group_by === "workspace" ? (i.context.workspace ?? "") : i.poster.label
        const g = groups.get(key) ?? { key, label, items: [] }
        g.items.push(i.id)
        groups.set(key, g)
      }
      out.groups = [...groups.values()]
    }
    return out
  }

  counts(): Counts {
    const now = this.now()
    const c: Counts = { open_requests: 0, unread: 0, by_priority: {}, by_poster_kind: {} }
    for (const i of this.items) {
      if (this.openRequest(i)) {
        c.open_requests++
        c.by_priority[i.priority] = (c.by_priority[i.priority] ?? 0) + 1
      }
      if (this.active(i) && i.read_at === null && (i.snoozed_until === null || i.snoozed_until <= now)) {
        c.unread++
        c.by_poster_kind[i.poster.kind] = (c.by_poster_kind[i.poster.kind] ?? 0) + 1
      }
    }
    return c
  }

  private commit(op: string, params: unknown, changed: FeedItem[], origin = "user"): FeedEvent | null {
    const at = this.now()
    if (changed.length === 0) return null
    for (const i of changed) {
      i.revision++
      i.updated_at = at
    }
    return { stream: `feed:${USER}`, seq: ++this.seq, tx: `tx_${this.seq}`, op, params, actor: { identity: "install_mac", kind: "install" }, origin, at }
  }

  private pick(p: { items?: string[]; all?: boolean; filter?: FeedFilter }) {
    if (p.items) return p.items.map((id) => this.get(id) ?? fail("selector.not_found", `no feed item ${id}`))
    if (p.filter) return this.items.filter((i) => this.matches(i, p.filter!))
    return p.all ? this.items : []
  }

  /** `feed.answer`: the user only (a gesture token = origin user), first answer wins. */
  answer(p: { item: string; answer: unknown }, gesture: unknown): FeedEvent | null {
    const i = this.get(p.item) ?? fail("selector.not_found", "no item")
    if (!gesture) fail("auth.forbidden", "answers come only from a user action (origin user)")
    if (i.type !== "request") fail("validation.invalid", "a notice takes no answer")
    if (i.state !== "open") fail("feed.closed", `the request is already ${i.state}`)
    const at = this.now()
    Object.assign(i, { state: "answered", answer: { value: p.answer, by: "install_mac", device: null, at }, closed_at: at, read_at: i.read_at ?? at })
    this.answers.push({ item: p.item, answer: p.answer })
    return this.commit("feed.answer", p, [i])
  }

  /** `feed.cancel`: the user declines (reason `declined`), or the poster withdraws (`poster`). */
  cancel(p: { item: string; reason?: string }, origin = "user"): FeedEvent | null {
    const i = this.get(p.item) ?? fail("selector.not_found", "no item")
    if (i.state !== "open") fail("feed.closed", `the item is already ${i.state}`)
    const at = this.now()
    Object.assign(i, { state: "cancelled", cancel: { reason: p.reason ?? "poster", by: "install_mac", at, note: null }, closed_at: at })
    return this.commit("feed.cancel", p, [i], origin)
  }

  read(p: { items?: string[]; all?: boolean; filter?: FeedFilter }) {
    const at = this.now()
    const changed = this.pick(p).filter((i) => i.read_at === null)
    for (const i of changed) i.read_at = at
    return this.commit("feed.read", p, changed)
  }

  archive(p: { items?: string[]; filter?: FeedFilter }) {
    const at = this.now()
    let targets = this.pick(p).filter((i) => i.archived_at === null)
    if (p.items) {
      if (targets.some((i) => this.openRequest(i))) fail("validation.invalid", "answer or decline an open request; it cannot be archived")
    } else targets = targets.filter((i) => !this.openRequest(i))
    for (const i of targets) Object.assign(i, { archived_at: at, read_at: i.read_at ?? at, snoozed_until: null })
    return this.commit("feed.archive", p, targets)
  }

  unarchive(p: { items: string[] }) {
    const changed = this.pick(p).filter((i) => i.archived_at !== null)
    for (const i of changed) i.archived_at = null
    return this.commit("feed.unarchive", p, changed)
  }

  snooze(p: { items: string[]; until: number }) {
    const targets = this.pick(p)
    if (targets.some((i) => this.openRequest(i))) fail("validation.invalid", "answer or decline an open request; it cannot be snoozed")
    const changed = targets.filter((i) => i.snoozed_until !== p.until)
    for (const i of changed) i.snoozed_until = p.until
    return this.commit("feed.snooze", p, changed)
  }

  /** A new item from a poster (the event carries the params, not the item). */
  post(item: FeedItem) {
    item.order = Math.max(0, ...this.items.map((i) => i.order)) + 1
    this.items.push(item)
    return this.commit("feed.post", { type: item.type, kind: item.kind, title: item.title }, [item], "script")
  }

  expire(at: number) {
    const due = this.items.filter((i) => i.state === "open" && i.expires_at <= at)
    for (const i of due) Object.assign(i, { state: "expired", closed_at: i.expires_at })
    return this.commit("feed.expire", { at }, due, "script")
  }
}

function fail(code: string, message: string): never {
  throw new OwnerReject(code, message)
}
