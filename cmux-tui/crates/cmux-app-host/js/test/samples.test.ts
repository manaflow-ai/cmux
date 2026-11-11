import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "./fake-host.ts"

const samples = join(import.meta.dir, "../../../../../samples/apps")
const load = (name: string) => readFileSync(join(samples, name, "dist/main.js"), "utf8")
const texts = (host: FakeHost, mount: string) => [...host.tree(mount).nodes.values()].map((n) => n.props.title ?? n.props.text).filter(Boolean)

const agents = [
  { id: "agent_1", session_id: "s", terminal_id: "term_1", state: "working", source: "hook", updated_at_ms: String(Date.now()), source_session: "agent-a" },
  { id: "agent_2", session_id: "s", terminal_id: "term_2", state: "blocked", source: "hook", updated_at_ms: String(Date.now()), source_session: "agent-b" }
]

describe("samples", () => {
  test("running-agents groups agents and focuses the tab on tap", async () => {
    const host = new FakeHost(load("running-agents"), { app: { id: "cmux/running-agents", version: "1.0.0" }, settings: { showIdle: true } })
    host.handlers["agent.list"] = () => ({ ok: true, body: { value: agents } })
    host.handlers["terminal.get"] = (p) => ({ ok: true, body: { value: { id: p.terminal, tab_id: "tab_9" } } })
    host.handlers["tab.focus"] = () => ({ ok: true, body: { value: null } })
    expect(host.mount("m", "renderAgents", { contribution: "cmux/running-agents#agents", surface: "sidebarSection" })).toBe("")
    await host.settle()
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["Waiting for you", "Working", "agent-a", "agent-b"]))
    const row = host.findNode("m", (n) => n.type === "Row" && n.props.title === "agent-b")!
    host.dispatch("m", row, "tap", { gesture: "g7" })
    await host.settle()
    const focus = host.calls.find((c) => c.name === "tab.focus")!
    expect([focus.params, focus.options.gesture]).toEqual([{ tab: "tab_9" }, "g7"])
  })

  test("priority-view ranks needs-you first, hides idle, and one rename sends one update op", async () => {
    const now = Date.now()
    let value = [
      { ...agents[0]!, id: "agent_w", state: "working", source_session: "w", updated_at_ms: String(now) },
      { ...agents[0]!, id: "agent_i", state: "idle", source_session: "i", updated_at_ms: String(now) },
      { ...agents[0]!, id: "agent_d", state: "done", source_session: "d", updated_at_ms: String(now - 5) },
      { ...agents[0]!, id: "agent_b", state: "blocked", source_session: "b", updated_at_ms: String(now - 9) }
    ]
    const host = new FakeHost(load("priority-view"), { app: { id: "cmux/priority-view", version: "0.1.0" }, settings: {} })
    host.handlers["agent.list"] = () => ({ ok: true, body: { value } })
    expect(host.mount("m", "renderPriority", { contribution: "cmux/priority-view#priority", surface: "sidebarSection" })).toBe("")
    await host.settle()
    const rowTitles = () => {
      const { root, nodes } = host.tree("m")
      const out: unknown[] = []
      const walk = (id: string) => {
        const n = nodes.get(id)
        if (!n) return
        if (n.type === "Row") out.push(n.props.title)
        n.children.forEach(walk)
      }
      walk(root)
      return out
    }
    expect(rowTitles()).toEqual(["b", "d", "w"])
    const before = host.batches("m").length
    value = value.map((a) => (a.id === "agent_w" ? { ...a, extra: { name: "w2" } } : a))
    host.emit("agent.changed")
    await host.settle()
    const sent = host.batches("m").slice(before).flat()
    expect(sent.map((op) => op.op)).toEqual(["update"])
    expect(rowTitles()).toEqual(["b", "d", "w2"])
  })

  test("agent-status summarizes", async () => {
    const host = new FakeHost(load("agent-status"))
    host.handlers["agent.list"] = () => ({ ok: true, body: { value: agents } })
    expect(host.mount("m", "renderStatus")).toBe("")
    await host.settle()
    expect(texts(host, "m")).toContain("1 working · 1 waiting")
  })

  test("github-prs loads through net.fetch when no integration is connected", async () => {
    const host = new FakeHost(load("github-prs"), { app: { id: "cmux/github-prs", version: "1.0.0" }, settings: { login: "octo" } })
    host.handlers["integration.request"] = () => ({ ok: false, body: { code: "scope.missing", message: "no integration" } })
    host.handlers["net.fetch"] = () => ({ ok: true, body: { value: { status: 200, body: JSON.stringify({ items: [{ id: 1, number: 42, title: "Add App Store", html_url: "https://github.com/manaflow-ai/cmux/pull/42", draft: false, repository_url: "https://api.github.com/repos/manaflow-ai/cmux", updated_at: "" }] }) } } })
    host.handlers["action.run"] = () => ({ ok: true, body: { value: null } })
    expect(host.mount("m", "renderPRs")).toBe("")
    await host.settle(10)
    expect(texts(host, "m")).toContain("Add App Store")
    const row = host.findNode("m", (n) => n.type === "Row")!
    host.dispatch("m", row, "tap")
    await host.settle()
    expect(host.calls.find((c) => c.name === "action.run")!.params).toEqual({ id: "openBrowser", args: { url: "https://github.com/manaflow-ai/cmux/pull/42" } })
  })
})
