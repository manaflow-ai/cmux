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
