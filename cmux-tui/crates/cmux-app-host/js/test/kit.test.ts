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

  test("threads: agent chats as cards, needs-you first, running ones shelved, a click shows the chat's workspace", async () => {
    const host = new FakeHost(load("threads"), init)
    const now = Date.now()
    const chat = (id: string, title: string, state: string, minutes: number, extra: Record<string, unknown> = {}) => ({
      id, title, state, unread: false, harness: "claude", project: "api", cwd: "/src/api", workspace: null, machine: null,
      step: null, error: null, since_ms: now - minutes * 60_000, updated_ms: now - minutes * 60_000, created_ms: now - minutes * 60_000 - 1,
      pull_requests: [], ...extra
    })
    let chats = [
      chat("s1", "Old docs pass", "idle", 3 * 24 * 60),
      chat("s2", "Approve the migration", "input", 2, { workspace: "ws_2" }),
      chat("s3", "Run the suite", "working", 4),
      chat("s4", "Fix the upload test", "idle", 7, { unread: true, pull_requests: ["https://github.com/o/r/pull/1"] })
    ]
    host.handlers["agent_chat.list"] = () => ({ ok: true, body: { value: { chats } } })
    host.handlers["workspace.list"] = ok([{ id: "ws_1", name: "web", focused: true }])
    host.handlers["workspace.focus"] = ok()
    expect(host.mount("m", "renderThreads")).toBe("")
    await host.settle()
    const texts = () => liveTexts(host)
    // Newest first; the running chat and the day-old one wait in closed shelves.
    expect(texts()).toEqual(expect.arrayContaining(["Approve the migration", "Fix the upload test", "Input", "Done", "Working", "Earlier"]))
    expect(texts()).not.toContain("Run the suite")
    expect(texts()).not.toContain("Old docs pass")
    expect(texts().indexOf("Approve the migration")).toBeLessThan(texts().indexOf("Fix the upload test"))
    // No polling: it reads again on agent_chat.changed; only the ages tick (30 s, no read).
    expect([...host.subscriptions.values()].map((s) => s.stream)).toContain("agent_chat.changed")
    expect([...host.timers.values()]).toEqual([{ ms: 30000, repeat: true }])
    // Opening the Working shelf shows its chat with a live duration.
    host.dispatch("m", tappableAround(host, "Working"), "tap", { gesture: "g1" })
    await host.settle()
    expect(texts()).toEqual(expect.arrayContaining(["Run the suite", "Working 4m"]))
    // A chat that leaves is gone on the next read, when the app tells the daemon its chats changed.
    chats = chats.filter((c) => c.id !== "s4")
    host.emit("agent_chat.changed")
    await host.settle()
    expect(texts()).not.toContain("Fix the upload test")
    // A click on a card shows the chat's workspace.
    host.dispatch("m", tappableAround(host, "Approve the migration"), "tap", { gesture: "g5" })
    await host.settle()
    const focus = host.calls.find((c) => c.name === "workspace.focus")!
    expect([focus.params, focus.options.gesture]).toEqual([{ workspace: "ws_2" }, "g5"])
  })
})

describe("the widget templates (clock-weather, my-prs, design-links)", () => {
  const load = (name: string) => readFileSync(new URL(`../../../../../skills/cmux-customization/templates/${name}/main.js`, import.meta.url), "utf8")
  const init = { app: { id: "local/customize", version: "1.0.0" }, apiVersion: "1.0.0" }
  const ok = (value: unknown = null) => () => ({ ok: true, body: { value } })
  const fetched = (body: unknown) => ({ ok: true, body: { value: { status: 200, headers: {}, body: JSON.stringify(body) } } })

  test("clock-weather: the time with no scope; a saved city reads its weather; a typed city is found and kept", async () => {
    const host = new FakeHost(load("clock-weather"), init)
    host.handlers["app.storage.get"] = ok(null)
    host.handlers["app.storage.set"] = ok()
    host.handlers["net.fetch"] = (p) =>
      p.url.startsWith("https://geocoding-api.open-meteo.com/")
        ? fetched({ results: [{ name: "Tokyo", latitude: 35.68, longitude: 139.69 }] })
        : fetched({ current: { temperature_2m: 21.4, weather_code: 0 }, daily: { temperature_2m_max: [24.2], temperature_2m_min: [15.6] } })
    expect(host.mount("m", "renderClock")).toBe("")
    await host.settle()
    expect(liveTexts(host).some((t) => /^\d\d:\d\d$/.test(t))).toBe(true)
    expect(host.calls.filter((c) => c.name === "net.fetch")).toEqual([])
    // A clock and a 15-minute weather read; nothing faster than the host's 1 s floor.
    expect([...host.timers.values()].map((t) => t.ms).sort((a, b) => a - b)).toEqual([15000, 900000])
    host.dispatch("m", host.findNode("m", (n) => n.type === "TextField")!, "submit", { text: "Tokyo" })
    await host.settle(10)
    expect(liveTexts(host)).toContain("21°")
    expect(liveTexts(host).some((t) => t.includes("Tokyo, Clear, 16° to 24°"))).toBe(true)
    expect(host.calls.find((c) => c.name === "app.storage.set")?.params).toEqual({ key: "place", value: { name: "Tokyo", latitude: 35.68, longitude: 139.69 } })
    expect(host.findNode("m", (n) => n.type === "TextField")).toBeUndefined()
  })

  test("my-prs: yours and your reviews, kept in the order you move them, read again when a chat changes", async () => {
    const host = new FakeHost(load("my-prs"), init)
    const item = (id: number, title: string) => ({ id, number: id, title, html_url: `https://github.com/o/r/pull/${id}`, repository_url: "https://api.github.com/repos/o/r", draft: false })
    host.handlers["app.storage.get"] = ok(null)
    host.handlers["app.storage.set"] = ok()
    host.handlers["action.run"] = ok()
    host.handlers["integration.request"] = (p) =>
      ({ ok: true, body: { value: { items: p.path.includes("review-requested") ? [item(3, "Review me")] : [item(1, "First"), item(2, "Second")] } } })
    expect(host.mount("m", "renderPRs")).toBe("")
    await host.settle(10)
    const rows = () => rowTitles(host)
    expect(rows()).toEqual(["First", "Second", "Review me"])
    expect([...host.subscriptions.values()].map((s) => s.stream)).toContain("agent_chat.changed")
    expect([...host.timers.values()]).toContainEqual({ ms: 60000, repeat: true })
    const row = (title: string) => host.findNode("m", (n) => n.type === "Row" && n.props.title === title)!
    // Move to top is the row's menu entry 2 (Open, divider, Move to top).
    host.dispatch("m", row("Review me"), "menu", { path: [2] })
    await host.settle()
    expect(rows()).toEqual(["Review me", "First", "Second"])
    expect(host.calls.filter((c) => c.name === "app.storage.set").at(-1)?.params).toEqual({ key: "order", value: [3, 1, 2] })
    host.dispatch("m", row("First"), "tap", { gesture: "g4" })
    await host.settle()
    const open = host.calls.find((c) => c.name === "action.run")!
    expect([open.params, open.options.gesture]).toEqual([{ id: "openBrowser", args: { url: "https://github.com/o/r/pull/1" } }, "g4"])
    // A chat change inside 20 s of the last read waits for one later read instead of searching at once.
    const searches = () => host.calls.filter((c) => c.name === "integration.request").length
    const before = searches()
    host.emit("agent_chat.changed")
    host.emit("agent_chat.changed")
    await host.settle()
    expect(searches()).toBe(before)
    expect([...host.timers.values()].filter((t) => t.ms === 20000 && !t.repeat)).toHaveLength(1)
  })

  test("my-prs: with no connected account it asks for a login and reads the public API", async () => {
    const host = new FakeHost(load("my-prs"), init)
    host.handlers["app.storage.get"] = ok(null)
    host.handlers["app.storage.set"] = ok()
    host.handlers["integration.request"] = () => ({ ok: false, body: { code: "provider.unavailable", message: "no provider", retryable: false } })
    host.handlers["net.fetch"] = (p) =>
      p.url.includes("nobody")
        ? { ok: true, body: { value: { status: 422, headers: {}, body: "{}" } } }
        : { ok: true, body: { value: { status: 200, headers: {}, body: JSON.stringify({ items: p.url.includes("author%3Aoctocat") ? [{ id: 7, number: 7, title: "Public one", html_url: "https://github.com/o/r/pull/7", repository_url: "https://api.github.com/repos/o/r" }] : [] }) } } }
    host.mount("m", "renderPRs")
    await host.settle(10)
    expect(host.calls.filter((c) => c.name === "net.fetch")).toEqual([])
    // A login GitHub does not know asks again instead of hiding the field for good.
    host.dispatch("m", host.findNode("m", (n) => n.type === "TextField")!, "submit", { text: "nobody" })
    await host.settle(10)
    expect(host.findNode("m", (n) => n.type === "TextField")).toBeDefined()
    expect(host.calls.find((c) => c.name === "net.fetch")?.params.headers["User-Agent"]).toBe("cmux-my-prs")
    host.dispatch("m", host.findNode("m", (n) => n.type === "TextField")!, "submit", { text: "octocat" })
    await host.settle(10)
    expect(rowTitles(host)).toEqual(["Public one"])
    expect(host.calls.filter((c) => c.name === "app.storage.set" && c.params.key === "login").at(-1)?.params.value).toBe("octocat")
    expect(host.findNode("m", (n) => n.type === "TextField")).toBeUndefined()
  })

  test("my-prs: a login with no open PRs can still be changed", async () => {
    const host = new FakeHost(load("my-prs"), init)
    host.handlers["app.storage.get"] = (p) => ({ ok: true, body: { value: p.key === "login" ? "quiet" : null } })
    host.handlers["app.storage.set"] = ok()
    host.handlers["integration.request"] = () => ({ ok: false, body: { code: "provider.unavailable", message: "no provider", retryable: false } })
    host.handlers["net.fetch"] = () => fetched({ items: [] })
    host.mount("m", "renderPRs")
    await host.settle(10)
    expect(rowTitles(host)).toEqual([])
    expect(host.findNode("m", (n) => n.type === "TextField")).toBeUndefined()
    host.dispatch("m", host.findNode("m", (n) => n.type === "Button" && n.props.title === "Change GitHub login")!, "tap")
    await host.settle()
    expect(host.findNode("m", (n) => n.type === "TextField")).toBeDefined()
  })

  test("design-links: a pasted Figma link gets its file name and opens in a browser tab", async () => {
    const host = new FakeHost(load("design-links"), init)
    host.handlers["app.storage.get"] = ok(null)
    host.handlers["app.storage.set"] = ok()
    host.handlers["action.run"] = ok()
    host.handlers["toast.show"] = ok()
    expect(host.mount("m", "renderLinks")).toBe("")
    await host.settle()
    const field = () => host.findNode("m", (n) => n.type === "TextField")!
    host.dispatch("m", field(), "submit", { text: "ftp://nope" })
    await host.settle()
    expect(host.calls.find((c) => c.name === "toast.show")?.params.title).toBe("Paste a link that starts with https://")
    const url = "https://www.figma.com/design/AbC123/Checkout-Flow-v2?node-id=1-2"
    host.dispatch("m", field(), "submit", { text: url })
    await host.settle()
    const row = host.findNode("m", (n) => n.type === "Row")!
    expect([host.tree("m").nodes.get(row)!.props.title, host.tree("m").nodes.get(row)!.props.subtitle]).toEqual(["Checkout Flow v2", "Figma"])
    host.dispatch("m", row, "tap", { gesture: "g9" })
    await host.settle()
    const open = host.calls.find((c) => c.name === "action.run")!
    expect([open.params, open.options.gesture]).toEqual([{ id: "openBrowser", args: { url } }, "g9"])
  })
})

/** The titles of the Rows reachable from the root, in screen order (a reorder only moves children). */
function rowTitles(host: FakeHost, mount = "m"): unknown[] {
  const tree = host.tree(mount)
  const out: unknown[] = []
  const walk = (id: string) => {
    const n = tree.nodes.get(id)
    if (!n) return
    if (n.type === "Row") out.push(n.props.title)
    n.children.forEach(walk)
  }
  walk(tree.root)
  return out
}

/** The texts of the nodes reachable from the root, in order (detached nodes left out). */
function liveTexts(host: FakeHost): string[] {
  const tree = host.tree("m")
  const out: string[] = []
  const walk = (id: string) => {
    const n = tree.nodes.get(id)
    if (!n) return
    if (n.type === "Text") out.push(String(n.props.text))
    n.children.forEach(walk)
  }
  walk(tree.root)
  return out
}

/** The nearest node with a tap handler around the Text that reads `text` (a card, a shelf header). */
function tappableAround(host: FakeHost, text: string): string {
  const tree = host.tree("m")
  const parent = new Map<string, string>()
  for (const [id, n] of tree.nodes) for (const child of n.children) parent.set(child, id)
  let id = [...tree.nodes.entries()].find(([, n]) => n.type === "Text" && n.props.text === text)?.[0]
  while (id && tree.nodes.get(id)!.props.onTap !== true) id = parent.get(id)
  if (!id) throw new Error(`no tappable node around ${text}`)
  return id
}
