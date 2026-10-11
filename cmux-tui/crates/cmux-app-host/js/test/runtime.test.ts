import { describe, expect, test } from "bun:test"
import { app, FakeHost } from "./fake-host.ts"

describe("mount", () => {
  test("initial mount emits create, children and root in one batch", () => {
    const host = new FakeHost(app(`return { render: () => VStack({ spacing: 4 }, [Text("Hello").bold(), Divider()]) }`))
    expect(host.mount("m1", "render")).toBe("")
    const batches = host.batches("m1")
    expect(batches.length).toBe(1)
    const ops = batches[0]!
    expect(ops.filter((o) => o.op === "create").map((o) => o.type)).toEqual(["VStack", "Text", "Divider"])
    expect(ops.find((o) => o.type === "Text")!.props).toEqual({ text: "Hello", weight: "bold" })
    expect(ops.find((o) => o.type === "VStack")!.props).toEqual({ spacing: 4 })
    expect(ops[ops.length - 1]!.op).toBe("root")
  })

  test("a render error is returned and leaves no mount", () => {
    const host = new FakeHost(app(`return { render: () => { throw new Error("boom") } }`))
    expect(host.mount("m1", "render")).toContain("boom")
    expect(host.batches("m1").length).toBe(0)
  })

  test("missing export is an error string", () => {
    const host = new FakeHost(app(`return {}`))
    expect(host.mount("m1", "nope")).toContain("nope")
  })

  test("node budget stops a runaway render", () => {
    const host = new FakeHost(app(`return { render: () => VStack(Array.from({ length: 5000 }, (_, i) => Text(String(i)))) }`))
    expect(host.mount("m1", "render")).toContain("app.limit")
  })
})

describe("bindings", () => {
  test("a signal write emits exactly one update op", async () => {
    const host = new FakeHost(app(`
      const [count, setCount] = signal(0)
      globalThis.bump = () => setCount((c) => c + 1)
      return { render: () => VStack([Text(() => "n=" + count()), Text("static")]) }`))
    host.mount("m1", "render")
    host.global.__cmuxAppFlush()
    host.eval("bump()")
    await host.settle()
    expect(host.lastBatch("m1")).toEqual([{ op: "update", id: expect.any(String), props: { text: "n=1" } }])
  })

  test("no ops when a write does not change the value", async () => {
    const host = new FakeHost(app(`
      const [v, setV] = signal("a")
      globalThis.same = () => setV("a")
      return { render: () => Text(() => v()) }`))
    host.mount("m1", "render")
    const before = host.batches("m1").length
    host.eval("same()")
    await host.settle()
    expect(host.batches("m1").length).toBe(before)
  })

  test("dynamic child function rebuilds its subtree", async () => {
    const host = new FakeHost(app(`
      const [on, setOn] = signal(false)
      globalThis.toggle = () => setOn((x) => !x)
      return { render: () => VStack([() => on() ? Text("on") : Text("off")]) }`))
    host.mount("m1", "render")
    host.eval("toggle()")
    await host.settle()
    const tree = host.tree("m1")
    const texts = [...tree.nodes.values()].filter((n) => n.type === "Text").map((n) => n.props.text)
    expect(texts).toEqual(["on"])
  })
})

describe("lists", () => {
  const listApp = app(`
    const [items, setItems] = signal([{ id: "a", t: "A" }, { id: "b", t: "B" }, { id: "c", t: "C" }])
    globalThis.setItems = setItems
    return { render: () => VStack([ForEach({ items, key: (x) => x.id }, (x) => Text(() => x().t))]) }`)

  test("keyed reorder emits only a children op", async () => {
    const host = new FakeHost(listApp)
    host.mount("m1", "render")
    host.eval(`setItems([{ id: "c", t: "C" }, { id: "a", t: "A" }, { id: "b", t: "B" }])`)
    await host.settle()
    const ops = host.lastBatch("m1")
    expect(ops.map((o) => o.op)).toEqual(["children"])
  })

  test("item change updates in place, removal removes the row", async () => {
    const host = new FakeHost(listApp)
    host.mount("m1", "render")
    host.eval(`setItems([{ id: "a", t: "A2" }, { id: "c", t: "C" }])`)
    await host.settle()
    const ops = host.lastBatch("m1")
    expect(ops.filter((o) => o.op === "create").length).toBe(0)
    expect(ops.filter((o) => o.op === "remove").length).toBe(1)
    expect(ops.some((o) => o.op === "update" && o.props!.text === "A2")).toBe(true)
    const tree = host.tree("m1")
    expect([...tree.nodes.values()].filter((n) => n.type === "Text").map((n) => n.props.text).sort()).toEqual(["A2", "C"])
  })

  test("Reorderable move dispatch calls onMove with the key", () => {
    const host = new FakeHost(app(`
      globalThis.moves = []
      return { render: () => Reorderable({ items: () => [{ id: "x" }, { id: "y" }], key: (i) => i.id, onMove: (id, index, extra) => moves.push([id, index, extra.side]) }, (i) => Text(() => i().id)) }`))
    host.mount("m1", "render")
    const list = host.findNode("m1", (n) => n.type === "Reorderable")!
    expect(host.tree("m1").nodes.get(list)!.props.onMove).toBe(true)
    host.dispatch("m1", list, "move", { id: "y", index: 0, extra: { side: "above" } })
    expect(host.eval("moves")).toEqual([["y", 0, "above"]])
  })
})

describe("events and menus", () => {
  test("tap runs the handler", () => {
    const host = new FakeHost(app(`globalThis.tapped = 0; return { render: () => Button("Go", () => { tapped++ }) }`))
    host.mount("m1", "render")
    const id = host.findNode("m1", (n) => n.type === "Button")!
    expect(host.tree("m1").nodes.get(id)!.props.onTap).toBe(true)
    host.dispatch("m1", id, "tap")
    expect(host.eval("tapped")).toBe(1)
  })

  test("contextMenu dispatch resolves nested index paths", () => {
    const host = new FakeHost(app(`
      globalThis.picked = []
      return { render: () => Text("row").contextMenu([Button("Pin", () => picked.push("pin")), Divider(), Menu("Move", [Button("Top", () => picked.push("top"))])]) }`))
    host.mount("m1", "render")
    const id = host.findNode("m1", (n) => n.type === "Text")!
    const menu = host.tree("m1").nodes.get(id)!.props.menu as any[]
    expect(menu.map((m) => m.title ?? "-")).toEqual(["Pin", "-", "Move"])
    expect(menu[2].children[0].title).toBe("Top")
    host.dispatch("m1", id, "menu", { path: [2, 0] })
    host.dispatch("m1", id, "menu", { path: [0] })
    expect(host.eval("picked")).toEqual(["top", "pin"])
  })

  test("a throwing handler is logged and does not break the runtime", () => {
    const host = new FakeHost(app(`return { render: () => Button("x", () => { throw new Error("bad tap") }) }`))
    host.mount("m1", "render")
    host.dispatch("m1", host.findNode("m1", (n) => n.type === "Button")!, "tap")
    expect(host.logs.some(([l, m]) => l === "error" && m.includes("bad tap"))).toBe(true)
  })
})

describe("cmux global", () => {
  test("ops resolve with value and reject with CmuxError codes", async () => {
    const host = new FakeHost()
    host.handlers["workspace.list"] = () => ({ ok: true, body: { value: [{ id: "ws_1", name: "one" }] } })
    host.handlers["tab.close"] = () => ({ ok: false, body: { code: "scope.missing", message: "no", details: { scope: "workspace:write" }, retryable: false } })
    host.eval(`cmux.workspace.list().then((v) => globalThis.ws = v); cmux.tab.close({ tab: "tab_1" }).catch((e) => globalThis.err = [e.name, e.code, e.details.scope])`)
    await host.settle()
    expect(host.eval("ws")).toEqual([{ id: "ws_1", name: "one" }])
    expect(host.eval("err")).toEqual(["CmuxError", "scope.missing", "workspace:write"])
    expect(host.calls.map((c) => c.name)).toEqual(["workspace.list", "tab.close"])
  })

  test("nested families and actions map to op names", async () => {
    const host = new FakeHost()
    host.eval(`cmux.browser.session.open({}).catch(() => {}); cmux.actions.run("bookmark.addPage", { url: "https://cmux.dev" }).catch(() => {})`)
    await host.settle()
    expect(host.calls.map((c) => [c.name, c.params])).toEqual([["browser.session.open", {}], ["action.run", { id: "bookmark.addPage", args: { url: "https://cmux.dev" } }]])
  })

  test("allowed op list rejects locally with scope.missing", async () => {
    const host = new FakeHost("", { app: { id: "local/t", version: "1.0.0" }, ops: ["workspace.list"] })
    host.eval(`cmux.terminal.input.write({}).catch((e) => globalThis.code = e.code)`)
    await host.settle()
    expect(host.eval("code")).toBe("scope.missing")
    expect(host.calls.length).toBe(0)
  })

  test("live() re-reads on its family's change event and updates bindings", async () => {
    let n = 0
    const host = new FakeHost(app(`return { render: () => { const ws = cmux.live("workspace.list"); return Text(() => String((ws() ?? []).length)) } }`))
    host.handlers["workspace.list"] = () => ({ ok: true, body: { value: Array.from({ length: ++n }, (_, i) => ({ id: "ws_" + i })) } })
    host.mount("m1", "render")
    await host.settle()
    expect([...host.subscriptions.values()].map((s) => s.stream)).toEqual(["workspace.changed"])
    host.emit("workspace.changed")
    await host.settle()
    const text = [...host.tree("m1").nodes.values()].find((x) => x.type === "Text")!.props.text
    expect(text).toBe("2")
  })

  test("unmount releases subscriptions and timers", async () => {
    const host = new FakeHost(app(`return { render: () => { cmux.live("agent.list"); cmux.timer.every(10, () => {}); return Text("x") } }`))
    host.handlers["agent.list"] = () => ({ ok: true, body: { value: [] } })
    host.mount("m1", "render")
    expect(host.subscriptions.size).toBe(1)
    expect([...host.timers.values()]).toEqual([{ ms: 1000, repeat: true }])
    host.global.__cmuxAppUnmount("m1")
    expect(host.subscriptions.size).toBe(0)
    expect(host.timers.size).toBe(0)
  })

  test("settings signal updates bindings", async () => {
    const host = new FakeHost(app(`return { render: () => Text(() => cmux.app.settings().label ?? "none") }`))
    host.mount("m1", "render")
    host.global.__cmuxAppSetSettings(JSON.stringify({ label: "hi" }))
    const text = [...host.tree("m1").nodes.values()].find((x) => x.type === "Text")!.props.text
    expect(text).toBe("hi")
  })

  test("commands report completion through commandDone", async () => {
    const host = new FakeHost(app(`return { refresh: async (args) => ({ got: args.n }) , fail: () => { throw new CmuxError("x.bad", "nope") } }`))
    host.global.__cmuxAppRunCommand("refresh", JSON.stringify({ n: 3 }), 7)
    host.global.__cmuxAppRunCommand("fail", "{}", 8)
    await host.settle()
    expect(host.commandResults.get(7)).toEqual({ ok: true, body: { value: { got: 3 } } })
    expect(host.commandResults.get(8)).toEqual({ ok: false, body: { code: "x.bad", message: "nope", details: null } })
  })

  test("net.fetch returns a response with json()", async () => {
    const host = new FakeHost()
    host.handlers["net.fetch"] = (p) => ({ ok: true, body: { value: { status: 200, headers: {}, body: JSON.stringify({ url: p.url }) } } })
    host.eval(`cmux.net.fetch("https://api.github.com/x").then((r) => globalThis.out = [r.ok, r.json().url])`)
    await host.settle()
    expect(host.eval("out")).toEqual([true, "https://api.github.com/x"])
  })
})

describe("compat with old sidebars", () => {
  test("sidebar(fn) + data.workspaces() + cmux(method, params)", async () => {
    const host = new FakeHost(`sidebar(() => VStack([ForEach({ items: () => data.workspaces() ?? [], key: (w) => w.id }, (w) => Text(() => w().name).onTap(() => cmux("workspace.select", { workspace_id: w().id })))]))`)
    host.handlers["workspace.list"] = () => ({ ok: true, body: { value: [{ id: "ws_1", name: "alpha" }] } })
    host.handlers["workspace.focus"] = () => ({ ok: true, body: { value: null } })
    expect(host.mount("m1", "sidebar")).toBe("")
    await host.settle()
    const id = host.findNode("m1", (n) => n.type === "Text" && n.props.text === "alpha")!
    host.dispatch("m1", id, "tap")
    await host.settle()
    expect(host.calls.find((c) => c.name === "workspace.focus")!.params).toEqual({ workspace_id: "ws_1" })
  })
})

describe("node budget accounting", () => {
  test("rebuilding a subtree many times never hits the node limit", async () => {
    const host = new FakeHost(app(`
      const [on, setOn] = signal(false)
      globalThis.toggle = () => setOn((x) => !x)
      return { render: () => VStack([() => on() ? VStack([Text("a"), Text("b"), Text("c")]) : HStack([Text("d"), Text("e")])]) }`))
    expect(host.mount("m1", "render")).toBe("")
    for (let i = 0; i < 3000; i++) {
      host.eval("toggle()")
      await host.settle(1)
    }
    expect(host.logs.filter(([l]) => l === "error")).toEqual([])
  })

  test("removing list rows releases their whole subtree", async () => {
    const host = new FakeHost(app(`
      const [items, setItems] = signal([])
      globalThis.setItems = setItems
      return { render: () => VStack([ForEach({ items, key: (x) => x }, (x) => HStack([Text(() => String(x())), Text("·"), Text("row")]))]) }`))
    host.mount("m1", "render")
    for (let round = 0; round < 40; round++) {
      host.eval(`setItems(Array.from({ length: 100 }, (_, i) => ${round} * 1000 + i))`)
      await host.settle(1)
    }
    expect(host.logs.filter(([l]) => l === "error")).toEqual([])
  })
})
