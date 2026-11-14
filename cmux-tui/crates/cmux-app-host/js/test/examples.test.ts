// The example extensions (examples/extensions/*) in the fake host, and the moved github-prs
// sample's budget: timers and upstream reads before (hand-rolled cmux.timer.every) and after
// (cmux.watch), counted the same way.
import { beforeAll, describe, expect, test } from "bun:test"
import { readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "./fake-host.ts"

const root = join(import.meta.dir, "../../../../..")
const load = (dir: string) => readFileSync(join(root, dir, "dist/main.js"), "utf8")
const ok = (value: unknown) => ({ ok: true, body: { value } })
const rows = (host: FakeHost, mount: string) => [...host.tree(mount).nodes.values()].filter((n) => n.type === "Row")

const item = (id: number, extra: Record<string, unknown> = {}) => ({
  id,
  number: id,
  title: `PR ${id}`,
  html_url: `https://github.com/o/r/pull/${id}`,
  draft: false,
  state: "open",
  repository_url: "https://api.github.com/repos/o/r",
  user: { login: "octo" },
  updated_at: `2026-11-09T00:${String(59 - id).padStart(2, "0")}:00Z`,
  ...extra
})

function prList(answer: (path: string) => { ok: boolean; body: unknown }) {
  const host = new FakeHost(load("examples/extensions/pr-list"), { app: { id: "local/pr-list", version: "1.0.0" }, settings: {} })
  host.handlers["integration.request"] = (p) => answer(decodeURIComponent(String(p.path)))
  host.handlers["action.run"] = () => ok(null)
  return host
}

function fireTimers(host: FakeHost) {
  for (const [id] of [...host.timers]) {
    host.timers.delete(id)
    host.global.__cmuxAppTimer(id)
  }
}

describe("local/pr-list", () => {
  test("lists review requests first with their state, and a click opens the PR", async () => {
    const host = prList((path) => ok({ items: path.includes("review-requested") ? [item(3)] : [item(1), item(2, { draft: true })] }))
    expect(host.mount("m", "renderPullRequests")).toBe("")
    await host.settle()
    expect(rows(host, "m").map((r) => [r.props.title, r.props.symbol, r.props.badge ?? null])).toEqual([
      ["PR 3", "eye", "Review"],
      ["PR 1", "arrow.triangle.pull", null],
      ["PR 2", "circle.dashed", null]
    ])
    expect(rows(host, "m")[2]!.props.subtitle).toBe("o/r #2 · Draft")
    const id = host.findNode("m", (n) => n.type === "Row" && n.props.title === "PR 1")!
    host.dispatch("m", id, "tap", { gesture: "g1" })
    await host.settle()
    expect(host.calls.find((c) => c.name === "action.run")!.params).toEqual({ id: "openBrowser", args: { url: "https://github.com/o/r/pull/1" } })
  })

  test("a failed refresh keeps the list, dimmed, under a retry row", async () => {
    let fail = false
    const host = prList(() => (fail ? { ok: false, body: { code: "operation.failed", message: "GitHub is slow", retryable: true } } : ok({ items: [item(1)] })))
    host.mount("m", "renderPullRequests")
    await host.settle()
    fail = true
    fireTimers(host)
    await host.settle()
    const byTitle = new Map(rows(host, "m").map((r) => [r.props.title, r.props]))
    expect([...byTitle.keys()].sort()).toEqual(["Couldn't refresh", "PR 1"])
    expect(String(byTitle.get("Couldn't refresh")!.subtitle)).toContain("GitHub is slow")
    expect(byTitle.get("PR 1")!.opacity).toBe(0.6)
  })

  test("no connection and no login is an empty state that says what to do", async () => {
    const host = prList(() => ({ ok: false, body: { code: "integration.not_connected", message: "no" } }))
    host.mount("m", "renderPullRequests")
    await host.settle()
    const empty = [...host.tree("m").nodes.values()].find((n) => n.type === "EmptyState")!
    expect(empty.props.message).toContain("Connect GitHub")
  })

  test("the Refresh command re-reads the section's watch", async () => {
    const host = prList(() => ok({ items: [item(1)] }))
    host.mount("m", "renderPullRequests")
    await host.settle()
    const before = host.calls.length
    host.runCommand("refresh", {}, 5)
    await host.settle()
    expect(host.commandResults.get(5)).toEqual({ ok: true, body: { value: { count: 1, status: "fresh" } } })
    expect(host.calls.length - before).toBe(2) // review-requested + author, once
  })
})

describe("github-prs on cmux.watch: budget", () => {
  // Before (hand-rolled, samples/apps/github-prs at feat-cmux-next 7d3e847): each section ran
  // cmux.timer.every(5 min) plus a read on every mount: 2 repeating timers per window; a second
  // window doubled both; a remount read again. After: one entry per section's params, one timer each.
  test("two windows showing both sections: one read per section, one timer per section, none when hidden", async () => {
    const host = new FakeHost(load("samples/apps/github-prs"), { app: { id: "cmux/github-prs", version: "1.0.0" }, settings: {} })
    host.handlers["integration.request"] = () => ok({ items: [item(1)] })
    for (const w of ["w1", "w2"]) {
      expect(host.mount(`${w}-prs`, "renderPRs")).toBe("")
      expect(host.mount(`${w}-recent`, "renderRecentPRs")).toBe("")
    }
    await host.settle()
    // prs: 1 search (author); recent: 3 searches (author, review-requested, assignee). Once, not per window.
    expect(host.calls.filter((c) => c.name === "integration.request").length).toBe(4)
    expect(host.timers.size).toBe(2)
    expect([...host.timers.values()].every((t) => t.ms === 300_000 && !t.repeat)).toBe(true)
    // A remount within 5 minutes reads nothing.
    host.global.__cmuxAppUnmount("w2-prs")
    host.mount("w2-prs", "renderPRs")
    await host.settle()
    expect(host.calls.filter((c) => c.name === "integration.request").length).toBe(4)
    // Hidden (every section unmounted): no timer, no subscription, no reads.
    for (const m of ["w1-prs", "w1-recent", "w2-prs", "w2-recent"]) host.global.__cmuxAppUnmount(m)
    expect(host.timers.size).toBe(0)
    expect(host.subscriptions.size).toBe(0)
  })
})

// examples/extensions/activity is built only against the public SDK (cmux-extension-sdk): a sidebar
// section and a pane that react to workspace, agent and chat events.
describe("local/activity (cmux-extension-sdk only)", () => {
  const dir = "examples/extensions/activity"
  const chat = (id: string, workspace: string | null, state: string, unread = false) =>
    ({ id, title: id, state, unread, harness: "claude", project: null, cwd: null, workspace, machine: null, updated_ms: 0 })

  // Rows in drawn order (the tree from its root), not creation order.
  const drawn = (host: FakeHost, mount: string) => {
    const tree = host.tree(mount)
    const out: Array<Record<string, unknown>> = []
    const walk = (id: string) => {
      const n = tree.nodes.get(id)
      if (!n) return
      if (n.type === "Row") out.push(n.props)
      n.children.forEach(walk)
    }
    walk(tree.root)
    return out
  }

  // Built the way `cmux ext dev` builds it (dist/ is build output, never committed).
  let built: string | undefined
  beforeAll(async () => {
    const { pack } = await import("../../tools/pack.ts")
    built = await pack(join(root, dir))
  })

  function activity() {
    const host = new FakeHost(built!, { app: { id: "local/activity", version: "1.0.0" }, settings: {} })
    const state = {
      workspaces: [{ id: "ws_1", session_id: "s", name: "api", index: 0, focused: true }, { id: "ws_2", session_id: "s", name: "web", index: 1, focused: false }],
      agents: [{ id: "a1", state: "working" }, { id: "a2", state: "idle" }],
      chats: [chat("c1", "ws_2", "input"), chat("c2", "ws_2", "idle", true), chat("c3", "ws_1", "working")]
    }
    host.handlers["workspace.list"] = () => ok(state.workspaces)
    host.handlers["agent.list"] = () => ok(state.agents)
    host.handlers["agent_chat.list"] = () => ok({ chats: state.chats })
    host.handlers["workspace.focus"] = () => ok({})
    return { host, state }
  }

  test("imports nothing but cmux-extension-sdk, and builds to one script that sets its exports", () => {
    const src = readFileSync(join(root, dir, "src/main.ts"), "utf8")
    expect([...src.matchAll(/from\s+"([^"]+)"/g)].map((m) => m[1])).toEqual(["cmux-extension-sdk"])
    expect(src).not.toContain("<reference")
    expect(built).toContain("__cmuxAppExports")
  })

  test("the section lists each workspace with the chats waiting in it, and redraws on agent_chat.changed", async () => {
    const { host, state } = activity()
    expect(host.mount("s", "renderSection")).toBe("")
    await host.settle()
    expect(drawn(host, "s").map((r) => [r.title, r.subtitle ?? null, r.badge ?? null])).toEqual([
      ["1 agent working", null, null],
      ["api", null, null],
      ["web", "2 chats waiting for you", 2]
    ])
    // Pushed, not polled: it subscribes to the three streams and arms no timer.
    expect(new Set([...host.subscriptions.values()].map((s) => s.stream))).toEqual(new Set(["workspace.changed", "agent.changed", "agent_chat.changed"]))
    expect(host.timers.size).toBe(0)
    state.chats = [chat("c1", "ws_2", "working")]
    host.emit("agent_chat.changed")
    await host.settle()
    expect(rows(host, "s").find((r) => r.props.title === "web")!.props.subtitle ?? null).toBe(null)
    state.workspaces = [...state.workspaces, { id: "ws_3", session_id: "s", name: "docs", index: 2, focused: false }]
    host.emit("workspace.changed")
    await host.settle()
    expect(rows(host, "s").map((r) => r.props.title)).toContain("docs")
  })

  test("a click on a workspace row shows that workspace", async () => {
    const { host } = activity()
    host.mount("s", "renderSection")
    await host.settle()
    host.dispatch("s", host.findNode("s", (n) => n.type === "Row" && n.props.title === "web")!, "tap")
    await host.settle()
    expect(host.calls.filter((c) => c.name === "workspace.focus").map((c) => c.params.workspace)).toEqual(["ws_2"])
  })

  test("the pane is a live feed of events, newest first, and unsubscribes when closed", async () => {
    const { host } = activity()
    expect(host.mount("p", "renderPane")).toBe("")
    await host.settle()
    expect(rows(host, "p")).toEqual([])
    host.emit("workspace.changed")
    await host.settle()
    host.emit("agent_chat.changed")
    await host.settle()
    expect(drawn(host, "p").map((r) => r.title)).toEqual(["A chat changed", "Workspaces changed"])
    host.global.__cmuxAppUnmount("p")
    expect(host.subscriptions.size).toBe(0)
  })
})

// examples/extensions/workspace-list is the built-in workspace list rebuilt on the public SDK: the
// whole list (`cmux.sidebar/1`, drawn in place of the built-in one once the person picks it in
// `sidebar.workspaceListApp`) and the same list as a section. Copy the folder to fork it.
describe("local/workspace-list (cmux-extension-sdk only)", () => {
  const dir = "examples/extensions/workspace-list"
  const chat = (id: string, workspace: string | null, state: string, unread = false) =>
    ({ id, title: id, state, unread, harness: "claude", project: null, cwd: null, workspace, machine: null, updated_ms: 0 })
  const space = (i: number, focused = false) => ({ id: `ws_${i}`, session_id: "s", name: `space ${i}`, index: i, focused })
  const drawn = (host: FakeHost, mount: string) => {
    const tree = host.tree(mount)
    const out: Array<Record<string, unknown>> = []
    const walk = (id: string) => {
      const n = tree.nodes.get(id)
      if (!n) return
      if (n.type === "Row") out.push(n.props)
      n.children.forEach(walk)
    }
    walk(tree.root)
    return out
  }

  let built: string | undefined
  beforeAll(async () => {
    const { pack } = await import("../../tools/pack.ts")
    built = await pack(join(root, dir))
  })

  function list(count = 3) {
    const host = new FakeHost(built!, { app: { id: "local/workspace-list", version: "1.0.0" }, settings: {} })
    const state = {
      workspaces: Array.from({ length: count }, (_, i) => space(i, i === 1)),
      chats: [chat("c1", "ws_2", "input"), chat("c2", "ws_2", "idle", true), chat("c3", "ws_0", "working")]
    }
    host.handlers["workspace.list"] = () => ok(state.workspaces)
    host.handlers["agent_chat.list"] = () => ok({ chats: state.chats })
    host.handlers["workspace.focus"] = () => ok({})
    return { host, state }
  }

  test("imports nothing but cmux-extension-sdk, and builds to one script that sets its exports", () => {
    const src = readFileSync(join(root, dir, "src/main.ts"), "utf8")
    expect([...src.matchAll(/from\s+"([^"]+)"/g)].map((m) => m[1])).toEqual(["cmux-extension-sdk"])
    expect(built).toContain("__cmuxAppExports")
    const manifest = JSON.parse(readFileSync(join(root, dir, "cmux-app.json"), "utf8"))
    expect(Object.keys(manifest.implements).sort()).toEqual(["cmux.section/1", "cmux.sidebar/1"])
  })

  test("the whole list draws every workspace in the person's order, the shown one selected, with what waits in it", async () => {
    const { host } = list()
    expect(host.mount("l", "renderSidebar")).toBe("")
    await host.settle()
    expect(drawn(host, "l").map((r) => [r.title, r.selected ?? false, r.badge ?? null])).toEqual([
      ["space 0", false, null],
      ["space 1", true, null],
      ["space 2", false, 2]
    ])
    // Pushed, not polled.
    expect(new Set([...host.subscriptions.values()].map((s) => s.stream))).toEqual(new Set(["workspace.changed", "agent_chat.changed"]))
    expect(host.timers.size).toBe(0)
  })

  test("a click shows that workspace, and a new workspace appears on workspace.changed", async () => {
    const { host, state } = list()
    host.mount("l", "renderSidebar")
    await host.settle()
    host.dispatch("l", host.findNode("l", (n) => n.type === "Row" && n.props.title === "space 2")!, "tap")
    await host.settle()
    expect(host.calls.filter((c) => c.name === "workspace.focus").map((c) => c.params.workspace)).toEqual(["ws_2"])
    state.workspaces = [...state.workspaces, space(3)]
    host.emit("workspace.changed")
    await host.settle()
    expect(drawn(host, "l").map((r) => r.title)).toContain("space 3")
  })

  test("the section is the same list", async () => {
    const { host } = list()
    expect(host.mount("s", "renderSection")).toBe("")
    await host.settle()
    expect(drawn(host, "s").map((r) => r.title)).toEqual(["space 0", "space 1", "space 2"])
  })

  test("500 workspaces: one read, one row each, and a change to one workspace redraws only its row", async () => {
    const { host, state } = list(500)
    host.mount("l", "renderSidebar")
    await host.settle()
    expect(drawn(host, "l").length).toBe(500)
    expect(host.calls.filter((c) => c.name === "workspace.list").length).toBe(1)
    const before = host.tree("l").nodes.size
    const batches = host.batches("l").length
    // A re-read returns new objects for every workspace, as the daemon's answer does.
    state.workspaces = state.workspaces.map((w) => ({ ...w, name: w.id === "ws_7" ? "renamed" : w.name }))
    host.emit("workspace.changed")
    await host.settle()
    expect(host.tree("l").nodes.size).toBe(before)
    expect(drawn(host, "l")[7]!.title).toBe("renamed")
    // The redraw is one update of that row's title: nothing created, removed or re-ordered.
    const ops = host.batches("l").slice(batches).flat()
    expect(ops.filter((o) => o.op !== "update")).toEqual([])
    expect(ops.map((o) => o.props)).toEqual([{ title: "renamed" }])
  })
})

describe("cmux-extension-sdk", () => {
  // The package bundled the way `cmux ext dev` bundles an extension, exposed as globalThis.__sdk.
  async function sdkHost(body: string) {
    const entry = join(root, "cmux-tui/crates/cmux-extension-sdk/typescript/src/.sdk-test-entry.ts")
    writeFileSync(entry, `import * as sdk from "./index.ts"\n;(globalThis as any).__sdk = sdk\n`)
    try {
      const out = await Bun.build({ entrypoints: [entry], format: "iife", target: "browser" })
      if (!out.success) throw new Error(out.logs.map(String).join("\n"))
      return new FakeHost(`${await out.outputs[0]!.text()}\n${body}`)
    } finally {
      rmSync(entry, { force: true })
    }
  }

  test("on() refuses a stream cmux does not send, naming the ones it does", async () => {
    const host = await sdkHost(`globalThis.__cmuxAppExports = { render: () => { __sdk.on("workspace.chagned", () => {}); return __sdk.Text("x") } }`)
    const error = host.mount("m", "render")
    expect(error).toContain("unknown event stream")
    expect(error).toContain("workspace.changed")
  })

  test("versions and the event table are the runtime's own (no copies)", async () => {
    const host = await sdkHost("")
    const json = (path: string) => JSON.parse(readFileSync(join(import.meta.dir, "..", "..", path), "utf8"))
    expect(host.eval("__sdk.API_VERSION")).toBe(json("generated/scopes.json").apiVersion)
    expect(host.eval("__sdk.RUNTIME_VERSION")).toBe(host.eval("__cmuxAppRuntimeVersion"))
    expect(host.eval("__sdk.RUNTIME_VERSION")).not.toBe("")
    expect(host.eval("__sdk.EVENT_STREAMS")).toEqual(Object.keys(json("schema/v2/events.json").events))
    expect(host.eval(`__sdk.scopeFor("agent_chat.changed")`)).toBe("agent_chat:read")
  })
})
