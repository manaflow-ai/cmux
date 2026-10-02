import { describe, expect, test } from "bun:test"
import { emptyLedger, isDone, isSeen, markDone, markSeen, MAX_ENTRIES, nextWake, parseLedger, prune, snooze, snoozedUntil, unsnooze, wake } from "../src/ledger.ts"

const NOW = 1_800_000_000_000

describe("ledger", () => {
  test("seen and done compare stamps, so later changes come back", () => {
    let l = markSeen(emptyLedger(), [{ id: "a", at: 10 }])
    expect(isSeen(l, "a", 10)).toBe(true)
    expect(isSeen(l, "a", 11)).toBe(false)
    l = markDone(l, [{ id: "b", at: 5 }])
    expect(isDone(l, "b", 5)).toBe(true)
    expect(isSeen(l, "b", 5)).toBe(true)
    expect(isDone(l, "b", 6)).toBe(false)
    // Stamps never move backwards.
    expect(markSeen(l, [{ id: "a", at: 3 }]).seen.a).toBe(10)
  })

  test("snooze, wake and the next wake time", () => {
    let l = snooze(markSeen(emptyLedger(), [{ id: "a", at: 1 }]), ["a", "b"], NOW + 60_000)
    l = snooze(l, ["c"], NOW + 10_000)
    expect(snoozedUntil(l, "a", NOW)).toBe(NOW + 60_000)
    expect(nextWake(l, NOW)).toBe(NOW + 10_000)
    const early = wake(l, NOW + 10_000)
    expect(early.woke).toEqual(["c"])
    const late = wake(early.ledger, NOW + 60_000)
    expect(late.woke.sort()).toEqual(["a", "b"])
    // Woken items read as unread again.
    expect(isSeen(late.ledger, "a", 1)).toBe(false)
    expect(nextWake(late.ledger, NOW + 60_000)).toBeNull()
    expect(unsnooze(l, ["a"]).snooze.a).toBeUndefined()
  })

  test("done clears a snooze", () => {
    const l = markDone(snooze(emptyLedger(), ["a"], NOW + 1), [{ id: "a", at: 1 }])
    expect(l.snooze).toEqual({})
  })

  test("parse drops malformed entries", () => {
    expect(parseLedger({ seen: { a: 1, b: "x", c: null }, done: [], snooze: { d: Infinity }, githubSeeded: "yes" })).toEqual({ v: 1, seen: { a: 1 }, done: {}, snooze: {}, githubSeeded: false })
    expect(parseLedger(null)).toEqual(emptyLedger())
  })

  test("prune keeps live and recent ids and caps each map", () => {
    const seen: Record<string, number> = { live: 1, recent: NOW - 1000, old: NOW - 40 * 86_400_000 }
    const pruned = prune({ ...emptyLedger(), seen }, new Set(["live"]), NOW)
    expect(Object.keys(pruned.seen).sort()).toEqual(["live", "recent"])
    const many: Record<string, number> = {}
    for (let i = 0; i < MAX_ENTRIES + 10; i++) many[`id${i}`] = NOW - i
    expect(Object.keys(prune({ ...emptyLedger(), done: many }, new Set(), NOW).done)).toHaveLength(MAX_ENTRIES)
  })
})
