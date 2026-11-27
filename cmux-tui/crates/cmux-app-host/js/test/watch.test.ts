// cmux.watch (ABI.md, Signals): shared reads, refcounting, the poll floor, pushed re-reads,
// stale-while-revalidate, backoff and typed errors, all against the fake host.
import { describe, expect, test } from "bun:test"
import { app, FakeHost } from "./fake-host.ts"

const pr = (id: number, title = `PR ${id}`, extra: Record<string, unknown> = {}) => ({
  id,
  number: id,
  title,
  html_url: `https://github.com/o/r/pull/${id}`,
  draft: false,
  state: "open",
  repository_url: "https://api.github.com/repos/o/r",
  user: { login: "octo" },
  updated_at: `2026-11-09T00:00:${String(60 - id).padStart(2, "0")}Z`,
  ...extra
})

const ok = (value: unknown) => ({ ok: true, body: { value } })
const reads = (host: FakeHost, name: string) => host.calls.filter((c) => c.name === name).length

/** Fires every armed timer once (the fake host keeps fired one-shot timers; drop them first). */
function fireTimers(host: FakeHost) {
  for (const [id] of [...host.timers]) {
    host.timers.delete(id)
    host.global.__cmuxAppTimer(id)
  }
}

/** A section that lists `name` with `params` (JSON) and shows its status; each mount is a reader (`w` is the last). */
const section = (name: string, params = "{}", options = "{}") =>
  app(`
    return { render: () => {
      const w = cmux.watch(${JSON.stringify(name)}, ${params}, ${options})
      globalThis.w = w
      return VStack([
        Text(() => "status=" + w.status()),
        ForEach({ items: () => w.value() ?? [], key: (p) => p.id }, (p) => Row({ title: () => p().title })),
      ])
    } }`)

const twoSections = (name: string, a = "{}", b = "{}") =>
  app(`
    const view = (params) => () => {
      const w = cmux.watch(${JSON.stringify(name)}, params)
      return ForEach({ items: () => w.value() ?? [], key: (p) => p.id }, (p) => Row({ title: () => p().title }))
    }
    return { one: view(${a}), two: view(${b}) }`)

function githubHost(source: string, items: () => unknown[] = () => [pr(1), pr(2)]) {
  const host = new FakeHost(source)
  host.handlers["integration.request"] = () => ok({ items: items() })
  return host
}

describe("cmux.watch: one upstream read per (name, params)", () => {
  test("two sections watching the same source share one read and one timer", async () => {
    const host = githubHost(twoSections("github.pulls", `{ roles: ["author"], limit: 10 }`, `{ limit: 10, roles: ["author"] }`))
    expect(host.mount("a", "one")).toBe("")
    expect(host.mount("b", "two")).toBe("")
    await host.settle()
    expect(reads(host, "integration.request")).toBe(1)
    expect(host.timers.size).toBe(1)
    expect([...host.tree("b").nodes.values()].filter((n) => n.type === "Row").map((n) => n.props.title)).toEqual(["PR 1", "PR 2"])
  })

  test("different params are different entries", async () => {
    const host = githubHost(twoSections("github.pulls", `{ roles: ["author"] }`, `{ roles: ["assignee"] }`))
    host.mount("a", "one")
    host.mount("b", "two")
    await host.settle()
    expect(reads(host, "integration.request")).toBe(2)
  })
})

describe("cmux.watch: refcounting is the stop condition", () => {
  test("the poll timer stops when the last reader unmounts", async () => {
    const host = githubHost(twoSections("github.pulls"))
    host.mount("a", "one")
    host.mount("b", "two")
    await host.settle()
    expect(host.timers.size).toBe(1)
    host.global.__cmuxAppUnmount("a")
    expect(host.timers.size).toBe(1)
    host.global.__cmuxAppUnmount("b")
    expect(host.timers.size).toBe(0)
  })

  test("the push subscription stops when the last reader unmounts", async () => {
    const host = new FakeHost(twoSections("workspace.list"))
    host.handlers["workspace.list"] = () => ok([{ id: "w1", title: "one" }])
    host.mount("a", "one")
    host.mount("b", "two")
    await host.settle()
    expect([...host.subscriptions.values()].map((s) => s.stream)).toEqual(["workspace.changed"])
    host.global.__cmuxAppUnmount("a")
    expect(host.subscriptions.size).toBe(1)
    host.global.__cmuxAppUnmount("b")
    expect(host.subscriptions.size).toBe(0)
    expect(host.timers.size).toBe(0)
  })

  test("a remount within staleAfterSeconds shows the cached value without a read", async () => {
    const host = githubHost(section("github.pulls"))
    host.mount("a", "render")
    await host.settle()
    host.global.__cmuxAppUnmount("a")
    host.mount("a2", "render")
    await host.settle()
    expect(reads(host, "integration.request")).toBe(2) // author + review-requested, once
    expect([...host.tree("a2").nodes.values()].some((n) => n.props.text === "status=fresh")).toBe(true)
  })

  test("a pushed source re-reads on remount (it missed its events)", async () => {
    const host = new FakeHost(section("workspace.list"))
    host.handlers["workspace.list"] = () => ok([{ id: "w1", title: "one" }])
    host.mount("a", "render")
    await host.settle()
    host.global.__cmuxAppUnmount("a")
    host.mount("a2", "render")
    await host.settle()
    expect(reads(host, "workspace.list")).toBe(2)
  })
})

describe("cmux.watch: params that follow a setting", () => {
  test("the reader moves to the new entry and the old one stops", async () => {
    const host = new FakeHost(
      app(`
        const [role, setRole] = signal("author")
        globalThis.setRole = setRole
        return { render: () => {
          const w = cmux.watch("github.pulls", () => ({ roles: [role()] }))
          globalThis.w = w
          return ForEach({ items: () => w.value() ?? [], key: (p) => p.id }, (p) => Row({ title: () => p().title }))
        } }`)
    )
    host.handlers["integration.request"] = (p) => ok({ items: String(p.path).includes("assignee") ? [pr(9, "Assigned")] : [pr(1)] })
    host.mount("m", "render")
    await host.settle()
    expect(host.eval("w.value().map((p) => p.title)")).toEqual(["PR 1"])
    host.eval(`setRole("assignee")`)
    await host.settle()
    expect(reads(host, "integration.request")).toBe(2)
    expect(host.eval("w.value().map((p) => p.title)")).toEqual(["Assigned"])
    expect(host.timers.size).toBe(1)
    host.global.__cmuxAppUnmount("m")
    expect(host.timers.size).toBe(0)
  })
})

describe("cmux.watch: polling budget", () => {
  test("polls every staleAfterSeconds and never faster than pollFloorSeconds", async () => {
    const host = githubHost(section("github.pulls", "{}", "{ everySeconds: 1 }"))
    host.mount("m", "render")
    await host.settle()
    expect([...host.timers.values()]).toEqual([{ ms: 60_000, repeat: false }])
    fireTimers(host)
    await host.settle()
    expect(reads(host, "integration.request")).toBe(4)
    expect([...host.timers.values()]).toEqual([{ ms: 60_000, repeat: false }])
  })

  test("without everySeconds it polls at staleAfterSeconds", async () => {
    const host = githubHost(section("github.pulls"))
    host.mount("m", "render")
    await host.settle()
    expect([...host.timers.values()]).toEqual([{ ms: 300_000, repeat: false }])
  })

  test("a pushed source arms no poll timer", async () => {
    const host = new FakeHost(section("workspace.list"))
    host.handlers["workspace.list"] = () => ok([])
    host.mount("m", "render")
    await host.settle()
    expect(host.timers.size).toBe(0)
  })
})

describe("cmux.watch: pushed re-reads are coalesced", () => {
  test("a burst of events is one read", async () => {
    const host = new FakeHost(section("workspace.list"))
    host.handlers["workspace.list"] = () => ok([{ id: "w1", title: "one" }])
    host.mount("m", "render")
    await host.settle()
    for (let i = 0; i < 5; i++) host.emit("workspace.changed")
    await host.settle()
    expect(reads(host, "workspace.list")).toBe(2)
  })

  test("events during a read in flight queue exactly one more read", async () => {
    const host = new FakeHost(section("workspace.list"))
    const pending: Array<() => void> = []
    host.handlers["workspace.list"] = () => new Promise((resolve) => pending.push(() => resolve(ok([{ id: "w1", title: "one" }]))))
    host.mount("m", "render")
    await host.settle()
    pending.shift()!()
    await host.settle()
    host.emit("workspace.changed")
    await host.settle()
    expect(reads(host, "workspace.list")).toBe(2)
    host.emit("workspace.changed")
    host.emit("workspace.changed")
    await host.settle()
    pending.shift()!()
    await host.settle()
    pending.shift()?.()
    await host.settle()
    expect(reads(host, "workspace.list")).toBe(3)
  })
})

describe("cmux.watch: stale-while-revalidate", () => {
  test("the old value stays with status stale during a re-read and after a failed one", async () => {
    const host = new FakeHost(section("workspace.list"))
    let answer: (() => unknown) | null = null
    host.handlers["workspace.list"] = () => ok([{ id: "w1", title: "one" }])
    host.mount("m", "render")
    await host.settle()
    expect(host.eval("w().status")).toBe("fresh")
    host.handlers["workspace.list"] = () => new Promise((resolve) => (answer = () => resolve({ ok: false, body: { code: "operation.failed", message: "daemon busy", retryable: true } })))
    host.emit("workspace.changed")
    await host.settle()
    expect(host.eval("[w().status, w().value.length]")).toEqual(["stale", 1])
    answer!()
    await host.settle()
    expect(host.eval("[w().status, w().value[0].title, w().error.code]")).toEqual(["stale", "one", "operation.failed"])
    const titles = [...host.tree("m").nodes.values()].filter((n) => n.type === "Row").map((n) => n.props.title)
    expect(titles).toEqual(["one"])
  })

  test("a failed first read is status error with no value", async () => {
    const host = new FakeHost(section("workspace.list"))
    host.handlers["workspace.list"] = () => ({ ok: false, body: { code: "operation.failed", message: "nope" } })
    host.mount("m", "render")
    await host.settle()
    expect(host.eval("[w().status, w().value, w().error.code]")).toEqual(["error", undefined, "operation.failed"])
  })
})

describe("cmux.watch: errors back off", () => {
  test("retries start at the floor and double, to at most 15 minutes", async () => {
    const host = new FakeHost(section("github.pulls", `{ login: "octo" }`))
    host.handlers["integration.request"] = () => ({ ok: false, body: { code: "integration.not_connected", message: "no" } })
    host.handlers["net.fetch"] = () => ok({ status: 503, body: "" })
    host.mount("m", "render")
    await host.settle()
    const delays: number[] = []
    for (let i = 0; i < 6; i++) {
      delays.push(...[...host.timers.values()].map((t) => t.ms))
      fireTimers(host)
      await host.settle()
    }
    expect(delays).toEqual([60_000, 120_000, 240_000, 480_000, 900_000, 900_000])
  })

  test("a refused read is not retried until refresh", async () => {
    const host = new FakeHost(section("github.pulls"))
    host.handlers["integration.request"] = () => ({ ok: false, body: { code: "scope.missing", message: "no grant" } })
    host.mount("m", "render")
    await host.settle()
    expect(host.eval("[w().status, w().error.code]")).toEqual(["error", "scope.missing"])
    expect(host.timers.size).toBe(0)
  })
})

describe("cmux.watch: typed errors", () => {
  test("an unknown source throws signal.unknown", () => {
    const host = new FakeHost(app(`return { render: () => { cmux.watch("github.nope"); return Text("x") } }`))
    expect(host.mount("m", "render")).toContain("no signal source named github.nope")
    expect(host.eval(`(() => { try { cmux.watch("nope") } catch (e) { return [e.name, e.code] } })()`)).toEqual(["CmuxError", "signal.unknown"])
  })

  test("params the source does not take throw signal.params", () => {
    const host = new FakeHost(app(`return {}`))
    expect(host.eval(`(() => { try { cmux.watch("github.pulls", { roles: ["boss"] }) } catch (e) { return e.code } })()`)).toBe("signal.params")
    expect(host.eval(`(() => { try { cmux.watch("workspace.list", { colour: 1 }) } catch (e) { return e.code } })()`)).toBe("signal.params")
  })

  test("a missing scope is the watch's error, with no call", async () => {
    const host = new FakeHost(section("workspace.list"), { app: { id: "local/test", version: "1.0.0" }, ops: ["agent.list"] })
    host.mount("m", "render")
    await host.settle()
    expect(host.eval("[w().status, w().error.code, w().error.details.scopes]")).toEqual(["error", "scope.missing", ["workspace:read"]])
    expect(reads(host, "workspace.list")).toBe(0)
  })

  test("github.pulls without a connection or a login says so", async () => {
    const host = new FakeHost(section("github.pulls"))
    host.handlers["integration.request"] = () => ({ ok: false, body: { code: "integration.not_connected", message: "no" } })
    host.mount("m", "render")
    await host.settle()
    expect(host.eval("[w().status, w().error.code]")).toEqual(["error", "integration.unavailable"])
  })
})

describe("cmux.watch: github.pulls reader", () => {
  test("merges roles by id, keeps why each PR is listed, newest first", async () => {
    const host = new FakeHost(section("github.pulls"))
    host.handlers["integration.request"] = (p) => ok({ items: String(p.path).includes("review-requested") ? [pr(2), pr(3, "Review me")] : [pr(1), pr(2)] })
    host.mount("m", "render")
    await host.settle()
    expect(host.eval("w().value.map((p) => [p.id, p.roles.join('+')])")).toEqual([[1, "author"], [2, "author+review-requested"], [3, "review-requested"]])
    expect(host.calls.filter((c) => c.name === "integration.request").map((c) => decodeURIComponent(c.params.path))).toEqual([
      "/search/issues?q=is:pr is:open author:@me&per_page=30",
      "/search/issues?q=is:pr is:open review-requested:@me&per_page=30"
    ])
  })

  test("falls back to the public search for params.login", async () => {
    const host = new FakeHost(section("github.pulls", `{ login: "octo", roles: ["author"] }`))
    host.handlers["integration.request"] = () => ({ ok: false, body: { code: "scope.missing", message: "no" } })
    host.handlers["net.fetch"] = () => ok({ status: 200, body: JSON.stringify({ items: [pr(7)] }) })
    host.mount("m", "render")
    await host.settle()
    expect(host.eval("w().value.map((p) => p.url)")).toEqual(["https://github.com/o/r/pull/7"])
    expect(decodeURIComponent(host.calls.find((c) => c.name === "net.fetch")!.params.url)).toContain("author:octo")
  })
})

describe("cmux.watch: refresh and scene cost", () => {
  test("refresh re-reads now and coalesces with a read in flight", async () => {
    const host = githubHost(section("github.pulls", `{ roles: ["author"] }`))
    host.mount("m", "render")
    await host.settle()
    host.eval("w.refresh(); w.refresh(); cmux.watch.refresh('github.pulls', { roles: ['author'] })")
    await host.settle()
    expect(reads(host, "integration.request")).toBe(3) // mount, then one refresh plus one queued behind it
  })

  test("a one-row change in a 30-row list is one update op; an unchanged poll is none", async () => {
    let items = Array.from({ length: 30 }, (_, i) => pr(i + 1))
    const host = githubHost(section("github.pulls", `{ roles: ["author"] }`), () => items)
    host.mount("m", "render")
    await host.settle()
    const before = host.batches("m").length
    fireTimers(host)
    await host.settle()
    const unchanged = host.batches("m").slice(before).flat()
    // The status Text goes stale and back to fresh; no row is touched.
    expect(unchanged.every((op) => op.op === "update" && Object.keys(op.props!).join() === "text")).toBe(true)
    items = items.map((p) => (p.id === 17 ? { ...p, title: "Renamed" } : p))
    const mark = host.batches("m").length
    fireTimers(host)
    await host.settle()
    const rowOps = host.batches("m").slice(mark).flat().filter((op) => !(op.op === "update" && "text" in op.props!))
    expect(rowOps).toEqual([{ op: "update", id: expect.any(String), props: { title: "Renamed" } }])
  })
})
