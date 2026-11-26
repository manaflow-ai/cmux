// A view's kept state (runtime 1.6.0): ctx.keep(name, initial) and ctx.state, written through app.view.state.
// The daemon side, which keeps the value with the mount across a host restart, is cmux-tui-core apps/view_state.rs.
import { describe, expect, test } from "bun:test"
import { FakeHost } from "./fake-host.ts"

const app = `
  globalThis.__cmuxAppExports = {
    renderPane: (ctx) => {
      const [tab, setTab] = ctx.keep("tab", "open")
      const [count, setCount] = ctx.keep("count", 0)
      globalThis.viewCtx = ctx
      globalThis.setTab = setTab
      globalThis.setCount = setCount
      globalThis.again = ctx.keep("tab", "other")[0] === tab
      return VStack([Text(() => tab() + " " + count())])
    }
  }
`

const texts = (host: FakeHost, mountId: string) =>
  [...host.tree(mountId).nodes.values()].filter((n) => n.type === "Text").map((n) => String(n.props.text))

describe("kept view state", () => {
  test("keep starts at its initial value and sends no call until a write", async () => {
    const host = new FakeHost(app)
    expect(host.global.__cmuxAppMount("7:p1", "renderPane", JSON.stringify({ surface: "pane" }))).toBe("")
    await host.settle()
    expect(texts(host, "7:p1")).toEqual(["open 0"])
    expect(host.eval("viewCtx.state")).toEqual({})
    expect(host.eval("again")).toBe(true)
    expect(host.calls).toEqual([])
  })

  test("writes of one turn leave as one app.view.state call with every kept value", async () => {
    const host = new FakeHost(app)
    host.handlers["app.view.state"] = () => ({ ok: true, body: { value: { kept: true } } })
    host.global.__cmuxAppMount("7:p1", "renderPane", JSON.stringify({ surface: "pane" }))
    host.eval(`setTab("closed"); setCount((n) => n + 2)`)
    await host.settle()
    expect(texts(host, "7:p1")).toEqual(["closed 2"])
    expect(host.calls).toEqual([{ name: "app.view.state", params: { mount: "7:p1", state: { tab: "closed", count: 2 } }, options: {} }])
    host.eval(`setCount(2)`)
    await host.settle()
    expect(host.calls.length).toBe(1)
  })

  test("a mount the daemon sends again renders its kept state", async () => {
    const host = new FakeHost(app)
    host.global.__cmuxAppMount("7:p1", "renderPane", JSON.stringify({ surface: "pane", state: { tab: "closed", count: 5 } }))
    await host.settle()
    expect(texts(host, "7:p1")).toEqual(["closed 5"])
    expect(host.eval("viewCtx.state")).toEqual({ tab: "closed", count: 5 })
    host.handlers["app.view.state"] = () => ({ ok: true, body: { value: { kept: true } } })
    host.eval(`setCount(6)`)
    await host.settle()
    expect(host.calls[0]!.params).toEqual({ mount: "7:p1", state: { tab: "closed", count: 6 } })
  })

  test("a refused write is logged, the view keeps its value", async () => {
    const host = new FakeHost(app)
    host.handlers["app.view.state"] = () => ({ ok: false, body: { code: "validation.invalid", message: "state is over 65536 bytes as JSON", retryable: false } })
    host.global.__cmuxAppMount("7:p1", "renderPane", JSON.stringify({ surface: "pane" }))
    host.eval(`setTab("x")`)
    await host.settle()
    expect(texts(host, "7:p1")).toEqual(["x 0"])
  })
})
