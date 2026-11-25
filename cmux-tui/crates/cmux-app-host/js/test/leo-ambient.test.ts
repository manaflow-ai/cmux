// examples/extensions/leo-ambient (the Leo collection): the model that folds chat.list, github.changes
// and fleet.hosts into the rings, the checks line and the machine bars.
import { beforeAll, describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { ci, countdown, fleet, providers, tokens, type Change } from "../../../../../examples/extensions/leo-ambient/src/ambient.ts"
import { pack } from "../../tools/pack.ts"
import { FakeHost } from "./fake-host.ts"

const dir = join(import.meta.dir, "../../../../..", "examples/extensions/leo-ambient")
const manifest = JSON.parse(readFileSync(join(dir, "cmux-app.json"), "utf8"))
let bundle = ""
beforeAll(async () => {
  bundle = await pack(dir)
})

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

describe("local/leo-ambient in the fake host", () => {
  const ok = (value: unknown) => ({ ok: true, body: { value } })
  const rows = (session: number) => [chat("claude", { state: "working", usage: { tokens_24h: 2_500_000, cost_usd_24h: 12.5 }, limits: windows(session, 30) })]
  function host(settings: Record<string, unknown>) {
    const h = new FakeHost(bundle, { app: { id: manifest.id, version: "1.0.0" }, settings, apiVersion: "1.0.0" })
    return h
  }
  /** The nodes reachable from the root (a removed subtree can leave its children in the fake tree). */
  const nodes = (h: FakeHost, m: string) => {
    const { root, nodes: all } = h.tree(m)
    const out: Array<{ id: string; type: string; props: Record<string, unknown>; children: string[] }> = []
    const walk = (id: string) => {
      const n = all.get(id)
      if (!n) return
      out.push({ id, ...n })
      n.children.forEach(walk)
    }
    if (root) walk(root)
    return out
  }
  const arcs = (h: FakeHost, m: string) => nodes(h, m).filter((n) => n.type === "Circle" && n.props.trim)

  test("every surface the manifest names is an export of the bundle", () => {
    for (const impl of Object.values(manifest.implements as Record<string, { export: string }>)) expect(bundle).toContain(`var ${impl.export} = `)
  })

  test("New Tab: two rings per provider that move in place; checks and machines off read nothing", async () => {
    let session = 40
    const h = host({ ci: false, fleet: false })
    h.handlers["chat.list"] = () => ok(rows(session))
    expect(h.mount("m", "renderNewTab", { surface: "newTab" })).toBe("")
    await h.settle(10)
    const before = arcs(h, "m")
    expect(before.map((n) => (n.props.trim as { to: number }).to)).toEqual([0.4, 0.3])
    expect(h.calls.some((c) => c.name === "integration.request" || c.name === "fleet.hosts")).toBe(false)
    expect(h.timers.size).toBe(0)
    session = 90
    h.emit("chat.changed")
    await h.settle(10)
    const after = arcs(h, "m")
    expect(after.map((n) => (n.props.trim as { to: number }).to)).toEqual([0.9, 0.3])
    // The same nodes: the arc animates to its new end instead of being redrawn.
    expect(after.map((n) => n.id)).toEqual(before.map((n) => n.id))
  })

  test("widget: the usage tile draws rings; tapping the title switches to checks", async () => {
    const h = host({})
    h.handlers["chat.list"] = () => ok(rows(65))
    h.handlers["integration.request"] = () => ok({ items: [] })
    const ctx = { surface: "widget", place: "newtab", size: "medium", instance: "w1", settings: {}, refresh: { everySeconds: 60 }, locale: "en", timeZone: "UTC", now: Date.now() }
    expect(h.mount("w", "renderWidget", ctx)).toBe("")
    await h.settle(10)
    expect(arcs(h, "w").length).toBe(2)
    const title = () => nodes(h, "w").find((n) => n.type === "Text" && ["Usage", "Checks", "Machines"].includes(String(n.props.text)))!
    expect(title().props.text).toBe("Usage")
    expect(h.calls.some((c) => c.name === "integration.request")).toBe(false)
    // The title is the symbol and the word in one HStack, which takes the tap.
    const header = nodes(h, "w").find((n) => n.type === "HStack" && n.children.includes(title().id))!
    h.dispatch("w", header.id, "tap")
    await h.settle(10)
    expect(title().props.text).toBe("Checks")
    expect(arcs(h, "w").length).toBe(0)
    expect(h.calls.find((c) => c.name === "app.storage.set")?.params).toMatchObject({ key: "show:w1", value: "ci" })
  })
})
