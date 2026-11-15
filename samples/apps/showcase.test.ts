import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

const root = join(import.meta.dir)
const load = (name: string) => readFileSync(join(root, name, "main.js"), "utf8")
const ok = (value: unknown) => ({ ok: true, body: { value } })
const text = (host: FakeHost, mount: string, type: string) => [...host.tree(mount).nodes.values()].filter((n) => n.type === type).map((n) => n.props.text ?? n.props.title ?? n.props.message)
const workspace = [{ id: "ws_1", name: "cmux", focused: true }]

describe("customization showcase samples", () => {
  test("standup serializes rapid edits and keeps a local edit when load resolves late", async () => {
    const host = new FakeHost(load("showcase-standup"))
    expect(host.calls).toEqual([])
    let finishLoad!: (value: unknown) => void
    host.handlers["workspace.list"] = () => ok(workspace)
    host.handlers["app.storage.get"] = () => new Promise((resolve) => { finishLoad = (value) => resolve(value) })
    const saved: unknown[] = []
    host.handlers["app.storage.set"] = (p) => { saved.push(p.value); return ok(null) }
    expect(host.mount("m", "renderStandup")).toBe("")
    await host.settle()
    expect(host.findNode("m", (n) => n.type === "TextField")).toBeUndefined()
    finishLoad(ok([{ id: "seed", text: "loaded first", workspace: "cmux" }]))
    await host.settle()
    const field = host.findNode("m", (n) => n.type === "TextField")!
    host.dispatch("m", field, "submit", { text: "first" })
    host.dispatch("m", field, "submit", { text: "second" })
    await host.settle(8)
    expect(saved.at(-1)).toEqual(expect.arrayContaining([expect.objectContaining({ text: "loaded first" }), expect.objectContaining({ text: "first", workspace: "cmux" }), expect.objectContaining({ text: "second" })]))
  })

  test("standup shows a storage error instead of dropping the edit", async () => {
    const host = new FakeHost(load("showcase-standup"))
    host.handlers["workspace.list"] = () => ok(workspace)
    host.handlers["app.storage.get"] = () => ok([])
    host.handlers["app.storage.set"] = () => ({ ok: false, body: { code: "scope.missing", message: "storage off", retryable: false } })
    host.mount("m", "renderStandup"); await host.settle()
    host.dispatch("m", host.findNode("m", (n) => n.type === "TextField")!, "submit", { text: "write it" })
    await host.settle(8)
    expect(text(host, "m", "EmptyState")).toContain("Cannot save notes")
  })

  test("standup shares one local list across section mounts", async () => {
    const host = new FakeHost(load("showcase-standup"))
    let reads = 0
    host.handlers["workspace.list"] = () => ok(workspace)
    host.handlers["app.storage.get"] = () => { reads++; return ok([]) }
    host.handlers["app.storage.set"] = () => ok(null)
    host.mount("m1", "renderStandup"); host.mount("m2", "renderStandup"); await host.settle()
    expect(reads).toBe(1)
    host.dispatch("m1", host.findNode("m1", (n) => n.type === "TextField")!, "submit", { text: "shared note" })
    await host.settle()
    expect(text(host, "m2", "Row")).toContain("shared note")
  })

  test("standup retries a failed read before enabling edits", async () => {
    const host = new FakeHost(load("showcase-standup"))
    let reads = 0
    const saved: unknown[] = []
    host.handlers["workspace.list"] = () => ok(workspace)
    host.handlers["app.storage.get"] = () => ++reads === 1 ? ({ ok: false, body: { code: "scope.missing", message: "storage off", retryable: false } }) : ok([{ id: "old", text: "existing", workspace: "cmux" }])
    host.handlers["app.storage.set"] = (p) => { saved.push(p.value); return ok(null) }
    host.mount("m", "renderStandup"); await host.settle()
    expect(host.findNode("m", (n) => n.type === "TextField")).toBeUndefined()
    host.dispatch("m", host.findNode("m", (n) => n.type === "Button" && n.props.title === "Retry")!, "tap"); await host.settle()
    expect(text(host, "m", "Row")).toContain("existing")
    host.dispatch("m", host.findNode("m", (n) => n.type === "TextField")!, "submit", { text: "new" }); await host.settle(8)
    expect(saved.at(-1)).toEqual(expect.arrayContaining([expect.objectContaining({ text: "existing" }), expect.objectContaining({ text: "new" })]))
  })

  test("agent status follows live changes and reports a focus failure", async () => {
    let agents = [{ id: "a", terminal_id: "term", state: "blocked", source: "hook", source_session: "question" }]
    const host = new FakeHost(load("showcase-agent-status"))
    host.handlers["agent.list"] = () => ok(agents)
    host.handlers["terminal.get"] = () => ({ ok: false, body: { code: "scope.missing", message: "terminal read off", retryable: false } })
    host.handlers["toast.show"] = () => ok(null)
    host.mount("m", "renderStatus"); await host.settle()
    expect(text(host, "m", "Row")).toContain("question")
    agents = [{ ...agents[0]!, state: "working", source_session: "coding" }]
    host.emit("agent.changed"); await host.settle()
    expect(text(host, "m", "Row")).toContain("coding")
    host.dispatch("m", host.findNode("m", (n) => n.type === "Row")!, "tap", { gesture: "click" }); await host.settle()
    expect(host.calls.find((call) => call.name === "toast.show")?.params.title).toBe("Cannot focus agent")
  })

  test("built-in command buttons pass the clicked action through", async () => {
    const host = new FakeHost(load("showcase-command-buttons"))
    host.handlers["action.run"] = () => ok(null)
    host.mount("m", "renderCommands")
    host.dispatch("m", host.findNode("m", (n) => n.type === "Button" && n.props.title === "New workspace")!, "tap", { gesture: "click" })
    await host.settle()
    expect(host.calls.find((call) => call.name === "action.run")?.params).toEqual({ id: "newTab", args: {} })
  })

  test("review request clicks surface a browser-action failure", async () => {
    const host = new FakeHost(load("showcase-pr-review"), { app: { id: "local/showcase-pr-review", version: "1.0.0" }, settings: {} })
    host.handlers["integration.request"] = () => ok({ items: [{ id: 7, number: 7, title: "Review me", html_url: "https://github.com/o/r/pull/7", state: "open", draft: false, repository_url: "https://api.github.com/repos/o/r", updated_at: "" }] })
    host.handlers["action.run"] = () => ({ ok: false, body: { code: "scope.missing", message: "actions off", retryable: false } })
    host.handlers["toast.show"] = () => ok(null)
    host.mount("m", "renderReviewRequests"); await host.settle(8)
    host.dispatch("m", host.findNode("m", (n) => n.type === "Row" && n.props.title === "Review me")!, "tap", { gesture: "click" })
    await host.settle()
    expect(host.calls.find((call) => call.name === "toast.show")?.params.title).toBe("Cannot open pull request")
  })

  test("focus timer binds the workspace and clears its timer on unmount", async () => {
    const host = new FakeHost(load("showcase-focus-timer"))
    host.handlers["workspace.list"] = () => ok(workspace)
    expect(host.calls).toEqual([])
    host.mount("m1", "renderTimer")
    host.mount("m2", "renderTimer")
    await host.settle()
    expect(text(host, "m1", "Text")).toContain("cmux")
    host.dispatch("m1", host.findNode("m1", (n) => n.type === "Button" && n.props.title === "Start")!, "tap")
    host.dispatch("m2", host.findNode("m2", (n) => n.type === "Button" && n.props.title === "Start")!, "tap")
    expect(host.timers.size).toBe(2)
    host.global.__cmuxAppUnmount("m1")
    expect(host.timers.size).toBe(1)
    host.global.__cmuxAppUnmount("m2")
    expect(host.timers.size).toBe(0)
  })
})
