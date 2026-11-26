// cmux.watch on a host with the daemon's signals cache (`__cmuxAppNative.watch`): op sources join
// the daemon's entry once per mount and mirror its states; the runtime reads and polls nothing.
import { describe, expect, test } from "bun:test"
import { app, FakeHost } from "./fake-host.ts"

const init = { app: { id: "local/test", version: "1.0.0" }, apiVersion: "1.0.0" }
const daemonHost = (source: string) => new FakeHost(source, init, { daemonWatch: true })

const views = app(`
  const view = () => {
    const w = cmux.watch("agent.list", {})
    globalThis.w = w
    return Text(() => "n=" + (w.value() ?? []).length + " " + w.status())
  }
  return { one: view, two: view }`)

const text = (host: FakeHost, mount: string) => {
  const { nodes } = host.tree(mount)
  return [...nodes.values()].map((n) => n.props.text).filter(Boolean).join(" ")
}

describe("cmux.watch through the daemon's signals cache", () => {
  test("one watch per mount, no reads, no timers, no subscriptions in the runtime", async () => {
    const host = daemonHost(views)
    expect(host.mount("m1", "one")).toBe("")
    expect(host.mount("m2", "two")).toBe("")
    await host.settle()
    expect([...host.watches.values()].map((w) => w.mount).sort()).toEqual(["m1", "m2"])
    expect(host.calls.filter((c) => c.name === "agent.list").length).toBe(0)
    expect(host.timers.size).toBe(0)
    expect(host.subscriptions.size).toBe(0)
    host.watchState("agent.list", { value: [{ id: 1 }, { id: 2 }], status: "fresh", updatedAt: 5 })
    await host.settle()
    expect(text(host, "m1")).toContain("n=2 fresh")
    expect(text(host, "m2")).toContain("n=2 fresh")
    expect(host.global.w.updatedAt.peek()).toBe(5)
  })

  test("errors arrive typed, and the old value stays while stale", async () => {
    const host = daemonHost(views)
    host.mount("m1", "one")
    host.watchState("agent.list", { value: [{ id: 1 }], status: "fresh", updatedAt: 1 })
    host.watchState("agent.list", { value: [{ id: 1 }], status: "stale", updatedAt: 1, error: { code: "operation.failed", message: "down" } })
    await host.settle()
    expect(host.global.w.status.peek()).toBe("stale")
    expect(host.global.w.error.peek().code).toBe("operation.failed")
    expect(host.global.w.value.peek()).toEqual([{ id: 1 }])
  })

  test("refresh asks the daemon and resolves on its answer", async () => {
    const host = daemonHost(views)
    host.mount("m1", "one")
    let done = false
    host.global.w.refresh().then(() => (done = true))
    expect(host.watchRefreshes.length).toBe(1)
    host.watchState("agent.list", { value: [], status: "stale", updatedAt: 1 })
    await host.settle()
    expect(done).toBe(false)
    host.watchState("agent.list", { value: [{ id: 3 }], status: "fresh", updatedAt: 2 })
    await host.settle()
    expect(done).toBe(true)
  })

  test("unmounting the last reader of a mount leaves the daemon's entry", async () => {
    const host = daemonHost(views)
    host.mount("m1", "one")
    host.mount("m2", "two")
    host.global.__cmuxAppUnmount("m1")
    await host.settle()
    expect([...host.watches.values()].map((w) => w.mount)).toEqual(["m2"])
    host.global.__cmuxAppUnmount("m2")
    await host.settle()
    expect(host.watches.size).toBe(0)
  })

  test("a fallback answer makes the runtime read the source itself", async () => {
    const host = daemonHost(views)
    host.handlers["agent.list"] = () => ({ ok: true, body: { value: [{ id: 9 }] } })
    host.mount("m1", "one")
    host.watchState("agent.list", { fallback: true })
    await host.settle()
    expect(host.watches.size).toBe(0)
    expect(host.calls.filter((c) => c.name === "agent.list").length).toBe(1)
    expect(host.global.w.value.peek()).toEqual([{ id: 9 }])
  })

  test("reader sources stay in the runtime", async () => {
    const host = daemonHost(app(`return { render: () => { const w = cmux.watch("http.json", { url: "https://example.com/a.json" }); return Text(() => w.status()) } }`))
    host.handlers["net.fetch"] = () => ({ ok: true, body: { value: { status: 200, headers: {}, body: "{}" } } })
    host.mount("m1", "render")
    await host.settle()
    expect(host.watches.size).toBe(0)
    expect(host.calls.filter((c) => c.name === "net.fetch").length).toBe(1)
  })
})
