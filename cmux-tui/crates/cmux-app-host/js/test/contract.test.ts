// Runtime contract v1.1 (plans/cmux-next/app-platform.md section 12, V11).
import { describe, expect, test } from "bun:test"
import { app, FakeHost } from "./fake-host.ts"

describe("error codes", () => {
  test("unknown op is operation.unsupported, known but ungranted is scope.missing", async () => {
    const host = new FakeHost("", { app: { id: "local/t", version: "1.0.0" }, knownOps: ["workspace.list", "tab.close"], ops: ["workspace.list"] })
    host.eval(`cmux.made.up({}).catch((e) => globalThis.a = e.code); cmux.tab.close({}).catch((e) => globalThis.b = e.code)`)
    await host.settle()
    expect([host.eval("a"), host.eval("b")]).toEqual(["operation.unsupported", "scope.missing"])
    expect(host.calls.length).toBe(0)
  })
})

describe("gesture tokens", () => {
  const gestureApp = app(`
    return { render: () => VStack([
      Button("sync", () => cmux.tab.focus({ tab: "tab_1" })),
      Button("async", async () => {
        const g = cmux.gesture()
        await cmux.terminal.get({ terminal: "term_1" })
        await cmux.tab.focus({ tab: "tab_2" })
        await cmux.tab.focus({ tab: "tab_3" }, { gesture: g })
      })
    ]) }`)

  test("calls made synchronously in a user handler carry its gesture", async () => {
    const host = new FakeHost(gestureApp)
    host.handlers["tab.focus"] = () => ({ ok: true, body: { value: null } })
    host.mount("m", "render")
    host.dispatch("m", host.findNode("m", (n) => n.props.title === "sync")!, "tap", { gesture: "g1" })
    await host.settle()
    expect(host.calls.find((c) => c.name === "tab.focus")!.options.gesture).toBe("g1")
  })

  test("after an await only an explicitly passed token carries the gesture", async () => {
    const host = new FakeHost(gestureApp)
    host.handlers["tab.focus"] = () => ({ ok: true, body: { value: null } })
    host.handlers["terminal.get"] = () => ({ ok: true, body: { value: { id: "term_1" } } })
    host.mount("m", "render")
    host.dispatch("m", host.findNode("m", (n) => n.props.title === "async")!, "tap", { gesture: "g2" })
    await host.settle(10)
    const focus = host.calls.filter((c) => c.name === "tab.focus")
    expect(focus.map((c) => [c.params.tab, c.options.gesture ?? null])).toEqual([["tab_2", null], ["tab_3", "g2"]])
  })

  test("outside a handler there is no gesture", () => {
    const host = new FakeHost()
    expect(host.eval("cmux.gesture()")).toBeNull()
  })
})

describe("lifecycle, settings, l10n", () => {
  test("onCleanup runs when the mount goes away", () => {
    const host = new FakeHost(app(`globalThis.cleaned = 0; return { render: () => { onCleanup(() => cleaned++); return Text("x") } }`))
    host.mount("m", "render")
    host.global.__cmuxAppUnmount("m")
    expect(host.eval("cleaned")).toBe(1)
  })

  test("settings.set writes through the host", async () => {
    const host = new FakeHost()
    host.handlers["app.settings.set"] = () => ({ ok: true, body: { value: null } })
    host.eval(`cmux.app.settings.set({ login: "octo" })`)
    await host.settle()
    expect(host.calls[0]).toEqual({ name: "app.settings.set", params: { values: { login: "octo" } }, options: {} })
  })

  test("t() looks up the app's strings for the user's locale", () => {
    const host = new FakeHost("", { app: { id: "local/t", version: "1.0.0" }, locale: "ja", strings: { greeting: "こんにちは {name}", plain: "プレーン" } })
    expect(host.eval(`[cmux.t("greeting", { name: "Ada" }), cmux.t("plain"), cmux.t("missing", "Fallback {n}", { n: 2 }), cmux.app.locale]`)).toEqual(["こんにちは Ada", "プレーン", "Fallback 2", "ja"])
  })
})
