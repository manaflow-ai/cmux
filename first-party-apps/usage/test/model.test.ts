import { beforeEach, describe, expect, test } from "bun:test"
import { planAlerts } from "../src/alerts.ts"
import { durationText, nextTextChange, summaryText, windowText } from "../src/format.ts"
import { setLocale } from "../src/l10n.ts"
import { normalizeHistory, normalizeUsage, snapshotOf, summarize, type Account, type Provider, type Snapshot } from "../src/model.ts"
import { actualPerHour, idealPerHour, pickBaseline, providerPace, verdictOf, weeklyPace, windowPace, WEEK_MS } from "../src/pace.ts"
import { statusJSON } from "../src/status.ts"
import { DEFAULT_RATIOS, historyValue, usageValue } from "../preview/fixtures.ts"

const NOW = Date.UTC(2026, 9, 2, 12, 0, 0)
const MIN = 60_000
const HOUR = 60 * MIN

beforeEach(() => setLocale("en-US"))

const account = (over: Partial<Account> = {}): Account => ({
  id: "a1",
  label: "alpha",
  provider: "claude",
  plan: null,
  state: "ready",
  session: null,
  weekly: { leftPct: 50, resetAt: NOW + 50 * HOUR },
  extraUsd: null,
  source: null,
  ...over
})

const provider = (accounts: Account[], id = "claude"): Provider => ({ id, accounts, summary: summarize(accounts) })

const snap = (at: number, rows: Array<[string, number | null, number | null, Account["state"]?]>): Snapshot => ({
  at,
  accounts: new Map(rows.map(([id, left, reset, state]) => [`claude/${id}`, { provider: "claude", state: state ?? "ready", weeklyLeftPct: left, weeklyResetAt: reset }]))
})

describe("normalization", () => {
  test("reads the router schema: providers, accounts, ISO resets, summary, envelope", () => {
    const u = normalizeUsage(usageValue(NOW, { fetchedAgo: 0 }))
    expect(u.providers.map((p) => p.id)).toEqual(["claude", "codex", "kimi"])
    const claude = u.providers[0]!
    expect(claude.summary).toEqual({ usable: 4, total: 7, weeklyLeftSumPct: 58 + 72 + 34 + 9 })
    const alder = claude.accounts.find((a) => a.label === "alder")!
    expect(alder).toMatchObject({ state: "active", session: { leftPct: 41 }, weekly: { leftPct: 58 }, source: "subrouter" })
    expect(alder.session!.resetAt).toBe(NOW + 2 * HOUR + 10 * MIN)
    expect(claude.accounts.find((a) => a.label === "ginkgo")).toMatchObject({ state: "error", session: null, weekly: null })
    expect(u.fetchedAt).toBe(NOW)
    expect(u.sources.map((s) => s.ok)).toEqual([true, true])
  })

  test("orders accounts in use first, broken last, and earliest weekly reset first within a state", () => {
    const u = normalizeUsage(usageValue(NOW))
    expect(u.providers[0]!.accounts.map((a) => a.state)).toEqual(["active", "rec", "ready", "protected", "temp", "cooked", "error"])
    expect(u.providers[1]!.accounts.filter((a) => a.state === "ready").map((a) => a.label)).toEqual(["keel", "jetty"])
  })

  test("tolerates junk, clamps percents, recomputes a missing summary, maps unknown states", () => {
    const u = normalizeUsage({
      generated_at: "2026-10-02T12:00:00Z",
      providers: {
        codex: { accounts: [null, { label: "no id" }, { id: "x", state: "weird", weekly_left_pct: "140", weekly_reset_at: "nope" }] },
        claude: "garbage"
      }
    })
    expect(u.fetchedAt).toBe(NOW)
    expect(u.providers.map((p) => p.id)).toEqual(["claude", "codex"])
    const x = u.providers[1]!.accounts[0]!
    expect(x).toMatchObject({ id: "x", label: "x", state: "unknown", weekly: { leftPct: 100, resetAt: null } })
    expect(u.providers[1]!.summary).toEqual({ usable: 1, total: 1, weeklyLeftSumPct: 100 })
    expect(normalizeUsage(null).providers).toEqual([])
  })

  test("history snapshots key accounts by provider and id and sort by time", () => {
    const h = normalizeHistory({
      snapshots: [
        { taken_at_ms: String(NOW), accounts: [{ provider: "claude", id: "a", state: "ready", weekly_left_pct: 40 }] },
        { taken_at_ms: NOW - HOUR, accounts: [{ provider: "claude", id: "a", weekly_left_pct: 44, weekly_reset_at: "2026-10-04T00:00:00Z" }, { id: "no provider" }] },
        { accounts: [] }
      ]
    })
    expect(h.map((s) => s.at)).toEqual([NOW - HOUR, NOW])
    expect(h[0]!.accounts.get("claude/a")).toEqual({ provider: "claude", state: "unknown", weeklyLeftPct: 44, weeklyResetAt: Date.UTC(2026, 9, 4) })
    expect(h[0]!.accounts.size).toBe(1)
  })
})

describe("provider pace", () => {
  test("ideal burn sums left / hours to each reset and skips error accounts and passed resets", () => {
    const accounts = [
      account({ id: "a", weekly: { leftPct: 50, resetAt: NOW + 50 * HOUR } }),
      account({ id: "b", weekly: { leftPct: 20, resetAt: NOW + 10 * HOUR } }),
      account({ id: "c", state: "error", weekly: { leftPct: 90, resetAt: NOW + HOUR } }),
      account({ id: "d", weekly: { leftPct: 30, resetAt: NOW - HOUR } }),
      account({ id: "e", weekly: null })
    ]
    expect(idealPerHour(accounts, NOW)).toBeCloseTo(1 + 2)
  })

  test("baseline is the newest snapshot at least 30 minutes old", () => {
    const h = [snap(NOW - 2 * HOUR, []), snap(NOW - 40 * MIN, []), snap(NOW - 10 * MIN, [])]
    expect(pickBaseline(h, NOW)!.at).toBe(NOW - 40 * MIN)
    expect(pickBaseline([snap(NOW - 29 * MIN, [])], NOW)).toBeNull()
  })

  test("actual burn matches accounts by id and leaves out resets, new accounts and errors", () => {
    const reset = NOW + 50 * HOUR
    const before = snap(NOW - HOUR, [
      ["a", 60, reset],
      ["b", 30, reset],
      ["r", 2, NOW - 10 * MIN], // its window reset between the readings
      ["m", 5, NOW + 10 * HOUR] // its reset moved by a week: reset
    ])
    const after = snap(NOW, [
      ["a", 56, reset],
      ["b", 29, reset],
      ["r", 100, NOW + 7 * 24 * HOUR],
      ["m", 100, NOW + 178 * HOUR],
      ["new", 10, reset],
      ["broken", 0, reset, "error"]
    ])
    expect(actualPerHour("claude", before, after)).toBeCloseTo(5)
    expect(actualPerHour("codex", before, after)).toBeNull()
    expect(actualPerHour("claude", after, after)).toBeNull()
  })

  test("verdict bands: under below 0.8, over above 1.2, on pace between (inclusive)", () => {
    expect(verdictOf(0.79)).toBe("under")
    expect(verdictOf(0.8)).toBe("onPace")
    expect(verdictOf(1.2)).toBe("onPace")
    expect(verdictOf(1.21)).toBe("over")
  })

  test("providerPace: counts usable accounts, verdict pending without a baseline, none without headroom", () => {
    const accounts = [
      account({ id: "a", state: "active" }),
      account({ id: "b", state: "cooked", weekly: { leftPct: 0, resetAt: NOW + 10 * HOUR } }),
      account({ id: "c", state: "temp" }),
      account({ id: "d", state: "error" })
    ]
    const p = provider(accounts)
    const current = snap(NOW, [
      ["a", 50, NOW + 50 * HOUR],
      ["c", 50, NOW + 50 * HOUR]
    ])
    const pending = providerPace(p, current, null)
    expect(pending).toMatchObject({ counted: 3, usable: 1, leftSumPct: 100, verdict: "pending", ratio: null, metered: true })
    expect(pending.idealPerHour).toBeCloseTo(2)
    const base = snap(NOW - HOUR, [
      ["a", 52, NOW + 50 * HOUR],
      ["c", 50, NOW + 50 * HOUR]
    ])
    expect(providerPace(p, current, base)).toMatchObject({ verdict: "onPace", ratio: 1, baselineAt: NOW - HOUR })
    const none = providerPace(provider([account({ weekly: { leftPct: 0, resetAt: NOW + HOUR } })]), current, base)
    expect(none.verdict).toBe("none")
    const keyed = providerPace(provider([account({ weekly: null, plan: "API key" })], "kimi"), current, null)
    expect(keyed).toMatchObject({ metered: false, verdict: "none" })
  })

  test("fixtures: Claude on pace, Codex over pace, at the reading time", () => {
    const now = Date.now()
    const u = normalizeUsage(usageValue(now))
    const at = u.fetchedAt!
    const base = pickBaseline(normalizeHistory(historyValue(now, DEFAULT_RATIOS)), at)
    const [claude, codex] = u.providers.map((p) => providerPace(p, snapshotOf(u, at), base))
    expect(claude!.ratio).toBeCloseTo(1, 1)
    expect(claude!.verdict).toBe("onPace")
    expect(codex!.ratio).toBeCloseTo(1.4, 1)
    expect(codex!.verdict).toBe("over")
    expect(summaryText(codex!)).toMatch(/^over pace ×1\.4\d · lower load · [\d.]+%\/h of [\d.]+%\/h · 5 of 6 usable$/)
  })
})

describe("account pace", () => {
  test("used share over elapsed share of the window", () => {
    // 3.5 days of 7 passed, 75% used: 1.5x
    const p = windowPace({ leftPct: 25, resetAt: NOW + 3.5 * 24 * HOUR }, WEEK_MS, NOW)!
    expect(p.ratio).toBeCloseTo(1.5)
    expect(p.verdict).toBe("over")
    expect(p.expectedLeftPct).toBeCloseTo(50)
    expect(weeklyPace(account({ weekly: { leftPct: 70, resetAt: NOW + 3.5 * 24 * HOUR } }), NOW)!.verdict).toBe("under")
  })

  test("no pace early in a window, without a reset, or with a reset outside the window", () => {
    expect(windowPace({ leftPct: 90, resetAt: NOW + WEEK_MS - HOUR }, WEEK_MS, NOW)).toBeNull()
    expect(windowPace({ leftPct: 90, resetAt: null }, WEEK_MS, NOW)).toBeNull()
    expect(windowPace({ leftPct: 90, resetAt: NOW - 1 }, WEEK_MS, NOW)).toBeNull()
    expect(windowPace({ leftPct: 90, resetAt: NOW + WEEK_MS + HOUR }, WEEK_MS, NOW)).toBeNull()
    expect(windowPace(null, WEEK_MS, NOW)).toBeNull()
  })
})

describe("text and clock", () => {
  test("durations and windows", () => {
    expect(durationText(30_000)).toBe("<1m")
    expect(durationText(2 * HOUR + 10 * MIN + 59_000)).toBe("2h 10m")
    expect(durationText(52 * HOUR)).toBe("2d 4h")
    expect(windowText({ leftPct: 58.4, resetAt: NOW + 2 * HOUR }, NOW)).toBe("58% · 2h 0m")
    expect(windowText(null, NOW)).toBeNull()
    setLocale("ja-JP")
    expect(windowText({ leftPct: 58, resetAt: NOW + 2 * HOUR }, NOW)).toBe("58% · 2時間0分")
  })

  test("the next text change is the nearest minute boundary of a countdown", () => {
    expect(nextTextChange(NOW, { countdownsTo: [NOW + 2 * HOUR + 30_000], agesFrom: [], staleAt: [] })).toBe(NOW + 30_000)
    expect(nextTextChange(NOW, { countdownsTo: [], agesFrom: [], staleAt: [] })).toBeNull()
  })
})

describe("alerts and status", () => {
  test("warns once when a provider has no usable account, re-arms when one is usable", () => {
    const out = provider([account({ state: "cooked" }), account({ id: "b", state: "error" })])
    const first = planAlerts([out], {})
    expect(first.alerts).toEqual([{ provider: "claude", total: 2 }])
    expect(planAlerts([out], first.fired).alerts).toEqual([])
    expect(planAlerts([], first.fired).fired).toEqual({ claude: true })
    const back = planAlerts([provider([account()])], first.fired)
    expect(back.fired).toEqual({})
    expect(planAlerts([out], back.fired).alerts.length).toBe(1)
  })

  test("status JSON: provider summaries and pace by default, account rows only on request", () => {
    const now = Date.now()
    const u = normalizeUsage(usageValue(now))
    const base = pickBaseline(normalizeHistory(historyValue(now, DEFAULT_RATIOS)), u.fetchedAt!)
    const paces = u.providers.map((p) => providerPace(p, snapshotOf(u, u.fetchedAt!), base))
    const s = statusJSON(u, paces, { now, staleMs: 30 * MIN, state: "ready", problem: null })
    expect(s.providers.map((p) => p.id)).toEqual(["claude", "codex", "kimi"])
    expect(s.providers[1]!.pace).toMatchObject({ verdict: "over", usable: 5, counted: 6 })
    expect("accounts" in s.providers[0]!).toBe(false)
    const one = statusJSON(u, paces, { now, staleMs: 30 * MIN, state: "ready", problem: null, provider: "codex", accounts: true })
    expect(one.providers.length).toBe(1)
    const keel = (one.providers[0] as { accounts: Array<{ label: string; weekly_left_pct: number; weekly_pace: number | null }> }).accounts.find((a) => a.label === "keel")!
    expect(keel.weekly_left_pct).toBe(27)
    expect(keel.weekly_pace).toBeGreaterThan(0)
  })
})
