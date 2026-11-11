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

  /** One `chat.list` row (Cmux.ChatSummary), `ago` minutes since its state began. */
  const chat = (id: string, state: string, ago: number, extra: Record<string, unknown> = {}) => ({
    id, title: id, harness: "claude", state, unread: false, unread_turns: 0, pinned: false, ci_failing: null,
    machine: null, cwd: "/src/cmux", project: "cmux", workspace: null, parent: null, step: null, error: null,
    since_ms: String(Date.now() - ago * 60_000), updated_ms: String(Date.now() - ago * 60_000),
    created_ms: String(Date.now() - 3_600_000), pull_requests: [], ...extra
  })
  /** AgentPriorityRankingTests.lanes, as chat.list rows. */
  const nativeFixture = () => [
    chat("idle-old", "idle", 30),
    chat("working", "working", 5, { step: "Running tests" }),
    chat("done", "idle", 20, { unread: true, unread_turns: 1 }),
    chat("asks", "input", 50, { machine: "mini" }),
    chat("broke", "failed", 10, { error: "Credit balance too low" }),
    chat("asks-new", "input", 1),
    chat("idle-new", "idle", 2)
  ]
  const mountPriority = (value: () => unknown[], settings: Record<string, unknown> = { showIdle: true }) => {
    const host = new FakeHost(load("priority-view"), { app: { id: "cmux/priority-view", version: "0.1.0" }, settings })
    host.handlers["chat.list"] = () => ({ ok: true, body: { value: value() } })
    expect(host.mount("m", "renderPriority", { contribution: "cmux/priority-view#priority", surface: "sidebarSection" })).toBe("")
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
    return { host, rowTitles }
  }

  // extensibility-DESIGN.md step 3: the sample reads chat.list and orders it as the native
  // Priority View does (AgentPriorityRankingTests): needs you, finished unseen, failed or lost,
  // CI failing, working, idle; pinned first in a tier, then the most recent.
  test("priority-view orders chat.list as the native ranking tiers, pinned first in a tier", async () => {
    let value = [
      ...nativeFixture(),
      chat("red-ci", "idle", 3, { ci_failing: true }),
      chat("red-stale", "idle", 60 * 48, { ci_failing: true })
    ]
    const { host, rowTitles } = mountPriority(() => value)
    await host.settle()
    expect(rowTitles()).toEqual(["asks-new", "asks", "done", "broke", "red-ci", "red-stale", "working", "idle-new", "idle-old"])

    // aPinnedChatLeadsItsTierAndStaysWhileIdleForLong: a stale idle chat is gone until pinned.
    value = [...nativeFixture(), chat("stale", "idle", 60 * 48)]
    host.emit("chat.changed")
    await host.settle()
    expect(rowTitles()).not.toContain("stale")
    value = value.map((c) => (c.id === "stale" || c.id === "idle-old" ? { ...c, pinned: true } : c))
    host.emit("chat.changed")
    await host.settle()
    expect(rowTitles().slice(-3)).toEqual(["idle-old", "stale", "idle-new"])

    // A pinned chat leads the needs-you tier too.
    value = value.map((c) => (c.id === "asks" ? { ...c, pinned: true } : c))
    host.emit("chat.changed")
    await host.settle()
    expect(rowTitles().slice(0, 2)).toEqual(["asks", "asks-new"])
  })

  test("priority-view hides idle chats unless pinned, and one rename sends one update op", async () => {
    let value = nativeFixture()
    const { host, rowTitles } = mountPriority(() => value, {})
    await host.settle()
    expect(rowTitles()).toEqual(["asks-new", "asks", "done", "broke", "working"])
    const before = host.batches("m").length
    value = value.map((c) => (c.id === "working" ? { ...c, title: "working 2" } : c))
    host.emit("chat.changed")
    await host.settle()
    const sent = host.batches("m").slice(before).flat()
    expect(sent.map((op) => op.op)).toEqual(["update"])
    expect(rowTitles()).toEqual(["asks-new", "asks", "done", "broke", "working 2"])
  })

  test("priority-view opens a tapped chat's workspace and marks it read with the tap's gesture", async () => {
    const value = [chat("done", "idle", 20, { unread: true, workspace: "ws_7" })]
    const { host } = mountPriority(() => value)
    host.handlers["workspace.focus"] = () => ({ ok: true, body: { value: null } })
    host.handlers["chat.mark_read"] = () => ({ ok: true, body: { value: null } })
    await host.settle()
    const row = host.findNode("m", (n) => n.type === "Row" && n.props.title === "done")!
    host.dispatch("m", row, "tap", { gesture: "g7" })
    await host.settle()
    const focus = host.calls.find((c) => c.name === "workspace.focus")!
    const read = host.calls.find((c) => c.name === "chat.mark_read")!
    expect([focus.params, focus.options.gesture]).toEqual([{ workspace: "ws_7" }, "g7"])
    expect([read.params, read.options.gesture]).toEqual([{ chat: "done" }, "g7"])
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
  test("pr-card shows a PR's checks five a page and keeps its page under the widget key", async () => {
    const checks = Array.from({ length: 7 }, (_, i) => ({ id: i + 1, name: `check-${i + 1}`, status: "completed", conclusion: i === 6 ? "failure" : "success", html_url: `https://github.com/o/r/runs/${i + 1}` }))
    const github = (params: any) => {
      const path = String(params.path)
      if (path === "/repos/o/r/pulls/7") return { ok: true, body: { value: { title: "Widgets in chat", state: "open", merged_at: null, draft: false, user: { login: "octo" }, html_url: "https://github.com/o/r/pull/7", head: { sha: "abc" } } } }
      if (path.startsWith("/repos/o/r/commits/abc/check-runs")) return { ok: true, body: { value: { check_runs: checks } } }
      return { ok: false, body: { code: "not_found", message: path } }
    }
    const storage = new Map<string, unknown>()
    const make = () => {
      const host = new FakeHost(load("pr-card"), { app: { id: "cmux/pr-card", version: "1.0.0" }, settings: {} })
      host.handlers["integration.request"] = github
      host.handlers["app.storage.get"] = (p) => ({ ok: true, body: { value: storage.get(p.key) ?? null } })
      host.handlers["app.storage.set"] = (p) => { storage.set(p.key, p.value); return { ok: true, body: { value: null } } }
      return host
    }
    const ctx = { contribution: "cmux/pr-card#cmux.chat.widget/1", surface: "chatWidget", props: { repo: "o/r", number: 7 }, widget: { key: "msg_1#0" } }
    const rows = (host: FakeHost) => [...host.tree("m").nodes.values()].filter((n) => n.type === "Row").map((n) => n.props.title)
    const host = make()
    expect(host.mount("m", "renderPRCard", ctx)).toBe("")
    await host.settle(10)
    // The failure first, then four of the six that passed; page 1 of 2.
    expect(rows(host)).toEqual(["o/r #7", "check-7", "check-1", "check-2", "check-3", "check-4"])
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["Widgets in chat", "1 failed · 6 passed", "Page 1 of 2", "Previous", "Next"]))
    host.dispatch("m", host.findNode("m", (n) => n.type === "Button" && n.props.title === "Next")!, "tap", {})
    await host.settle(10)
    expect(rows(host)).toEqual(["o/r #7", "check-5", "check-6"])
    expect(storage.get("page:msg_1#0")).toBe(1)
    // A new mount (a relaunch) starts on the kept page.
    const again = make()
    again.mount("m", "renderPRCard", ctx)
    await again.settle(10)
    expect(rows(again)).toEqual(["o/r #7", "check-5", "check-6"])
  })
})
