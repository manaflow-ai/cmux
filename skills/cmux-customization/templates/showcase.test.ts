import { readFileSync } from "node:fs"
import { expect, test } from "bun:test"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

const source = (name: string) => readFileSync(new URL(`./${name}/main.js`, import.meta.url), "utf8")
const ok = (value: unknown = null) => ({ ok: true, body: { value } })
const refused = () => ({ ok: false, body: { code: "scope.missing", message: "Enable the scope in Settings", retryable: false } })
const rows = (host: FakeHost) => [...host.tree("m").nodes.values()].filter((node) => node.type === "Row")
const tap = (host: FakeHost, type: string, title: string) => {
  const id = host.findNode("m", (node) => node.type === type && node.props.title === title)
  expect(id).toBeDefined()
  host.dispatch("m", id!, "tap", { gesture: "showcase-click" })
}

test("workspace tabs follow focus with bounded subscriptions and preserve the click gesture", async () => {
  const host = new FakeHost(source("workspace-tabs"))
  let workspace = "ws_one"
  host.handlers["workspace.list"] = () => ok([{ id: workspace, name: workspace, focused: true }])
  host.handlers["tab.list"] = (params) => ok([{ id: `tab_${params.workspace}`, name: params.workspace, content_kind: "browser", focused: true }])
  host.handlers["tab.focus"] = () => ok()
  expect(host.mount("m", "renderTabs")).toBe("")
  await host.settle(12)
  expect(rows(host).map((node) => node.props.title)).toEqual(["ws_one"])
  for (let index = 0; index < 12; index++) {
    workspace = `ws_${index}`
    host.emit("workspace.changed")
    await host.settle()
    expect(rows(host).map((node) => node.props.title)).toEqual([workspace])
    expect([...host.subscriptions.values()].map((sub) => sub.stream).sort()).toEqual(["tab.changed", "workspace.changed"])
  }
  workspace = "ws_two"
  host.emit("workspace.changed")
  await host.settle(12)
  expect(rows(host).map((node) => node.props.title)).toEqual(["ws_two"])
  tap(host, "Row", "ws_two")
  await host.settle()
  expect(host.calls.find((call) => call.name === "tab.focus")).toMatchObject({ params: { tab: "tab_ws_two" }, options: { gesture: "showcase-click" } })
  host.eval('__cmuxAppUnmount("m")')
  expect(host.subscriptions.size).toBe(0)
})

test("workspace tabs coalesce change bursts and ignore a late response after unmount", async () => {
  const host = new FakeHost(source("workspace-tabs"))
  let reply: (value: ReturnType<typeof ok>) => void = () => {}
  host.handlers["workspace.list"] = () => new Promise((resolve) => { reply = resolve })
  expect(host.mount("m", "renderTabs")).toBe("")
  for (let index = 0; index < 20; index++) host.emit("workspace.changed")
  expect(host.calls.filter((call) => call.name === "workspace.list")).toHaveLength(1)
  host.eval('__cmuxAppUnmount("m")')
  const batchCount = host.batches("m").length
  reply(ok([{ id: "ws_late", name: "Late", focused: true }]))
  await host.settle()
  expect(host.subscriptions.size).toBe(0)
  expect(host.calls.filter((call) => call.name === "workspace.list")).toHaveLength(1)
  expect(host.calls.some((call) => call.name === "tab.list")).toBe(false)
  expect(host.batches("m")).toHaveLength(batchCount)
})

test("needs-you changes with agent events and opens the chosen chat", async () => {
  const host = new FakeHost(source("needs-you"))
  let state = "input"
  host.handlers["agent_chat.list"] = () => ok({ chats: [{ id: "session_a", title: "A question", state }] })
  host.handlers["action.run"] = () => ok()
  expect(host.mount("m", "renderNeedsYou")).toBe("")
  await host.settle()
  tap(host, "Row", "A question")
  await host.settle()
  expect(host.calls.find((call) => call.name === "action.run")).toMatchObject({ params: { id: "agent.openSessionTab", args: { session: "session_a" } }, options: { gesture: "showcase-click" } })
  state = "working"
  host.emit("agent_chat.changed")
  await host.settle()
  expect(rows(host)).toHaveLength(0)
  expect(host.timers.size).toBe(0)
})

test("pull-watch opens the connected GitHub result and shows refresh failures", async () => {
  const host = new FakeHost(source("pull-watch"))
  host.handlers["integration.request"] = () => ok({ items: [{ id: 7, number: 7, title: "Ship samples", html_url: "https://github.com/o/r/pull/7", repository_url: "https://api.github.com/repos/o/r", state: "open", draft: false, user: { login: "me" }, updated_at: "2026-11-13T00:00:00Z" }] })
  host.handlers["action.run"] = () => ok()
  expect(host.mount("m", "renderPulls")).toBe("")
  await host.settle(15)
  tap(host, "Row", "Ship samples")
  await host.settle()
  expect(host.calls.find((call) => call.name === "action.run")).toMatchObject({ params: { id: "openBrowser", args: { url: "https://github.com/o/r/pull/7" } }, options: { gesture: "showcase-click" } })
  host.handlers["integration.request"] = refused
  tap(host, "Button", "Refresh")
  await host.settle(15)
  expect(host.findNode("m", (node) => node.type === "EmptyState" && node.props.title === "Cannot refresh pull requests")).toBeDefined()
})

test("saved links reject unsafe URLs, persist HTTPS links and open with a gesture", async () => {
  const host = new FakeHost(source("saved-links"))
  host.handlers["app.storage.get"] = () => ok([])
  host.handlers["app.storage.set"] = () => ok()
  host.handlers["action.run"] = () => ok()
  expect(host.mount("m", "renderSavedLinks")).toBe("")
  await host.settle()
  const field = host.findNode("m", (node) => node.type === "TextField")!
  host.dispatch("m", field, "submit", { text: "javascript:alert(1)" })
  await host.settle()
  expect(rows(host)).toHaveLength(0)
  host.dispatch("m", field, "submit", { text: "https://team.example/dashboard" })
  await host.settle()
  expect(host.calls.find((call) => call.name === "app.storage.set")?.params.value).toEqual(["https://team.example/dashboard"])
  tap(host, "Row", "https://team.example/dashboard")
  await host.settle()
  expect(host.calls.find((call) => call.name === "action.run")?.options.gesture).toBe("showcase-click")
})

test("saved links keep edits disabled after a read failure and retry without overwriting", async () => {
  const host = new FakeHost(source("saved-links"))
  let reads = 0
  const writes: unknown[] = []
  host.handlers["app.storage.get"] = () => ++reads === 1 ? refused() : ok(["https://team.example/existing"])
  host.handlers["app.storage.set"] = (params) => { writes.push(params.value); return ok() }
  expect(host.mount("m", "renderSavedLinks")).toBe("")
  await host.settle()
  expect(host.findNode("m", (node) => node.type === "TextField")).toBeUndefined()
  tap(host, "Button", "Retry")
  await host.settle()
  expect(rows(host).map((node) => node.props.title)).toEqual(["https://team.example/existing"])
  host.mount("m2", "renderSavedLinks")
  await host.settle()
  expect(reads).toBe(2)
  host.dispatch("m", host.findNode("m", (node) => node.type === "TextField")!, "submit", { text: "https://team.example/new" })
  await host.settle()
  expect(writes.at(-1)).toEqual(["https://team.example/existing", "https://team.example/new"])
})

test("branch status reads the Session Info folder and displays a read error", async () => {
  const host = new FakeHost(source("branch-status"))
  host.handlers["git.status"] = () => ok({ root: "/src/project", branch: "feature", ahead: 2, behind: 1 })
  expect(host.mount("m", "renderBranch", { cwd: "/src/project" })).toBe("")
  await host.settle()
  expect(host.calls.find((call) => call.name === "git.status")?.params).toEqual({ path: "/src/project" })
  expect(rows(host)[0].props.subtitle).toBe("2 ahead · 1 behind")
  host.handlers["git.status"] = refused
  tap(host, "Button", "Refresh")
  await host.settle()
  expect(host.findNode("m", (node) => node.type === "EmptyState" && node.props.title === "Cannot read this repository")).toBeDefined()
})
