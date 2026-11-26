// A pane's open arguments and result (cmux.pane/1, runtime 1.5.0): cmux.app.openPane, and the pane
// mount context's args, close, onOpen and onClose. The daemon side is cmux-tui-core apps/pane_flow.rs.
import { describe, expect, test } from "bun:test"
import { FakeHost } from "./fake-host.ts"

const app = `
  globalThis.__cmuxAppExports = {
    renderPane: (ctx) => {
      globalThis.seen = { args: ctx.args }
      ctx.onOpen((args) => { globalThis.opened = args })
      ctx.onClose(() => { globalThis.closed = (globalThis.closed ?? 0) + 1 })
      globalThis.paneCtx = ctx
      return VStack([Text(ctx.args ? "Detail " + ctx.args.id : "Empty")])
    },
    renderSection: (ctx) => {
      globalThis.sectionCtx = ctx
      return VStack([Text("Section")])
    }
  }
`

describe("pane open arguments and result", () => {
  test("openPane waits on app.pane.open and opens the tab with the gesture", async () => {
    const host = new FakeHost(app)
    let answer: (r: { ok: boolean; body: unknown }) => void = () => {}
    host.handlers["app.pane.open"] = () => new Promise((r) => (answer = r))
    host.handlers["action.run"] = () => ({ ok: true, body: { value: null } })
    let done: any
    host.eval(`cmux.app.openPane({ id: "42" }, { gesture: "g1" })`).then((r: unknown) => (done = r))
    await host.settle()
    expect(host.calls.map((c) => c.name)).toEqual(["app.pane.open", "action.run"])
    expect(host.calls[0]!.params).toEqual({ args: { id: "42" } })
    expect(host.calls[1]!.params).toEqual({ id: "app.open", args: { app: "local/test" } })
    expect(host.calls[1]!.options.gesture).toBe("g1")
    expect(done).toBeUndefined()
    answer({ ok: true, body: { value: { result: { picked: "a" }, dismissed: false } } })
    await host.settle()
    expect(done).toEqual({ result: { picked: "a" }, dismissed: false })
  })

  test("a tab that does not open dismisses the open and rejects", async () => {
    const host = new FakeHost(app)
    let answer: (r: { ok: boolean; body: unknown }) => void = () => {}
    host.handlers["app.pane.open"] = () => new Promise((r) => (answer = r))
    host.handlers["action.run"] = () => ({ ok: false, body: { code: "gesture.required", message: "no gesture", retryable: false } })
    host.handlers["app.pane.close"] = (params) => {
      answer({ ok: true, body: { value: { result: null, dismissed: true } } })
      expect(params).toEqual({})
      return { ok: true, body: { value: { closed: true } } }
    }
    let error: any
    host.eval(`cmux.app.openPane({ id: "1" })`).catch((e: unknown) => (error = e))
    await host.settle()
    expect(error?.code).toBe("gesture.required")
    expect(host.calls.map((c) => c.name)).toEqual(["app.pane.open", "action.run", "app.pane.close"])
  })

  test("a pane mount gets args, onOpen runs with them, close answers with its mount", async () => {
    const host = new FakeHost(app)
    host.handlers["app.pane.close"] = () => ({ ok: true, body: { value: { closed: true } } })
    expect(host.global.__cmuxAppMount("7:p1", "renderPane", JSON.stringify({ surface: "pane", args: { id: "42" } }))).toBe("")
    expect(host.eval("seen")).toEqual({ args: { id: "42" } })
    expect(host.eval("opened")).toEqual({ id: "42" })
    host.eval(`paneCtx.close({ picked: "b" })`)
    await host.settle()
    expect(host.calls).toEqual([{ name: "app.pane.close", params: { mount: "7:p1", result: { picked: "b" } }, options: {} }])
    host.global.__cmuxAppUnmount("7:p1")
    expect(host.eval("closed")).toBe(1)
  })

  test("a pane the person opened has null args and runs no onOpen", () => {
    const host = new FakeHost(app)
    expect(host.global.__cmuxAppMount("7:p1", "renderPane", JSON.stringify({ surface: "pane", args: null }))).toBe("")
    expect(host.eval("seen")).toEqual({ args: null })
    expect(host.eval("typeof opened")).toBe("undefined")
    expect(host.eval("typeof paneCtx.close")).toBe("function")
  })

  test("a section's context has no pane members", () => {
    const host = new FakeHost(app)
    expect(host.global.__cmuxAppMount("7:s1", "renderSection", JSON.stringify({ surface: "sidebarSection" }))).toBe("")
    expect(host.eval("typeof sectionCtx.close")).toBe("undefined")
  })
})
