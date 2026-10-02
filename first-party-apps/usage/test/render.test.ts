import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"
import { poolsValue, usageValue } from "../preview/fixtures.ts"

const source = readFileSync(join(import.meta.dir, "../dist/main.js"), "utf8")
const ok = (value: unknown) => ({ ok: true, body: { value } })
const fail = (code: string, details: unknown = {}) => ({ ok: false, body: { code, message: code, details, retryable: false } })

/** A host with the app loaded in a fixed language, in-memory storage and the fixture ops. */
function makeHost(settings: Record<string, unknown> = {}, ops: Partial<Record<string, (p: any) => { ok: boolean; body: unknown }>> = {}) {
  const host = new FakeHost("", { app: { id: "cmux/usage", version: "0.1.0" }, apiVersion: "1.0.0" })
  const now = Date.now()
  host.eval(`Intl.DateTimeFormat = function () { return { resolvedOptions: () => ({ locale: "en-US" }) } }; Date.now = () => ${now}`)
  host.eval(source)
  host.global.__cmuxAppInit(JSON.stringify({ app: { id: "cmux/usage", version: "0.1.0" }, apiVersion: "1.0.0", settings }))
  const storage = new Map<string, unknown>()
  host.handlers = {
    "usage.get": () => ok(usageValue(now)),
    "coderouter.usage.get": () => ok(poolsValue(now)),
    "notification.create": (p) => ok({ id: "notification_1", ...p }),
    "app.storage.get": (p) => ok(storage.get(p.key) ?? null),
    "app.storage.set": (p) => (storage.set(p.key, p.value), ok(null)),
    "app.storage.delete": (p) => (storage.delete(p.key), ok(null)),
    ...ops
  } as FakeHost["handlers"]
  return { host, storage }
}

/** Nodes reachable from the root, in order (FakeHost keeps removed subtrees' descendants in its map). */
function nodes(host: FakeHost, mount: string) {
  const { root, nodes: all } = host.tree(mount)
  const out: Array<{ type: string; props: Record<string, unknown> }> = []
  const walk = (id: string) => {
    const n = all.get(id)
    if (!n) return
    out.push(n)
    n.children.forEach(walk)
  }
  walk(root)
  return out
}
const texts = (host: FakeHost, mount: string) => nodes(host, mount).flatMap((n) => [n.props.title, n.props.text, n.props.badge, n.props.subtitle, n.props.message]).filter((v): v is string => typeof v === "string" && v !== "")
const menuTitles = (host: FakeHost, mount: string) => nodes(host, mount).flatMap((n) => (Array.isArray(n.props.menu) ? (n.props.menu as Array<{ title?: string }>).map((m) => m.title ?? "") : []))
const calls = (host: FakeHost, name: string) => host.calls.filter((c) => c.name === name)

async function runCommand(host: FakeHost, name: string, args: unknown = {}) {
  const id = Math.floor(Math.random() * 1e6)
  host.global.__cmuxAppRunCommand(name, JSON.stringify(args), id)
  await host.settle(20)
  return host.commandResults.get(id)!
}

describe("usage app", () => {
  test("menuPercent: the menu bar shows the tightest limit; the dropdown and section list every window", async () => {
    const { host } = makeHost()
    expect(host.mount("s", "renderStatus")).toBe("")
    expect(host.mount("d", "renderSection")).toBe("")
    await host.settle(20)
    expect(texts(host, "s")).toContain("87%")
    expect(menuTitles(host, "s")).toEqual(expect.arrayContaining(["Codex · Work · Plus", "Weekly  87%  resets in 1d 6h · runs out in 20h 37m", "Refresh Now", "Show Usage"]))
    expect(menuTitles(host, "s").some((t) => t.startsWith("5-hour  62%  resets in 2h 10m · runs out in 1h"))).toBe(true)
    const section = texts(host, "d")
    expect(section).toEqual(expect.arrayContaining(["Claude Code · Personal · Max 20x", "Opus weekly", "83%", "$42.50 / $100 · resets in 12d 3h", "CodeRouter · team · Seat B · Pro"]))
    // Both mounts share one read of each source.
    expect(calls(host, "usage.get").length).toBe(1)
    expect(calls(host, "coderouter.usage.get").length).toBe(1)
  })

  test("menuMeters: a glyph of two meters, and cards with a pace tick", async () => {
    const { host } = makeHost({ variant: "menuMeters" })
    host.mount("s", "renderStatus")
    host.mount("d", "renderSection")
    await host.settle(20)
    expect(nodes(host, "s").filter((n) => n.type === "Rectangle").length).toBe(10)
    expect(texts(host, "s")).not.toContain("87%")
    expect(texts(host, "d")).toEqual(expect.arrayContaining(["Claude Code", "Max 20x", "Personal", "62%", "resets in 2h 10m · runs out in 1h 44m"]))
    // The Claude session card meter: 62% used, pace tick at ~57%: fill, tick, fill beyond the pace, track.
    const widths = nodes(host, "d")
      .filter((n) => n.type === "Rectangle")
      .slice(0, 5)
      .map((n) => (n.props.frame as { width: number }).width)
    expect(widths[1]).toBe(0)
    expect(widths[2]).toBe(1)
    expect(widths.reduce((a, b) => a + b, 0)).toBeCloseTo(240, 0)
  })

  test("sidebarOnly: the status item stays empty while calm and warns when a limit is high", async () => {
    const calm = makeHost({ variant: "sidebarOnly" }, { "usage.get": () => ok({ accounts: [] }), "coderouter.usage.get": () => fail("operation.unsupported") })
    calm.host.mount("s", "renderStatus")
    await calm.host.settle(20)
    expect(texts(calm.host, "s")).toEqual([])
    const { host } = makeHost({ variant: "sidebarOnly" })
    host.mount("s", "renderStatus")
    host.mount("d", "renderSection")
    await host.settle(20)
    expect(texts(host, "s")).toEqual(["87%"])
    expect(nodes(host, "d").filter((n) => n.type === "ProgressView").length).toBe(10)
  })

  test("missing service and missing scope show what is missing", async () => {
    const a = makeHost({}, { "usage.get": () => fail("operation.unsupported"), "coderouter.usage.get": () => fail("operation.unsupported") })
    a.host.mount("d", "renderSection")
    a.host.mount("s", "renderStatus")
    await a.host.settle(20)
    expect(texts(a.host, "d")).toEqual(expect.arrayContaining(["Usage service not available", "This build has no usage service (usage.get) yet."]))
    expect(texts(a.host, "s")).toContain("—")
    const b = makeHost({}, { "usage.get": () => fail("scope.missing", { scope: "usage:read" }) })
    b.host.mount("d", "renderSection")
    await b.host.settle(20)
    expect(texts(b.host, "d")).toEqual(expect.arrayContaining(["No permission to read usage", "Allow usage:read in Settings > Apps > Usage."]))
  })

  test("event driven: usage.changed re-reads; no repeating timers; demand reaches the service", async () => {
    const { host } = makeHost()
    host.mount("s", "renderStatus")
    host.mount("d", "renderSection")
    await host.settle(20)
    const demands = [...host.subscriptions.values()].filter((s) => s.stream === "usage.changed").map((s) => s.filter.demand)
    expect(demands.sort()).toEqual(["detail", "glance"])
    host.emit("usage.changed", { revision: "8" })
    await host.settle(20)
    // Two subscriptions fired together; reads coalesce to at most one more.
    expect(calls(host, "usage.get").length).toBeLessThanOrEqual(3)
    expect(calls(host, "usage.get").length).toBeGreaterThan(1)
    expect([...host.timers.values()].every((t) => !t.repeat)).toBe(true)
    expect(host.timers.size).toBeLessThanOrEqual(1)
    host.global.__cmuxAppUnmount("s")
    host.global.__cmuxAppUnmount("d")
    expect([...host.subscriptions.values()].filter((s) => s.stream === "usage.changed")).toEqual([])
  })

  test("warnings: once per window across reads and restarts (deduplicated in storage)", async () => {
    const { host, storage } = makeHost()
    host.mount("s", "renderStatus")
    await host.settle(30)
    const sent = calls(host, "notification.create").map((c) => c.params.title)
    expect(sent.sort()).toEqual(["Claude Code Opus weekly limit at 83%", "Codex Weekly limit at 87%"])
    host.emit("usage.changed", {})
    await host.settle(30)
    expect(calls(host, "notification.create").length).toBe(2)
    // A new VM (app restart) with the same storage sends nothing new.
    const again = makeHost()
    for (const [k, v] of storage) again.storage.set(k, v)
    again.host.mount("s", "renderStatus")
    await again.host.settle(30)
    expect(calls(again.host, "notification.create")).toEqual([])
  })

  test("stale data is marked and never warns", async () => {
    const now = Date.now()
    const { host } = makeHost({}, { "usage.get": () => ok(usageValue(now, { fetchedAgo: 47 * 60_000, stale: true, codexError: true })), "coderouter.usage.get": () => fail("scope.missing") })
    host.mount("d", "renderSection")
    await host.settle(30)
    expect(texts(host, "d")).toEqual(expect.arrayContaining(["Stale · updated 47m ago", "Sign-in expired. Run codex login."]))
    expect(calls(host, "notification.create")).toEqual([])
  })

  test("commands: status JSON for agents, refresh asks the service, cycleVariant falls back to storage", async () => {
    const { host, storage } = makeHost({}, { "usage.refresh": () => ok({ accepted: true }) })
    const status = await runCommand(host, "status", { provider: "codex" })
    expect(status.ok).toBe(true)
    expect(status.body.value.accounts.map((a: { provider: string }) => a.provider)).toEqual(["codex"])
    expect(status.body.value.tightest).toMatchObject({ window: "weekly", used_percent: 87 })
    const refresh = await runCommand(host, "refresh")
    expect(refresh.body.value).toMatchObject({ requested: true, accounts: 5 })
    host.mount("d", "renderSection")
    await host.settle(20)
    expect(nodes(host, "d").some((n) => n.type === "Rectangle")).toBe(false)
    const cycled = await runCommand(host, "cycleVariant")
    expect(cycled.body.value).toEqual({ variant: "menuMeters", persisted: "storage" })
    expect(storage.get("variantOverride")).toEqual({ value: "menuMeters", base: null })
    expect(nodes(host, "d").some((n) => n.type === "Rectangle")).toBe(true)
    const show = await runCommand(host, "show")
    expect(show.body.value).toEqual({ shown: false, reason: "operation.unsupported" })
  })
})
