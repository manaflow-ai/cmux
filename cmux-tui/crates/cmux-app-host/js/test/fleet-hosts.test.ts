// cmux.watch("fleet.hosts"): the person's machines and how busy each is, one daemon op
// (cmux-tui-core apps/fleet_hosts.rs, which keeps its answer 30 s for every app). Here: the
// runtime side, one read for every reader, a 60 s poll only while a view reads it, nothing
// once the last reader is gone, and the typed scope error.
import { describe, expect, test } from "bun:test"
import { app, FakeHost } from "./fake-host.ts"

const ok = (value: unknown) => ({ ok: true, body: { value } })
const reads = (host: FakeHost) => host.calls.filter((c) => c.name === "fleet.hosts").length

const machine = (name: string, busy: number | null, extra: Record<string, unknown> = {}) => ({
  name,
  self: false,
  reachable: busy !== null,
  device: busy === null ? null : "linux-server",
  deviceSymbol: busy === null ? null : "server.rack",
  cpus: busy === null ? null : 8,
  load1: busy === null ? null : busy * 8,
  loadLimit: busy === null ? null : 8,
  busy,
  pressure: busy === null ? null : "normal",
  overBudget: busy === null ? null : false,
  liveSessions: busy === null ? null : 1,
  ramFreeFraction: busy === null ? null : 0.5,
  ...extra
})

const widgets = app(`
  const view = () => () => {
    const w = cmux.watch("fleet.hosts")
    globalThis.w = w
    return VStack([
      Text(() => "status=" + w.status()),
      ForEach({ items: () => w.value() ?? [], key: (m) => m.name }, (m) =>
        Row({ title: () => m().name, subtitle: () => (m().busy === null ? "unknown" : Math.round(m().busy * 100) + "%") })),
    ])
  }
  return { one: view(), two: view() }`)

const rows = (host: FakeHost, mount: string) =>
  [...host.tree(mount).nodes.values()].filter((n) => n.type === "Row").map((n) => `${n.props.title} ${n.props.subtitle}`)

describe("cmux.watch(\"fleet.hosts\")", () => {
  test("two widgets share one read and one 60 s timer, and show null as unknown", async () => {
    const host = new FakeHost(widgets)
    host.handlers["fleet.hosts"] = () => ok([machine("mini", 0.25, { self: true }), machine("laptop", null)])
    expect(host.mount("a", "one")).toBe("")
    expect(host.mount("b", "two")).toBe("")
    await host.settle()
    expect(reads(host)).toBe(1)
    expect(host.calls.find((c) => c.name === "fleet.hosts")!.params).toEqual({})
    expect([...host.timers.values()].map((t) => t.ms)).toEqual([60_000])
    expect(rows(host, "b")).toEqual(["mini 25%", "laptop unknown"])
  })

  test("with no reader left there is no timer and no read", async () => {
    const host = new FakeHost(widgets)
    host.handlers["fleet.hosts"] = () => ok([machine("mini", 0.5)])
    host.mount("a", "one")
    host.mount("b", "two")
    await host.settle()
    host.global.__cmuxAppUnmount("a")
    host.global.__cmuxAppUnmount("b")
    expect(host.timers.size).toBe(0)
    expect(host.subscriptions.size).toBe(0)
    await host.settle()
    expect(reads(host)).toBe(1)
  })

  test("a failed re-read keeps the machines shown, status stale", async () => {
    const host = new FakeHost(widgets)
    let up = true
    host.handlers["fleet.hosts"] = () =>
      up ? ok([machine("mini", 0.5)]) : { ok: false, body: { code: "upstream.failed", message: "acpmux did not answer in time", retryable: true } }
    host.mount("a", "one")
    await host.settle()
    up = false
    for (const [id] of [...host.timers]) {
      host.timers.delete(id)
      host.global.__cmuxAppTimer(id)
    }
    await host.settle()
    expect(reads(host)).toBe(2)
    expect(host.eval("w().status")).toBe("stale")
    expect(rows(host, "a")).toEqual(["mini 50%"])
  })

  test("without fleet:read the watch says scope.missing and reads nothing", async () => {
    const host = new FakeHost(widgets, { app: { id: "local/test", version: "1.0.0" }, ops: ["agent.list"] })
    host.mount("a", "one")
    await host.settle()
    expect(host.eval("[w().status, w().error.code, w().error.details.scopes]")).toEqual(["error", "scope.missing", ["fleet:read"]])
    expect(reads(host)).toBe(0)
  })

  test("it takes no params", () => {
    const host = new FakeHost(app(`return {}`))
    expect(host.eval(`(() => { try { cmux.watch("fleet.hosts", { every: 5 }) } catch (e) { return e.code } })()`)).toBe("signal.params")
  })
})
