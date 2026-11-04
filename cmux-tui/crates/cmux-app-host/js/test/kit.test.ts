// The kit a vibe-coded pane matches the app with: Toggle, Slider, Panel,
// the tone names in `cmux.theme`, and `cmux.toast`.
import { readFileSync } from "node:fs"
import { describe, expect, test } from "bun:test"
import { app, FakeHost } from "./fake-host.ts"

describe("Toggle", () => {
  test("is a two-way bound switch: the value is a prop, a change runs onChange with the new value", async () => {
    const host = new FakeHost(app(`
      const [on, setOn] = signal(false)
      globalThis.seen = []
      globalThis.flip = () => setOn(true)
      return { render: () => Toggle(on, { label: "Focus sounds", onChange: (v) => { seen.push(v); setOn(v) } }) }`))
    host.mount("m1", "render")
    const id = host.findNode("m1", (n) => n.type === "Toggle")!
    expect(host.tree("m1").nodes.get(id)!.props).toEqual({ value: false, label: "Focus sounds", onChange: true })
    host.dispatch("m1", id, "change", { value: true })
    expect(host.eval("seen")).toEqual([true])
    host.eval("flip()")
    await host.settle()
    expect(host.tree("m1").nodes.get(id)!.props.value).toBe(true)
  })

  test("a non-boolean payload is read as a boolean", () => {
    const host = new FakeHost(app(`globalThis.seen = []; return { render: () => Toggle(true, { onChange: (v) => seen.push(v) }) }`))
    host.mount("m1", "render")
    host.dispatch("m1", host.findNode("m1", (n) => n.type === "Toggle")!, "change", { value: 0 })
    expect(host.eval("seen")).toEqual([false])
  })

  test("a payload that is not a boolean or a number is dropped, not read as true", () => {
    const host = new FakeHost(app(`globalThis.seen = []; return { render: () => Toggle(true, { onChange: (v) => seen.push(v) }) }`))
    host.mount("m1", "render")
    const id = host.findNode("m1", (n) => n.type === "Toggle")!
    host.dispatch("m1", id, "change", { value: "false" })
    host.dispatch("m1", id, "change", {})
    expect(host.eval("seen")).toEqual([])
  })
})

describe("Slider", () => {
  test("carries min, max and step, and onChange gets the number", () => {
    const host = new FakeHost(app(`
      globalThis.seen = []
      return { render: () => Slider(25, { min: 5, max: 60, step: 5, onChange: (v) => seen.push(v) }) }`))
    host.mount("m1", "render")
    const id = host.findNode("m1", (n) => n.type === "Slider")!
    expect(host.tree("m1").nodes.get(id)!.props).toEqual({ value: 25, min: 5, max: 60, step: 5, onChange: true })
    host.dispatch("m1", id, "change", { value: "30" })
    expect(host.eval("seen")).toEqual([30])
  })

  test("a value that is not a finite number never reaches onChange", () => {
    const host = new FakeHost(app(`globalThis.seen = []; return { render: () => Slider(25, { min: 5, max: 60, onChange: (v) => seen.push(v) }) }`))
    host.mount("m1", "render")
    const id = host.findNode("m1", (n) => n.type === "Slider")!
    for (const payload of [{}, { value: "abc" }, { value: true }, { value: null }]) host.dispatch("m1", id, "change", payload)
    expect(host.eval("seen")).toEqual([])
  })

  test("defaults to 0...1", () => {
    const host = new FakeHost(app(`return { render: () => Slider(0.5) }`))
    host.mount("m1", "render")
    const id = host.findNode("m1", (n) => n.type === "Slider")!
    expect(host.tree("m1").nodes.get(id)!.props).toEqual({ value: 0.5, min: 0, max: 1 })
  })
})

describe("Panel", () => {
  test("is a container with a style and an optional title", () => {
    const host = new FakeHost(app(`return { render: () => Panel({ title: "Timer", style: "card" }, [Text("a"), Text("b")]) }`))
    host.mount("m1", "render")
    const id = host.findNode("m1", (n) => n.type === "Panel")!
    const node = host.tree("m1").nodes.get(id)!
    expect(node.props).toEqual({ title: "Timer", style: "card" })
    expect(node.children.length).toBe(2)
  })

  test("takes children alone and defaults to glass", () => {
    const host = new FakeHost(app(`return { render: () => Panel([Text("a")]) }`))
    host.mount("m1", "render")
    const node = host.tree("m1").nodes.get(host.findNode("m1", (n) => n.type === "Panel")!)!
    expect(node.props).toEqual({ style: "glass" })
  })
})

describe("cmux.theme", () => {
  test("names the tones props accept, read-only", () => {
    const host = new FakeHost(app(`return {}`))
    expect(host.eval("cmux.theme.accent")).toBe("accent")
    expect(host.eval("[cmux.theme.text.primary, cmux.theme.text.secondary, cmux.theme.text.tertiary]")).toEqual(["primary", "secondary", "tertiary"])
    expect(host.eval("[cmux.theme.success, cmux.theme.warning, cmux.theme.danger, cmux.theme.separator]")).toEqual(["success", "warning", "danger", "separator"])
    expect(host.eval(`(() => { "use strict"; try { cmux.theme.accent = "#ff0000"; return "wrote" } catch { return "refused" } })()`)).toBe("refused")
    expect(host.eval("cmux.theme.accent")).toBe("accent")
  })
})

describe("cmux.toast", () => {
  test("calls the host's toast.show with title, message and tone", async () => {
    const host = new FakeHost(app(`return {}`))
    host.handlers["toast.show"] = () => ({ ok: true, body: { value: null } })
    host.eval(`cmux.toast({ title: "Focus started", message: "25 minutes", tone: "success" })`)
    await host.settle()
    expect(host.calls.at(-1)).toMatchObject({ name: "toast.show", params: { title: "Focus started", message: "25 minutes", tone: "success" } })
  })

  test("a string is the title", async () => {
    const host = new FakeHost(app(`return {}`))
    host.handlers["toast.show"] = () => ({ ok: true, body: { value: null } })
    host.eval(`cmux.toast("Saved")`)
    await host.settle()
    expect(host.calls.at(-1)).toMatchObject({ name: "toast.show", params: { title: "Saved" } })
  })

  test("is a host op: an app whose grant list omits it still reaches the host", async () => {
    const host = new FakeHost(app(`return {}`), { app: { id: "local/customize", version: "1.0.0" }, apiVersion: "1.0.0", ops: ["workspace.list"], knownOps: ["workspace.list"] })
    host.handlers["toast.show"] = () => ({ ok: true, body: { value: null } })
    host.eval(`globalThis.result = cmux.toast("Hi").then(() => "ok", (e) => e.code)`)
    await host.settle()
    expect(await host.eval("result")).toBe("ok")
  })
})

describe("the documented focus timer template", () => {
  // skills/cmux-customization/references/local-app-views.md, "Focus timer script", as written.
  const doc = readFileSync(new URL("../../../../../skills/cmux-customization/references/local-app-views.md", import.meta.url), "utf8")
  const after = doc.slice(doc.indexOf("#### Focus timer script"))
  const script = after.slice(after.indexOf("```js\n") + 6, after.indexOf("```", after.indexOf("```js\n") + 6))

  test("renders from the kit alone, and Start toasts and swaps the slider for progress", async () => {
    const host = new FakeHost(script)
    host.handlers["toast.show"] = () => ({ ok: true, body: { value: null } })
    expect(host.mount("m1", "renderFocus")).toBe("")
    const types = new Set([...host.tree("m1").nodes.values()].map((n) => n.type))
    for (const type of ["Panel", "Slider", "Toggle", "Button", "Menu", "Row"]) expect(types.has(type)).toBe(true)
    const literal = [...host.tree("m1").nodes.values()].flatMap((n) => Object.values(n.props)).filter((v) => typeof v === "string" && /^#[0-9a-f]{6}/i.test(v))
    expect(literal).toEqual([])
    host.dispatch("m1", host.findNode("m1", (n) => n.type === "Button" && n.props.title === "Start")!, "tap")
    await host.settle()
    expect(host.calls.find((c) => c.name === "toast.show")?.params).toEqual({ title: "Focus for 25 minutes" })
    expect(host.findNode("m1", (n) => n.type === "ProgressView")).toBeDefined()
    expect(host.findNode("m1", (n) => n.type === "Slider")).toBeUndefined()
  })
})

describe("the template folders (skills/cmux-customization/templates)", () => {
  const load = (name: string) => readFileSync(new URL(`../../../../../skills/cmux-customization/templates/${name}/main.js`, import.meta.url), "utf8")
  const init = { app: { id: "local/customize", version: "1.0.0" }, apiVersion: "1.0.0" }
  const ok = (value: unknown = null) => () => ({ ok: true, body: { value } })
  const titles = (host: FakeHost, mount: string, type: string) => [...host.tree(mount).nodes.values()].filter((n) => n.type === type).map((n) => n.props.title ?? n.props.label ?? n.props.text)
  const tap = (host: FakeHost, mount: string, type: string, title: string, payload: unknown = { gesture: "g1" }) =>
    host.dispatch(mount, host.findNode(mount, (n) => n.type === type && (n.props.title ?? n.props.label) === title)!, "tap", payload)

  test("starter: a click redraws its text and Say hi toasts", async () => {
    const host = new FakeHost(load("starter"), init)
    host.handlers["toast.show"] = ok()
    expect(host.mount("m", "renderSection")).toBe("")
    tap(host, "m", "Button", "Click")
    await host.settle()
    expect(titles(host, "m", "Text")).toContain("Clicked 1 times")
    tap(host, "m", "Button", "Say hi")
    await host.settle()
    expect(host.calls.find((c) => c.name === "toast.show")?.params).toEqual({ title: "Hi from my section", tone: "success" })
  })

  test("sidebar-section: the focused workspace's tabs, read again on a tab change, a click focuses", async () => {
    const host = new FakeHost(load("sidebar-section"), init)
    let tabs = [
      { id: "tab_1", pane_id: "pane_1", name: "zsh", index: 0, focused: true, content_kind: "terminal" },
      { id: "tab_2", pane_id: "pane_1", name: null, index: 1, focused: false, content_kind: "browser" }
    ]
    host.handlers["workspace.list"] = ok([{ id: "workspace_0", name: "web", focused: false }, { id: "workspace_1", name: "api", focused: true }])
    host.handlers["tab.list"] = (p) => ({ ok: true, body: { value: p.workspace === "workspace_1" ? tabs : [] } })
    host.handlers["tab.focus"] = ok()
    expect(host.mount("m", "renderWorkspace")).toBe("")
    await host.settle()
    expect(titles(host, "m", "Text")).toContain("api")
    expect(titles(host, "m", "Row")).toEqual(["zsh", "browser"])
    tabs = [...tabs, { id: "tab_3", pane_id: "pane_1", name: "logs", index: 2, focused: false, content_kind: "terminal" }]
    host.emit("tab.changed")
    await host.settle()
    expect(titles(host, "m", "Row")).toEqual(["zsh", "browser", "logs"])
    tap(host, "m", "Row", "logs", { gesture: "g7" })
    await host.settle()
    const focus = host.calls.find((c) => c.name === "tab.focus")!
    expect([focus.params, focus.options.gesture]).toEqual([{ tab: "tab_3" }, "g7"])
  })

  test("command-button: a button runs the person's own action with the click's gesture", async () => {
    const host = new FakeHost(load("command-button"), init)
    host.handlers["action.run"] = ok()
    expect(host.mount("m", "renderCommands")).toBe("")
    tap(host, "m", "Button", "Run tests", { gesture: "g2" })
    await host.settle()
    const run = host.calls.find((c) => c.name === "action.run")!
    expect([run.params, run.options.gesture]).toEqual([{ id: "cmuxConfig.tests", args: {} }, "g2"])
    expect(titles(host, "m", "Row")).toEqual(["Ran Run tests"])
  })

  test("command-button: with actions:run off a click says which switch to turn on", async () => {
    const host = new FakeHost(load("command-button"), init)
    host.handlers["action.run"] = () => ({ ok: false, body: { code: "scope.missing", message: "actions:run is not granted", retryable: false } })
    host.handlers["toast.show"] = ok()
    host.mount("m", "renderCommands")
    tap(host, "m", "Button", "Git status")
    await host.settle()
    expect(host.calls.find((c) => c.name === "toast.show")?.params.title).toBe("Turn on Run actions for My views")
  })

  test("pane: the checklist adds, checks and saves, and the sidebar row opens the pane", async () => {
    const host = new FakeHost(load("pane"), init)
    const saved: unknown[] = []
    host.handlers["app.storage.get"] = ok([{ id: "a", text: "Ship it", done: false }])
    host.handlers["app.storage.set"] = (p) => (saved.push(p.value), { ok: true, body: { value: null } })
    host.handlers["action.run"] = ok()
    expect(host.mount("p", "renderPane")).toBe("")
    expect(host.mount("s", "renderOpener")).toBe("")
    await host.settle()
    expect(titles(host, "p", "Toggle")).toEqual(["Ship it"])
    host.dispatch("p", host.findNode("p", (n) => n.type === "TextField")!, "submit", { text: "Write docs" })
    await host.settle()
    expect(titles(host, "p", "Toggle")).toEqual(["Ship it", "Write docs"])
    host.dispatch("p", host.findNode("p", (n) => n.type === "Toggle" && n.props.label === "Ship it")!, "change", { value: true })
    await host.settle()
    expect(saved.at(-1)).toEqual([{ id: "a", text: "Ship it", done: true }, expect.objectContaining({ text: "Write docs", done: false })])
    expect(titles(host, "s", "Row")).toEqual(["Scratchpad · 1 left"])
    tap(host, "s", "Row", "Scratchpad · 1 left", { gesture: "g3" })
    await host.settle()
    const open = host.calls.find((c) => c.name === "action.run")!
    expect([open.params, open.options.gesture]).toEqual([{ id: "app.open", args: { app: "local/customize" } }, "g3"])
  })
})
