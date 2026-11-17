// The example extensions (examples/extensions/*) in the fake host, and the moved github-prs
// sample's budget: timers and upstream reads before (hand-rolled cmux.timer.every) and after
// (cmux.watch), counted the same way.
import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
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

// The clock (examples/extensions/clock): a New Tab widget, so its recipe's cost promises are tested.
const clockCtx = { contribution: "manaflow-ai/clock#cmux.newtab.widget/1", surface: "newTab" }

function clock(settings: Record<string, unknown>) {
  const host = new FakeHost(load("examples/extensions/clock"), { app: { id: "manaflow-ai/clock", version: "1.0.0" }, apiVersion: "1.0.0", settings })
  // The VM has its own Date (node:vm realm); its clock reads `at`: 13:41:58 local, then a second a tick.
  let at = new Date(2026, 10, 10, 13, 41, 58).getTime()
  host.eval("Date").now = () => at
  const step = (ms = 1000) => {
    at += ms
  }
  return { host, step }
}

describe("manaflow-ai/clock", () => {
  test("one Text update per tick with seconds, none until the minute without", async () => {
    const { host, step } = clock({ showSeconds: true, hourCycle: "24h" })
    expect(host.mount("m", "renderClock", clockCtx)).toBe("")
    await host.settle()
    const texts = () => [...host.tree("m").nodes.values()].map((n) => n.props.text).filter(Boolean)
    expect(texts()).toEqual(["13:41:58", "Tuesday, November 10"])
    // One repeating timer, floored at 1 s by the runtime.
    expect([...host.timers.values()]).toEqual([{ ms: 1000, repeat: true }])
    const [timer] = [...host.timers.keys()]
    const before = host.batches("m").length
    step()
    host.global.__cmuxAppTimer(timer)
    await host.settle()
    const batch = host.lastBatch("m")
    expect(host.batches("m").length).toBe(before + 1)
    expect(batch).toHaveLength(1)
    expect(batch[0]).toMatchObject({ op: "update", props: { text: "13:41:59" } })

    const quiet = clock({ showSeconds: false, hourCycle: "12h" })
    quiet.host.mount("m", "renderClock", clockCtx)
    await quiet.host.settle()
    expect([...quiet.host.tree("m").nodes.values()].map((n) => n.props.text).filter(Boolean)[0]).toBe("1:41 PM")
    const [quietTimer] = [...quiet.host.timers.keys()]
    const quietBefore = quiet.host.batches("m").length
    quiet.step()
    quiet.host.global.__cmuxAppTimer(quietTimer)
    await quiet.host.settle()
    expect(quiet.host.batches("m").length).toBe(quietBefore)
    quiet.step()
    quiet.host.global.__cmuxAppTimer(quietTimer)
    await quiet.host.settle()
    expect(quiet.host.lastBatch("m")).toEqual([expect.objectContaining({ op: "update", props: { text: "1:42 PM" } })])
  })

  test("unmounting stops the tick", async () => {
    const { host } = clock({})
    host.mount("m", "renderClock", clockCtx)
    await host.settle()
    expect(host.timers.size).toBe(1)
    host.global.__cmuxAppUnmount("m")
    await host.settle()
    expect(host.timers.size).toBe(0)
  })
})
