import { beforeEach, describe, expect, test } from "bun:test"
import { cleanThresholds, planAlerts, type Fired } from "../src/alerts.ts"
import { durationText, nextTextChange, paceText, resetText, windowLabel } from "../src/format.ts"
import { setLocale } from "../src/l10n.ts"
import { normalizePools, normalizeUsage, percentOf, severityOf, tightest, type UsageAccount } from "../src/model.ts"
import { paceOf } from "../src/pace.ts"
import { statusJSON } from "../src/status.ts"
import { poolsValue, usageValue } from "../preview/fixtures.ts"

const NOW = Date.UTC(2026, 9, 2, 12, 0, 0)
const MIN = 60_000
const HOUR = 60 * MIN

beforeEach(() => setLocale("en-US"))

const window = (over: Partial<UsageAccount["windows"][number]> = {}) => ({
  id: "session",
  kind: "session" as const,
  label: null,
  scope: null,
  usedPercent: 50,
  used: null,
  limit: null,
  unit: null,
  windowSeconds: 5 * 3600,
  resetsAt: NOW + 2 * HOUR,
  ...over
})

const account = (windows = [window()], over: Partial<UsageAccount> = {}): UsageAccount => ({
  id: "a1",
  provider: "claude-code",
  providerTitle: "Claude Code",
  kind: "plan",
  upstream: null,
  label: "Personal",
  plan: "Pro",
  windows,
  source: "oauth",
  fetchedAt: NOW - MIN,
  stale: false,
  error: null,
  ...over
})

describe("normalization", () => {
  test("reads the usage.get shape, string milliseconds included, and orders windows", () => {
    const accounts = normalizeUsage(usageValue(NOW))
    expect(accounts.map((a) => a.provider)).toEqual(["claude-code", "codex", "anthropic-api"])
    const claude = accounts[0]!
    expect(claude.windows.map((w) => w.id)).toEqual(["session", "weekly", "weekly:opus"])
    expect(claude.windows[0]!.resetsAt).toBe(NOW + 2 * HOUR + 10 * MIN)
    expect(claude.fetchedAt).toBe(NOW - 2 * MIN)
    expect(percentOf(accounts[2]!.windows[0]!)).toBeCloseTo(42.5)
  })

  test("drops malformed accounts and tolerates junk", () => {
    expect(normalizeUsage({ accounts: [{ id: "x" }, null, 7, { id: "y", provider: "codex", windows: [{ kind: "bogus", used_percent: "12" }] }] })).toMatchObject([
      { id: "y", windows: [{ kind: "other", usedPercent: 12, id: "other-0" }] }
    ])
    expect(normalizeUsage(null)).toEqual([])
  })

  test("pool accounts get pool-scoped ids and titles", () => {
    const pools = normalizePools(poolsValue(NOW), "pool")
    expect(pools[0]!.label).toBe("team · Seat A")
    expect(pools.map((a) => [a.id, a.kind, a.provider, a.upstream, a.providerTitle])).toEqual([
      ["pool_team/seat_a", "pool", "coderouter", "claude-code", "CodeRouter"],
      ["pool_team/seat_b", "pool", "coderouter", "codex", "CodeRouter"]
    ])
  })

  test("tightest skips failed accounts and breaks ties by the earlier reset", () => {
    const a = account([window({ id: "late", usedPercent: 70, resetsAt: NOW + 5 * HOUR }), window({ id: "soon", usedPercent: 70, resetsAt: NOW + HOUR })])
    const failed = account([window({ usedPercent: 99 })], { id: "a2", error: { code: "auth.expired", message: "", retryable: false } })
    expect(tightest([failed, a])!.window.id).toBe("soon")
    expect(tightest([])).toBeNull()
  })

  test("severity uses the lowest and highest thresholds", () => {
    expect(severityOf(79.9, [80, 95])).toBe("normal")
    expect(severityOf(80, [80, 95])).toBe("warning")
    expect(severityOf(95, [95, 80])).toBe("danger")
    expect(severityOf(null, [80])).toBe("normal")
  })
})

describe("pace", () => {
  test("projects a run-out before the reset from the average rate", () => {
    // 5-hour window, 2h10m left: 170 minutes elapsed at 62% -> 38% more takes ~104 minutes.
    const p = paceOf(window({ usedPercent: 62, resetsAt: NOW + 130 * MIN }), NOW)!
    expect(p.expectedPercent).toBeCloseTo((170 / 300) * 100)
    expect(p.stage).toBe("over")
    expect(p.lastsToReset).toBe(false)
    expect((p.runsOutAt! - NOW) / MIN).toBeCloseTo(104.19, 1)
    expect(paceText(p, NOW)).toBe("runs out in 1h 44m")
  })

  test("lasts to the reset when usage is slow, and stays silent early in a window", () => {
    expect(paceOf(window({ usedPercent: 10, resetsAt: NOW + 2 * HOUR }), NOW)).toMatchObject({ stage: "under", lastsToReset: true, runsOutAt: null })
    // 5 minutes into a 5-hour window (< 5%): no prediction even at 30%.
    expect(paceOf(window({ usedPercent: 30, resetsAt: NOW + 295 * MIN }), NOW)!.runsOutAt).toBeNull()
    expect(paceOf(window({ resetsAt: null }), NOW)).toBeNull()
    expect(paceOf(window({ resetsAt: NOW - 1 }), NOW)).toBeNull()
    expect(paceOf(window({ usedPercent: 100 }), NOW)!.runsOutAt).toBe(NOW)
  })
})

describe("format", () => {
  test("durations and labels in English and Japanese", () => {
    expect([durationText(30_000), durationText(45 * MIN), durationText(2 * HOUR + 10 * MIN), durationText(3 * 24 * HOUR + 4 * HOUR + 59 * MIN)]).toEqual(["<1m", "45m", "2h 10m", "3d 4h"])
    expect(windowLabel(window())).toBe("5-hour")
    expect(windowLabel(window({ kind: "weekly", scope: "Opus" }))).toBe("Opus weekly")
    expect(resetText(window(), NOW)).toBe("resets in 2h 0m")
    setLocale("ja-JP")
    expect(durationText(2 * HOUR + 10 * MIN)).toBe("2時間10分")
    expect(windowLabel(window())).toBe("5時間")
    expect(resetText(window(), NOW)).toBe("2時間0分後にリセット")
  })

  test("the clock fires exactly when a displayed text changes, and not at all without relative text", () => {
    // 2h 10m 30s left -> "2h 10m" until 30 s from now.
    expect(nextTextChange(NOW, { countdownsTo: [NOW + 130 * MIN + 30_000], agesFrom: [], staleAt: [] })).toBe(NOW + 30_000)
    // Over a day left: hour granularity.
    expect(nextTextChange(NOW, { countdownsTo: [NOW + 3 * 24 * HOUR + 20 * MIN], agesFrom: [], staleAt: [] })).toBe(NOW + 20 * MIN)
    // An age of 12m 40s gains a minute in 20 s; a staleness boundary sooner wins.
    expect(nextTextChange(NOW, { countdownsTo: [], agesFrom: [NOW - 12 * MIN - 40_000], staleAt: [NOW + 5_000] })).toBe(NOW + 5_000)
    expect(nextTextChange(NOW, { countdownsTo: [NOW - 1], agesFrom: [], staleAt: [NOW - 1] })).toBeNull()
  })
})

describe("alerts", () => {
  const run = (accounts: UsageAccount[], fired: Fired, now = NOW) => planAlerts(accounts, [80, 95], fired, now, 30 * MIN)

  test("warns once per threshold per window, escalates, and re-arms after the reset", () => {
    let fired: Fired = {}
    const at = (p: number, resetsAt = NOW + HOUR, fetchedAt = NOW - MIN) => [account([window({ usedPercent: p, resetsAt })], { fetchedAt })]
    let r = run(at(70), fired)
    expect(r.alerts).toEqual([])
    r = run(at(81), (fired = r.fired))
    expect(r.alerts.map((a) => [a.level, a.top])).toEqual([[80, false]])
    r = run(at(84), (fired = r.fired))
    expect(r.alerts).toEqual([])
    // The provider moved the reset by a few seconds: still the same window, no repeat.
    r = run(at(85, NOW + HOUR + 3_000), (fired = r.fired))
    expect(r.alerts).toEqual([])
    r = run(at(97), (fired = r.fired))
    expect(r.alerts.map((a) => [a.level, a.top])).toEqual([[95, true]])
    // After the reset time passes, a new window warns again.
    r = run(at(82, NOW + 6 * HOUR, NOW + 2 * HOUR - MIN), (fired = r.fired), NOW + 2 * HOUR)
    expect(r.alerts.map((a) => a.level)).toEqual([80])
  })

  test("jumping past both thresholds sends one warning; falling below re-arms", () => {
    let r = run([account([window({ usedPercent: 96 })])], {})
    expect(r.alerts.map((a) => a.level)).toEqual([95])
    r = run([account([window({ usedPercent: 20 })])], r.fired)
    expect(r.fired).toEqual({})
    r = run([account([window({ usedPercent: 85 })])], r.fired)
    expect(r.alerts.map((a) => a.level)).toEqual([80])
  })

  test("stale and failed accounts never warn and keep their history", () => {
    const fired: Fired = { "a1|session": { level: 80, resetsAt: NOW + HOUR } }
    const stale = run([account([window({ usedPercent: 99 })], { fetchedAt: NOW - 2 * HOUR })], fired)
    expect(stale.alerts).toEqual([])
    expect(stale.fired).toEqual(fired)
    expect(run([account([window({ usedPercent: 99 })], { stale: true })], {}).alerts).toEqual([])
  })

  test("thresholds are cleaned", () => {
    expect(cleanThresholds([95, "80", 80, 0, 101, 2.5])).toEqual([80, 95])
    expect(cleanThresholds(undefined)).toEqual([80, 95])
  })
})

describe("status JSON", () => {
  test("snake_case, filtered by provider, with pace and no secrets", () => {
    const accounts = normalizeUsage(usageValue(NOW))
    const json = statusJSON(accounts, { now: NOW, staleMs: 30 * MIN, thresholds: [80, 95], state: "ready", problem: null, provider: "claude-code" })
    expect(json.accounts.map((a) => a.provider)).toEqual(["claude-code"])
    expect(json.tightest).toMatchObject({ provider: "claude-code", window: "weekly:opus", used_percent: 83 })
    const session = json.accounts[0]!.windows[0]!
    expect(session).toMatchObject({ id: "session", used_percent: 62, resets_in_seconds: 130 * 60, severity: "normal", pace: { lasts_to_reset: false } })
    expect(JSON.stringify(json)).not.toMatch(/token|cookie|@/i)
  })
})
