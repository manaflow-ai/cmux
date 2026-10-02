import { describe, expect, test } from "bun:test"
import { applyEvent, type Page } from "../src/events.ts"
import type { FeedEvent, FeedItem, ListParams } from "../src/feed.ts"
import { feedItems, fid } from "./fixtures.ts"
import { MockFeed, OwnerReject } from "./mock-feed.ts"

const VIEWS: ListParams[] = [
  { state: "open", order: "urgent", limit: 100 },
  { state: "open", order: "urgent", needs_response: true, limit: 100 },
  { state: "open", order: "urgent", unread: true, group_by: "poster", limit: 100 },
  { state: "open", order: "urgent", poster_kind: "agent", group_by: "workspace", limit: 100 },
  { state: "all", archived: true, order: "recent", limit: 100 }
]

const pageOf = (r: { items: FeedItem[]; groups?: Page["groups"] }): Page => (r.groups ? { items: r.items, groups: r.groups } : { items: r.items })
const ids = (p: Page) => ({ items: p.items.map((i) => `${i.id}@${i.revision}:${i.state}:${i.read_at === null ? "u" : "r"}`), groups: p.groups?.map((g) => [g.key, g.items]) })

/** A tiny seeded generator, so a failure reproduces. */
function rng(seed: number) {
  let s = seed
  return () => ((s = (s * 1103515245 + 12345) % 2147483648) / 2147483648)
}

describe("deriving a page from op events", () => {
  test("after every event, a patched page equals a fresh list (or asks for one)", () => {
    for (let seed = 1; seed <= 40; seed++) {
      const random = rng(seed)
      let now = 1_790_000_000_000
      const owner = new MockFeed(feedItems(now), () => now)
      const pages = VIEWS.map((v) => pageOf(owner.list(v)))
      const pick = () => owner.items[Math.floor(random() * owner.items.length)]!.id
      for (let step = 0; step < 30; step++) {
        now += 60_000
        const r = random()
        let ev: FeedEvent | null = null
        try {
          if (r < 0.15) ev = owner.answer({ item: pick(), answer: { text: "ok" } }, "tap")
          else if (r < 0.25) ev = owner.cancel({ item: pick(), reason: "declined" })
          else if (r < 0.4) ev = owner.read(random() < 0.3 ? { all: true } : { items: [pick()] })
          else if (r < 0.55) ev = owner.archive(random() < 0.3 ? { filter: { poster_kind: "agent" } } : { items: [pick()] })
          else if (r < 0.65) ev = owner.snooze({ items: [pick()], until: now + 3_600_000 })
          else if (r < 0.75) ev = owner.unarchive({ items: [pick()] })
          else if (r < 0.85) ev = owner.expire(now + Math.floor(random() * 48) * 3_600_000)
          else ev = owner.cancel({ item: pick(), reason: "poster" }, "script")
        } catch (e) {
          if (!(e instanceof OwnerReject)) throw e
        }
        if (!ev) continue
        VIEWS.forEach((v, n) => {
          const patch = applyEvent(pages[n]!, ev!, v, now)
          const fresh = pageOf(owner.list(v))
          if (patch.relist) pages[n] = fresh
          else {
            expect([seed, step, ev!.op, n, ids(patch.page)]).toEqual([seed, step, ev!.op, n, ids(fresh)])
            pages[n] = patch.page
          }
        })
      }
    }
  })

  test("a post, an unarchive and snooze wake-ups ask for a list; seen and push decisions change nothing", () => {
    const page: Page = { items: feedItems(0).slice(0, 2) }
    const ev = (op: string, params: unknown = {}): FeedEvent => ({ stream: "feed:u", seq: 1, tx: "t", op, params, actor: { identity: "x" }, origin: "user", at: 1 })
    const view: ListParams = { state: "open" }
    expect(applyEvent(page, ev("feed.post"), view, 0)).toMatchObject({ relist: true, recount: true })
    expect(applyEvent(page, ev("feed.unarchive", { items: [fid("x")] }), view, 0)).toMatchObject({ relist: true })
    expect(applyEvent(page, ev("feed.snooze_wake", { at: 1 }), view, 0)).toMatchObject({ relist: true })
    expect(applyEvent(page, ev("feed.seen", { items: [page.items[0]!.id] }), view, 0)).toMatchObject({ relist: false, recount: false })
    expect(applyEvent(page, ev("feed.push_due", { at: 1, send: [], skip: [] }), view, 0)).toEqual({ page, relist: false, recount: false })
  })
})
