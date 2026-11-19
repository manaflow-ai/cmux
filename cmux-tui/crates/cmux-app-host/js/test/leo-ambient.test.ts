// examples/extensions/leo-ambient (the Leo collection): the model that folds chat.list, github.changes
// and fleet.hosts into the rings, the checks line and the machine bars.
import { describe, expect, test } from "bun:test"
import { ci, countdown, fleet, providers, tokens, type Change } from "../../../../../examples/extensions/leo-ambient/src/ambient.ts"

const chat = (harness: string, extra: Record<string, unknown> = {}) => ({ harness, state: "idle", usage: null, limits: null, ...extra })
const windows = (session: number, weekly: number, resets = 1_800_000_000) => ({
  windows: [{ id: "session", used_percent: session, resets_at: resets }, { id: "weekly", used_percent: weekly, resets_at: null }],
  plan: "max"
})
const change = (number: number, state: Change["checks"]["state"]): Change => ({
  id: number, number, title: `PR ${number}`, url: `https://github.com/o/r/pull/${number}`, repo: "o/r", draft: false,
  checks: { state, failing: 0, pending: 0, passing: 0 }
})

describe("local/leo-ambient model", () => {
  test("a provider's rings are its fullest chat's windows; spend adds up; unknown stays null", () => {
    const got = providers([
      chat("claude", { state: "working", usage: { tokens_24h: 1000, cost_usd_24h: 1.5 }, limits: windows(40, 70) }),
      chat("claude", { usage: { tokens_24h: 500, cost_usd_24h: null }, limits: windows(55, 60) }),
      chat("codex", { usage: { tokens_24h: 9, cost_usd_24h: 0.25 } }),
      chat("gemini")
    ])
    expect(got.map((p) => p.id)).toEqual(["claude", "codex"])
    const claude = got[0]!
    expect([claude.chats, claude.working, claude.tokens24h, claude.costUsd24h]).toEqual([2, 1, 1500, 1.5])
    expect(claude.session).toEqual({ usedPercent: 55, resetsAtMs: 1_800_000_000_000 })
    expect(claude.weekly).toEqual({ usedPercent: 70, resetsAtMs: null })
    expect(got[1]!.session).toBeNull()
  })

  test("family names the provider before the harness, and percents are clamped", () => {
    const [p] = providers([chat("claude-code", { family: "Claude", limits: windows(140, -3) })])
    expect([p!.id, p!.name, p!.session!.usedPercent, p!.weekly!.usedPercent]).toEqual(["claude", "Claude", 100, 0])
  })

  test("any red is red, then running, then green; the worst come first", () => {
    const s = ci([change(1, "passing"), change(2, "failing"), change(3, "pending"), change(4, "none")])
    expect([s.state, s.failing, s.pending, s.passing, s.total]).toEqual(["failing", 1, 1, 1, 4])
    expect(s.worst.map((c) => c.number)).toEqual([2, 3, 1, 4])
    expect(ci([change(1, "passing"), change(3, "pending")]).state).toBe("pending")
    expect(ci([]).state).toBe("none")
  })

  test("fleet busy is the mean of the machines that answered; offline ones sort last", () => {
    const s = fleet([
      { name: "b", reachable: true, busy: 0.2, liveSessions: 3 },
      { name: "a", reachable: false, busy: 0.9, liveSessions: 9 },
      { name: "c", reachable: true, busy: 1.4, liveSessions: 1 },
      { name: "d", reachable: true, busy: null }
    ])
    expect(s.hosts.map((h) => h.name)).toEqual(["c", "b", "d", "a"])
    expect([s.reachable, s.busy, s.sessions]).toEqual([3, 0.6, 4])
    expect(fleet([]).busy).toBeNull()
  })

  test("numbers read short", () => {
    expect([tokens(null), tokens(950), tokens(12_345), tokens(2_500_000), tokens(3e9)]).toEqual(["–", "950", "12k", "2.5M", "3.0B"])
    expect([countdown(null, 0), countdown(90 * 60_000, 0), countdown(26 * 3_600_000, 0), countdown(5 * 60_000, 0)]).toEqual(["", "1h 30m", "1d 2h", "5m"])
  })
})
