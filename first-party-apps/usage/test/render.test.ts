import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"
import { DEFAULT_RATIOS, historyValue, usageValue } from "../preview/fixtures.ts"

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
    "account.list": () => ok(usageValue(now, { fetchedAgo: 0 })),
    "account.usage": () => ok(historyValue(now, DEFAULT_RATIOS, { fetchedAgo: 0 })),
    "notification.create": (p) => ok({ id: "notification_1", ...p }),
    "app.storage.get": (p) => ok(storage.get(p.key) ?? null),
    "app.storage.set": (p) => (storage.set(p.key, p.value), ok(null)),
    "app.storage.delete": (p) => (storage.delete(p.key), ok(null)),
    ...ops
  } as FakeHost["handlers"]
  return { host, storage, now }
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
/** The id of the tappable node whose subtree shows `text`. */
function tappable(host: FakeHost, mount: string, text: string): string | undefined {
  const { nodes: all } = host.tree(mount)
  const shows = (id: string): boolean => {
    const n = all.get(id)
    return !!n && (n.props.text === text || n.children.some(shows))
  }
  for (const [id, n] of all) if (n.props.onTap === true && shows(id)) return id
  return undefined
}
const calls = (host: FakeHost, name: string) => host.calls.filter((c) => c.name === name)

async function runCommand(host: FakeHost, name: string, args: unknown = {}) {
  const id = Math.floor(Math.random() * 1e6)
  host.global.__cmuxAppRunCommand(name, JSON.stringify(args), id)
  await host.settle(20)
  return host.commandResults.get(id)!
}

async function mountAll(host: FakeHost) {
  expect(host.mount("s", "renderStatus")).toBe("")
  expect(host.mount("d", "renderSection")).toBe("")
  expect(host.mount("p", "renderPane")).toBe("")
  await host.settle(30)
}

describe("usage app", () => {
  test("rows: ratios in the menu bar, provider rows in the section, grouped account rows in the pane", async () => {
    const { host } = makeHost()
    await mountAll(host)
    const status = texts(host, "s")
    expect(status.some((t) => /^Cl ×1\.0\d · Cx ×1\.[34]\d$/.test(t))).toBe(true)
    expect(menuTitles(host, "s").some((t) => t.startsWith("Codex · over pace ×1.4"))).toBe(true)
    expect(menuTitles(host, "s")).toEqual(expect.arrayContaining(["Refresh Now", "Show Usage"]))
    const section = texts(host, "d")
    expect(section).toEqual(expect.arrayContaining(["Claude", "Codex", "Kimi", "4/7", "5/6", "1/1", "no weekly limit"]))
    expect(section.some((t) => t.startsWith("over pace ×1.4"))).toBe(true)
    const pane = texts(host, "p")
    expect(pane).toEqual(expect.arrayContaining(["alder", "ginkgo", "harbor", "key-one", "58%", "on pace", "over pace", "error"]))
    expect(pane.some((t) => t.startsWith("in use · 5h 41% · 2h 10m · wk 58% · 2d 4h · pace ×"))).toBe(true)
    expect(pane.some((t) => t.includes("+$12.50 extra"))).toBe(true)
    expect(pane.some((t) => /^×1\.0\d · [\d.]+%\/h of [\d.]+%\/h · 4 of 7 usable$/.test(t))).toBe(true)
    // Tapping a provider header collapses its accounts.
    expect(nodes(host, "p").filter((n) => n.type === "Row").length).toBe(7 + 6 + 1)
    host.dispatch("p", tappable(host, "p", "Claude")!, "tap")
    await host.settle(10)
    expect(nodes(host, "p").filter((n) => n.type === "Row").length).toBe(6 + 1)
    // Mounts share one read; the history read asks for the baseline only.
    expect(calls(host, "account.list").length).toBe(1)
    expect(calls(host, "account.usage")[0]!.params).toMatchObject({ limit: 1 })
  })

  test("meters: one bar per metered provider in the menu bar, bars per account in the pane", async () => {
    const { host } = makeHost({ variant: "meters" })
    await mountAll(host)
    expect(nodes(host, "s").filter((n) => n.type === "Rectangle").length).toBe(2 * 2)
    expect(texts(host, "s")).toEqual([])
    // Bars only for windows that exist: Claude 6 accounts x 2 (the error account has none), Codex 6 weekly, the keyed provider none.
    expect(nodes(host, "p").filter((n) => n.type === "ProgressView").length).toBe(12 + 6)
    expect(texts(host, "p")).toEqual(expect.arrayContaining(["Claude", "alder", "in use", "41% · 2h 10m", "58% · 2d 4h"]))
    expect(nodes(host, "d").filter((n) => n.type === "ProgressView").length).toBe(2)
  })

  test("quiet: the status item shows only the provider over pace; the pane is a text table", async () => {
    const { host } = makeHost({ variant: "quiet" })
    await mountAll(host)
    const status = texts(host, "s")
    expect(status.length).toBe(1)
    expect(status[0]).toMatch(/^Cx ×1\.[34]\d$/)
    const pane = texts(host, "p")
    expect(pane.some((t) => /^alder\s+in use\s+41% 2h10m\s+58% 2d4h\s+×/.test(t))).toBe(true)
    expect(pane.some((t) => /^Codex {2}over pace ×1\.[34]\d {2}5\/6$/.test(t))).toBe(true)
    // On pace everywhere: the status item is empty.
    const calm = makeHost({ variant: "quiet" }, { "account.usage": () => ok(historyValue(calm.now, { claude: 1, codex: 1 }, { fetchedAgo: 0 })) })
    calm.host.mount("s", "renderStatus")
    await calm.host.settle(30)
    expect(texts(calm.host, "s")).toEqual([])
  })

  test("pending pace, stale reading and a failed source are said in words", async () => {
    const pending = makeHost({}, { "account.usage": () => ok({ snapshots: [] }) })
    await mountAll(pending.host)
    expect(texts(pending.host, "s")).toContain("Cl 4/7 · Cx 5/6")
    expect(texts(pending.host, "d")).toContain("pace in 30m")
    const now = Date.now()
    const stale = makeHost(
      {},
      {
        "account.list": () => ok(usageValue(now, { fetchedAgo: 47 * 60_000, stale: true, error: { code: "router.timeout", message: "The router did not answer within 90 s." } })),
        "account.usage": () => ok({ snapshots: [] })
      }
    )
    await mountAll(stale.host)
    expect(texts(stale.host, "p").some((t) => t.startsWith("The router did not answer within 90 s. · Stale · updated 4"))).toBe(true)
    expect(calls(stale.host, "notification.create")).toEqual([])
  })

  test("missing server and missing scope show what is missing", async () => {
    const a = makeHost({}, { "account.list": () => fail("operation.unsupported") })
    await mountAll(a.host)
    expect(texts(a.host, "p")).toEqual(expect.arrayContaining(["Usage server not available", "This build has no usage server (account.list) yet."]))
    expect(texts(a.host, "s")).toContain("—")
    const b = makeHost({}, { "account.list": () => fail("scope.missing", { scope: "account:read" }) })
    b.host.mount("d", "renderSection")
    await b.host.settle(20)
    expect(texts(b.host, "d")).toEqual(expect.arrayContaining(["No permission to read usage", "Allow account:read in Settings > Apps > Usage."]))
    const c = makeHost({}, { "account.list": () => ok({ providers: {} }) })
    c.host.mount("p", "renderPane")
    await c.host.settle(20)
    expect(texts(c.host, "p")).toContain("No accounts found")
  })

  test("event driven: account.watch re-reads; no repeating timers; subscriptions end with the mount", async () => {
    const { host } = makeHost()
    await mountAll(host)
    const demands = [...host.subscriptions.values()].filter((s) => s.stream === "account.watch").map((s) => s.filter.demand)
    expect(demands.sort()).toEqual(["detail", "detail", "glance"])
    host.emit("account.watch", { revision: "8" })
    await host.settle(30)
    expect(calls(host, "account.list").length).toBeGreaterThan(1)
    expect(calls(host, "account.list").length).toBeLessThanOrEqual(3)
    expect([...host.timers.values()].every((t) => !t.repeat)).toBe(true)
    expect(host.timers.size).toBeLessThanOrEqual(1)
    for (const m of ["s", "d", "p"]) host.global.__cmuxAppUnmount(m)
    expect([...host.subscriptions.values()].filter((s) => s.stream === "account.watch")).toEqual([])
  })

  test("warns once when a provider has no usable account, across restarts", async () => {
    const now = Date.now()
    const out = () => {
      const v = usageValue(now, { only: ["codex"] })
      for (const a of v.providers.codex!.accounts) a.state = "cooked"
      v.providers.codex!.summary = { usable: 0, total: 6, weekly_left_sum_pct: 0 }
      return ok(v)
    }
    const { host, storage } = makeHost({}, { "account.list": out })
    host.mount("s", "renderStatus")
    await host.settle(30)
    expect(calls(host, "notification.create").map((c) => c.params.title)).toEqual(["No usable Codex account"])
    const again = makeHost({}, { "account.list": out })
    for (const [k, v] of storage) again.storage.set(k, v)
    again.host.mount("s", "renderStatus")
    await again.host.settle(30)
    expect(calls(again.host, "notification.create")).toEqual([])
  })

  test("commands: status JSON, refresh, show opens the pane, cycleVariant falls back to storage", async () => {
    const { host, storage } = makeHost({}, { "account.refresh": () => ok({ accepted: true }) })
    const status = await runCommand(host, "status", { provider: "codex" })
    expect(status.ok).toBe(true)
    expect(status.body.value.providers.map((p: { id: string }) => p.id)).toEqual(["codex"])
    expect(status.body.value.providers[0].pace.verdict).toBe("over")
    const refresh = await runCommand(host, "refresh")
    expect(refresh.body.value).toEqual({ requested: true, providers: 3 })
    expect(calls(host, "account.refresh").length).toBe(1)
    host.mount("p", "renderPane")
    await host.settle(20)
    expect(nodes(host, "p").some((n) => n.type === "ProgressView")).toBe(false)
    const cycled = await runCommand(host, "cycleVariant")
    expect(cycled.body.value).toEqual({ variant: "meters", persisted: "storage" })
    expect(storage.get("variantOverride")).toEqual({ value: "meters", base: null })
    expect(nodes(host, "p").some((n) => n.type === "ProgressView")).toBe(true)
    const show = await runCommand(host, "show")
    expect(show.body.value).toEqual({ shown: false, reason: "operation.unsupported" })
  })
})
