// The showcase example extensions (examples/extensions/{weather,recent-prs,changes,agent-pet,
// agent-standup,workspace-notes}) in the fake host. Each imports nothing but cmux-extension-sdk.
// Their dist/ is build output (gitignored): `cmux ext dev` packs src/main.ts the same way, so
// these tests pack each one here and mount the result.
import { beforeAll, describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { pack } from "../../tools/pack.ts"
import { FakeHost } from "./fake-host.ts"

const root = join(import.meta.dir, "../../../../..")
const dir = (name: string) => join(root, "examples/extensions", name)
const ok = (value: unknown) => ({ ok: true, body: { value } })
const fail = (code: string, message = code) => ({ ok: false, body: { code, message, retryable: false } })
const NAMES = ["weather", "recent-prs", "agent-pet", "agent-standup", "workspace-notes", "changes"]
const built = new Map<string, string>()
beforeAll(async () => {
  for (const name of NAMES) built.set(name, await pack(dir(name)))
})

function host(name: string, settings: Record<string, unknown> = {}) {
  const manifest = JSON.parse(readFileSync(join(dir(name), "cmux-app.json"), "utf8"))
  return new FakeHost(built.get(name)!, { app: { id: manifest.id, version: "1.0.0" }, settings, apiVersion: "1.0.0" })
}

// Rows and texts in drawn order (the tree from its root).
function drawn(h: FakeHost, mount: string) {
  const tree = h.tree(mount)
  const out: Array<{ type: string; props: Record<string, unknown> }> = []
  const walk = (id: string) => {
    const n = tree.nodes.get(id)
    if (!n) return
    out.push(n)
    n.children.forEach(walk)
  }
  walk(tree.root)
  return out
}
const rows = (h: FakeHost, m: string) => drawn(h, m).filter((n) => n.type === "Row").map((n) => n.props)
const texts = (h: FakeHost, m: string) => drawn(h, m).filter((n) => n.type === "Text").map((n) => String(n.props.text))
const empty = (h: FakeHost, m: string) => drawn(h, m).find((n) => n.type === "EmptyState")?.props

describe("showcase examples are built only on cmux-extension-sdk", () => {
  for (const name of NAMES) {
    test(`${name}: imports nothing else, and its manifest names exports the bundle defines`, () => {
      const src = readFileSync(join(dir(name), "src/main.ts"), "utf8")
      expect([...src.matchAll(/from\s+"([^"]+)"/g)].map((m) => m[1])).toEqual(["cmux-extension-sdk"])
      expect(src).not.toContain("<reference")
      const manifest = JSON.parse(readFileSync(join(dir(name), "cmux-app.json"), "utf8"))
      expect(manifest.runtime.main).toBe("dist/main.js")
      for (const impl of Object.values(manifest.implements as Record<string, { export: string }>)) expect(built.get(name)).toContain(`function ${impl.export}(`)
    })
  }
})

describe("local/showcase-weather", () => {
  const geocode = { results: [{ name: "Lisbon", admin1: "Lisbon", country: "Portugal", latitude: 38.7, longitude: -9.1 }] }
  const forecast = {
    current: { temperature_2m: 21.4, apparent_temperature: 20.6, weather_code: 2, wind_speed_10m: 11.8, is_day: 1 },
    daily: { temperature_2m_max: [24.2], temperature_2m_min: [15.1] }
  }
  function weather(settings: Record<string, unknown>) {
    const h = host("weather", settings)
    h.handlers["net.fetch"] = (p) => ok({ status: 200, body: JSON.stringify(String(p.url).includes("geocoding") ? geocode : forecast) })
    h.handlers["app.settings.set"] = (p) => {
      h.global.__cmuxAppSetSettings(JSON.stringify({ ...settings, ...p.values }))
      return ok(null)
    }
    return h
  }

  test("shows the conditions for the place in its settings, in the chosen units", async () => {
    const h = weather({ place: "Lisbon", units: "fahrenheit" })
    expect(h.mount("m", "renderWeather")).toBe("")
    await h.settle(10)
    expect(texts(h, "m")).toEqual(["21°", "Lisbon", "Lisbon", "Partly cloudy · feels like 21°", "High 24° · low 15° · wind 12 mph"])
    const urls = h.calls.filter((c) => c.name === "net.fetch").map((c) => String(c.params.url))
    expect(urls.length).toBe(2)
    expect(urls[1]).toContain("temperature_unit=fahrenheit")
    // It refreshes on a 15 minute timer that ends with the view.
    expect([...h.timers.values()]).toEqual([{ ms: 15 * 60_000, repeat: true }])
    h.global.__cmuxAppUnmount("m")
    expect(h.timers.size).toBe(0)
  })

  test("with no place it asks for one, and the answer becomes the setting", async () => {
    const h = weather({})
    h.mount("m", "renderWeather")
    await h.settle()
    expect(h.calls.filter((c) => c.name === "net.fetch")).toEqual([])
    const field = h.findNode("m", (n) => n.type === "TextField")!
    h.dispatch("m", field, "submit", { text: "Lisbon" })
    await h.settle(10)
    expect(h.calls.find((c) => c.name === "app.settings.set")!.params).toEqual({ values: { place: "Lisbon" } })
    expect(texts(h, "m")).toContain("21°")
  })

  test("two windows share one read", async () => {
    const h = weather({ place: "Lisbon" })
    h.mount("a", "renderWeather")
    h.mount("b", "renderWeather")
    await h.settle(10)
    expect(h.calls.filter((c) => c.name === "net.fetch").length).toBe(2) // one geocode, one forecast
    expect(texts(h, "b")).toContain("21°")
  })

  test("without network access it says where to turn it on", async () => {
    const h = weather({ place: "Lisbon" })
    h.handlers["net.fetch"] = () => fail("scope.missing", "no grant")
    h.mount("m", "renderWeather")
    await h.settle(10)
    expect(rows(h, "m")).toEqual([expect.objectContaining({ title: "Couldn't read the weather", subtitle: "Turn on network access for Weather in Settings > Apps." })])
  })
})

describe("local/showcase-recent-prs", () => {
  const now = Date.now()
  const iso = (hoursAgo: number) => new Date(now - hoursAgo * 3_600_000).toISOString()
  const item = (id: number, hoursAgo: number, extra: Record<string, unknown> = {}) => ({
    id, number: id, title: `PR ${id}`, html_url: `https://github.com/o/r/pull/${id}`, draft: false, state: "open",
    repository_url: "https://api.github.com/repos/o/r", user: { login: "octo" }, updated_at: iso(hoursAgo), ...extra
  })
  function recent(answer: (q: string) => unknown[]) {
    const h = host("recent-prs", { hours: 48 })
    h.handlers["integration.request"] = (p) => ok({ items: answer(decodeURIComponent(String(p.path))) })
    h.handlers["action.run"] = () => ok(null)
    return h
  }

  test("lists open and merged pull requests from every role, once each, newest first", async () => {
    const h = recent((q) =>
      q.includes("author:") ? [item(1, 5), item(2, 1, { state: "closed", pull_request: { merged_at: iso(1) } })] : q.includes("review-requested:") ? [item(3, 2), item(1, 5)] : []
    )
    expect(h.mount("m", "renderRecentPRs")).toBe("")
    await h.settle(10)
    expect(rows(h, "m").map((r) => [r.title, r.symbol])).toEqual([
      ["PR 2", "arrow.triangle.merge"],
      ["PR 3", "eye"],
      ["PR 1", "eye"]
    ])
    expect(String(rows(h, "m")[0]!.subtitle)).toBe("o/r #2 · Merged · 1 h ago")
    const queries = h.calls.filter((c) => c.name === "integration.request").map((c) => decodeURIComponent(String(c.params.path)))
    expect(queries.length).toBe(3)
    expect(queries.every((q) => !q.includes("is:open") && q.includes("updated:>="))).toBe(true)
  })

  test("a click opens the pull request in a browser tab", async () => {
    const h = recent(() => [item(7, 1)])
    h.mount("m", "renderRecentPRs")
    await h.settle(10)
    h.dispatch("m", h.findNode("m", (n) => n.type === "Row" && n.props.title === "PR 7")!, "tap", { gesture: "g1" })
    await h.settle()
    expect(h.calls.find((c) => c.name === "action.run")!.params).toEqual({ id: "openBrowser", args: { url: "https://github.com/o/r/pull/7" } })
  })

  test("no GitHub account and no login says what to do", async () => {
    const h = host("recent-prs")
    h.handlers["integration.request"] = () => fail("integration.not_connected")
    h.mount("m", "renderRecentPRs")
    await h.settle(10)
    expect(String(empty(h, "m")!.message)).toContain("Connect GitHub")
  })
})

describe("local/showcase-agent-pet", () => {
  const chat = (id: string, state: string) => ({ id, title: `Chat ${id}`, state, unread: false, harness: "claude", project: null, cwd: null, workspace: null, machine: null, updated_ms: 0 })
  function pet(agentList: unknown[], chatList: unknown[]) {
    const h = host("agent-pet", { name: "Mochi" })
    const state = { agentList, chatList }
    h.handlers["agent.list"] = () => ok(state.agentList)
    h.handlers["agent_chat.list"] = () => ok({ chats: state.chatList })
    h.handlers["action.run"] = () => ok(null)
    return { h, state }
  }

  test("its mood follows the agents, pushed by events, never polled", async () => {
    const { h, state } = pet([{ id: "a1", state: "idle" }], [])
    expect(h.mount("m", "renderPet")).toBe("")
    await h.settle(10)
    expect(texts(h, "m")).toEqual(["Mochi", "Napping: every agent is idle"])
    expect(h.timers.size).toBe(0)
    state.agentList = [{ id: "a1", state: "working" }]
    h.emit("agent.changed")
    await h.settle(10)
    expect(texts(h, "m")[1]).toBe("Watching 1 agent work")
    state.chatList = [chat("c1", "input")]
    h.emit("agent_chat.changed")
    await h.settle(10)
    expect(texts(h, "m")[1]).toBe("Chat c1 is waiting for you")
  })

  test("a click opens the chat waiting for you", async () => {
    const { h } = pet([], [chat("c9", "input")])
    h.mount("m", "renderPet")
    await h.settle(10)
    h.dispatch("m", h.findNode("m", (n) => n.type === "Panel")!, "tap", { gesture: "g1" })
    await h.settle()
    expect(h.calls.find((c) => c.name === "action.run")!.params).toEqual({ id: "agent.openSessionTab", args: { session: "c9" } })
  })
})

describe("local/showcase-agent-standup", () => {
  const now = Date.now()
  const chat = (id: string, project: string, state: string, hoursAgo: number) => ({
    id, title: `Chat ${id}`, state, unread: false, harness: "claude", project, cwd: null, workspace: null, machine: null, updated_ms: now - hoursAgo * 3_600_000
  })

  test("groups the last day's chats by project and sums them up", async () => {
    const h = host("agent-standup")
    h.handlers["agent_chat.list"] = () => ok({ chats: [chat("1", "api", "idle", 3), chat("2", "web", "input", 1), chat("3", "api", "working", 0.5), chat("4", "docs", "idle", 30)] })
    expect(h.mount("m", "renderStandup")).toBe("")
    await h.settle(10)
    expect(texts(h, "m")).toEqual(["1 chat finished · 1 working · 1 waiting for you", "api", "web"])
    expect(rows(h, "m").map((r) => [r.title, r.subtitle])).toEqual([
      ["Chat 3", "Working · 30 min ago"],
      ["Chat 1", "Finished · 3 h ago"],
      ["Chat 2", "Waiting for you · 1 h ago"]
    ])
  })

  test("a quiet day says so", async () => {
    const h = host("agent-standup")
    h.handlers["agent_chat.list"] = () => ok({ chats: [chat("4", "docs", "idle", 30)] })
    h.mount("m", "renderStandup")
    await h.settle(10)
    expect(empty(h, "m")!.title).toBe("A quiet day")
  })
})

describe("local/showcase-workspace-notes", () => {
  function notes() {
    const h = host("workspace-notes")
    const store = new Map<string, unknown>()
    const state = { focused: "ws_1" }
    h.handlers["workspace.list"] = () => ok(["ws_1", "ws_2"].map((id, index) => ({ id, session_id: "s", name: id === "ws_1" ? "api" : "web", index, focused: id === state.focused })))
    h.handlers["app.storage.get"] = (p) => ok(store.get(p.key) ?? null)
    h.handlers["app.storage.set"] = (p) => (store.set(p.key, p.value), ok(null))
    h.handlers["app.storage.delete"] = (p) => (store.delete(p.key), ok(null))
    return { h, store, state }
  }

  test("adds, ticks and keeps notes per workspace, and follows the focused one", async () => {
    const { h, store, state } = notes()
    expect(h.mount("m", "renderNotes")).toBe("")
    await h.settle(10)
    h.dispatch("m", h.findNode("m", (n) => n.type === "TextField")!, "submit", { text: "Ship the weather sample" })
    await h.settle(10)
    expect(rows(h, "m").map((r) => [r.title, r.symbol])).toEqual([["Ship the weather sample", "circle"]])
    h.dispatch("m", h.findNode("m", (n) => n.type === "Row")!, "tap")
    await h.settle(10)
    expect(rows(h, "m")[0]!.symbol).toBe("checkmark.circle.fill")
    expect((store.get("notes:ws_1") as Array<{ done: boolean }>)[0]!.done).toBe(true)
    state.focused = "ws_2"
    h.emit("workspace.changed")
    await h.settle(10)
    expect(texts(h, "m")[0]).toBe("For web")
    expect(rows(h, "m")).toEqual([])
    // A second window shows the same lists.
    state.focused = "ws_1"
    h.emit("workspace.changed")
    h.mount("w2", "renderNotes")
    await h.settle(10)
    expect(rows(h, "w2").map((r) => r.title)).toEqual(["Ship the weather sample"])
  })
})

describe("local/changes", () => {
  const pull = (n: number, sha: string, extra: Record<string, unknown> = {}) => ({
    id: 900 + n, number: n, title: `PR ${n}`, html_url: `https://github.com/manaflow-ai/cmux/pull/${n}`, state: "open", draft: false, merged_at: null,
    user: { login: "octo" }, head: { sha, ref: `topic-${n}` }, additions: 61331, deletions: 707, requested_reviewers: [], requested_teams: [],
    updated_at: `2026-11-15T0${n % 10}:00:00Z`, ...extra
  })
  /** A fake GitHub with `count` open pull requests in manaflow-ai/cmux; `runs` moves a head's checks. */
  function changes(settings: Record<string, unknown> = {}, count = 2) {
    const runs: Record<string, unknown[]> = {}
    for (let n = 1; n <= count; n++) runs[`s${n}`] = [{ status: "completed", conclusion: "failure" }, { status: "completed", conclusion: "failure" }, { status: "completed", conclusion: "success" }]
    const h = host("changes", settings)
    h.handlers["integration.request"] = (p) => {
      const path = new URL(`https://api.github.com${String(p.path)}`).pathname
      if (path === "/search/issues") return ok({ items: Array.from({ length: count }, (_, i) => ({ number: i + 1, state: "open", repository_url: "https://api.github.com/repos/manaflow-ai/cmux" })) })
      if (path === "/repos/manaflow-ai/cmux/pulls") return ok([{ number: 2, state: "open" }])
      const m = path.match(/\/pulls\/(\d+)(\/reviews)?$/)
      if (m) return ok(m[2] ? [] : pull(Number(m[1]), `s${m[1]}`))
      const c = path.match(/\/commits\/(\w+)\/(check-runs|status)$/)
      if (c) return ok(c[2] === "status" ? { statuses: [] } : { check_runs: runs[c[1]!] ?? [] })
      return fail("validation.invalid", path)
    }
    h.handlers["action.run"] = () => ok(null)
    h.handlers["clipboard.write"] = () => ok(null)
    h.handlers["workspace.create"] = () => ok({ ok: true })
    h.handlers["workspace.list"] = () => ok([{ id: "workspace_1", session_id: "session_1", name: "cmux", index: 0, focused: true }])
    h.handlers["git.status"] = () => ok({ root: "/Users/me/cmux", branch: "topic-2", detached: false, ahead: 0, behind: 0, github_repo: "manaflow-ai/cmux" })
    return { h, runs }
  }

  test("a row reads like the reference: title, repo #N, +lines −lines, checks", async () => {
    const { h } = changes()
    expect(h.mount("m", "renderChanges")).toBe("")
    await h.settle(20)
    const t = texts(h, "m")
    expect(t).toContain("PR 1")
    expect(t).toContain("cmux #1")
    expect(t).toContain("+61,331")
    expect(t).toContain("−707")
    expect(t).toContain("2 failing")
  })

  test("a check that flips redraws only that row's text", async () => {
    const { h, runs } = changes()
    h.mount("m", "renderChanges")
    await h.settle(20)
    runs.s1 = [{ status: "completed", conclusion: "success" }]
    h.eval("cmux.watch.refresh('github.changes', { show: 'mine', limit: 10, include: 'open-and-merged' })")
    await h.settle(20)
    const t = texts(h, "m")
    expect(t).toContain("Checks passed")
    expect(t.filter((x) => x === "2 failing").length).toBe(1)
  })

  test("five rows, then Show more", async () => {
    const { h } = changes({}, 8)
    h.mount("m", "renderChanges")
    await h.settle(30)
    expect(texts(h, "m").filter((x) => /^PR \d$/.test(x)).length).toBe(5)
    const more = h.findNode("m", (n) => n.type === "Button" && n.props.title === "Show more")!
    h.dispatch("m", more, "tap", { gesture: "g1" })
    await h.settle(5)
    expect(texts(h, "m").filter((x) => /^PR \d$/.test(x)).length).toBe(8)
  })

  test("show: branch lists the selected workspace's branch", async () => {
    const { h } = changes({ show: "branch" })
    h.mount("m", "renderChanges")
    await h.settle(30)
    const first = h.calls.find((c) => c.name === "integration.request")!
    expect(String(first.params.path)).toBe("/repos/manaflow-ai/cmux/pulls?head=manaflow-ai%3Atopic-2&state=all&per_page=10")
    expect(h.calls.find((c) => c.name === "git.status")!.params).toEqual({ workspace: "workspace_1", github: true })
    expect(texts(h, "m")).toContain("PR 2")
  })

  test("a click opens the pull request in a cmux browser tab", async () => {
    const { h } = changes()
    h.mount("m", "renderChanges")
    await h.settle(20)
    const row = h.findNode("m", (n) => n.type === "HStack" && String(n.props.help ?? "").startsWith("PR 1\n"))!
    h.dispatch("m", row, "tap", { gesture: "g1" })
    await h.settle()
    expect(h.calls.find((c) => c.name === "action.run")!.params).toEqual({ id: "openBrowser", args: { url: "https://github.com/manaflow-ai/cmux/pull/1" } })
  })

  test("a saved search with no query says what to set", async () => {
    const { h } = changes({ show: "search" })
    h.mount("m", "renderChanges")
    await h.settle(10)
    expect(String(empty(h, "m")!.title)).toBe("No saved search")
    expect(h.calls.some((c) => c.name === "integration.request")).toBe(false)
  })
})
