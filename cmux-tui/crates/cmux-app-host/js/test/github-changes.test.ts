// cmux.watch("github.changes"): the Changes list's source. A fake GitHub answers each GET by path,
// through the gateway (integration.request) or the public API (net.fetch, with ETags).
import { describe, expect, test } from "bun:test"
import { app, FakeHost } from "./fake-host.ts"

const ok = (value: unknown) => ({ ok: true, body: { value } })

const section = (params: string) =>
  app(`
    return { render: () => {
      const w = cmux.watch("github.changes", ${params})
      globalThis.w = w
      return ForEach({ items: () => w.value() ?? [], key: (p) => p.id }, (p) => Row({ title: () => p().title }))
    } }`)

/** A fake GitHub: two open PRs and one merged one in o/r. Change `world` to move checks. */
function github() {
  const world = {
    runs: { a1: [{ status: "completed", conclusion: "success" }, { status: "completed", conclusion: "failure" }], b2: [{ status: "in_progress", conclusion: null }] } as Record<string, unknown[]>,
    statuses: { a1: [{ state: "success" }], b2: [] } as Record<string, unknown[]>,
    reviews: { 1: [{ user: { login: "x" }, state: "APPROVED" }], 2: [{ user: { login: "y" }, state: "COMMENTED" }] } as Record<number, unknown[]>
  }
  const pull = (n: number, sha: string, extra: Record<string, unknown> = {}) => ({
    id: 100 + n, number: n, title: `PR ${n}`, html_url: `https://github.com/o/r/pull/${n}`, state: "open", draft: false, merged_at: null,
    user: { login: "octo" }, head: { sha, ref: `topic-${n}` }, additions: 61331 * n, deletions: 707 * n, requested_reviewers: [], requested_teams: [],
    updated_at: `2026-11-15T0${n}:00:00Z`, ...extra
  })
  const answer = (path: string): unknown => {
    const u = new URL(`https://api.github.com${path}`)
    const p = u.pathname
    if (p === "/search/issues") return { items: [1, 2, 3].map((n) => ({ number: n, state: n === 3 ? "closed" : "open", pull_request: { merged_at: n === 3 ? "2026-11-15T00:00:00Z" : null }, repository_url: "https://api.github.com/repos/o/r" })).concat([{ number: 4, state: "closed", pull_request: { merged_at: null }, repository_url: "https://api.github.com/repos/o/r" }]) }
    if (p === "/repos/o/r/pulls") return [{ number: 2, state: "open" }, { number: 5, state: "closed", merged_at: null }]
    const m = p.match(/^\/repos\/o\/r\/pulls\/(\d+)(\/reviews)?$/)
    if (m) {
      const n = Number(m[1])
      if (m[2]) return world.reviews[n] ?? []
      return n === 3 ? pull(3, "c3", { state: "closed", merged_at: "2026-11-15T00:00:00Z" }) : pull(n, n === 1 ? "a1" : "b2")
    }
    const c = p.match(/^\/repos\/o\/r\/commits\/(\w+)\/(check-runs|status)$/)
    if (c) return c[2] === "status" ? { statuses: world.statuses[c[1]!] ?? [] } : { check_runs: world.runs[c[1]!] ?? [] }
    throw new Error(`unexpected ${path}`)
  }
  return { world, answer }
}

describe("cmux.watch: github.changes", () => {
  test("rows carry lines, the check rollup and the review decision, merged ones without checks", async () => {
    const { answer } = github()
    const host = new FakeHost(section(`{ show: "mine", include: "open-and-merged" }`))
    host.handlers["integration.request"] = (p) => ok(answer(String(p.path)))
    host.mount("m", "render")
    await host.settle(12)
    const rows = host.eval("w().value") as Array<Record<string, any>>
    expect(rows.map((r) => [r.number, r.state, r.additions, r.deletions, r.checks.state, r.checks.failing, r.review])).toEqual([
      [3, "merged", 183993, 2121, "none", 0, "none"],
      [2, "open", 122662, 1414, "pending", 0, "commented"],
      [1, "open", 61331, 707, "failing", 1, "approved"]
    ])
    const paths = host.calls.filter((c) => c.name === "integration.request").map((c) => decodeURIComponent(String(c.params.path)))
    expect(paths[0]).toBe("/search/issues?q=is:pr author:@me&sort=updated&order=desc&per_page=10")
    // The merged one reads only itself.
    expect(paths.filter((p) => p.includes("/pulls/3") || p.includes("c3"))).toEqual(["/repos/o/r/pulls/3"])
    // A closed, unmerged one is dropped from the list before any read of its own.
    expect(paths.some((p) => p.includes("/pulls/4"))).toBe(false)
    expect(host.calls.some((c) => c.name === "net.fetch")).toBe(false)
  })

  test("a row whose checks GitHub refuses keeps the row; a busy gateway is retried on the gateway, never the public API", async () => {
    const { answer } = github()
    const host = new FakeHost(section(`{ show: "mine" }`))
    host.handlers["integration.request"] = (p) =>
      String(p.path).includes("/commits/a1/check-runs")
        ? { ok: false, body: { code: "integration.http", message: "GitHub answered 403", details: { status: 403 } } }
        : ok(answer(String(p.path)))
    host.mount("m", "render")
    await host.settle(12)
    const rows = host.eval("w().value") as Array<Record<string, any>>
    expect(rows.map((r) => [r.number, r.checks.state])).toEqual([[2, "pending"], [1, "passing"]])

    const busy = new FakeHost(section(`{ show: "mine" }`))
    busy.handlers["integration.request"] = () => ({ ok: false, body: { code: "app.limit", message: "8 in flight", retryable: true } })
    busy.mount("m", "render")
    await busy.settle()
    expect(busy.calls.some((c) => c.name === "net.fetch")).toBe(false)
  })

  test("show: branch reads the repository's pulls for that head, no search", async () => {
    const { answer } = github()
    const host = new FakeHost(section(`{ show: "branch", repo: "o/r", branch: "feat/x" }`))
    host.handlers["integration.request"] = (p) => ok(answer(String(p.path)))
    host.mount("m", "render")
    await host.settle(12)
    expect((host.eval("w().value") as Array<{ number: number }>).map((r) => r.number)).toEqual([2])
    const first = String(host.calls.find((c) => c.name === "integration.request")!.params.path)
    expect(first).toBe("/repos/o/r/pulls?head=o%3Afeat%2Fx&state=open&per_page=10")
  })

  test("mentions, review requests and a saved search build their queries", async () => {
    for (const [params, q] of [
      [`{ show: "mentions" }`, "is:pr is:open mentions:@me"],
      [`{ show: "review-requested", repo: "o/r" }`, "is:pr is:open repo:o/r review-requested:@me"],
      [`{ show: "search", query: "is:pr label:bug repo:o/r" }`, "is:pr is:open label:bug repo:o/r"]
    ] as const) {
      const host = new FakeHost(section(params))
      host.handlers["integration.request"] = () => ok({ items: [] })
      host.mount("m", "render")
      await host.settle()
      expect(decodeURIComponent(String(host.calls[0]!.params.path))).toBe(`/search/issues?q=${q}&sort=updated&order=desc&per_page=10`)
    }
  })

  test("a check that flips shows on the next read", async () => {
    const { world, answer } = github()
    const host = new FakeHost(section(`{ show: "mine" }`))
    host.handlers["integration.request"] = (p) => ok(answer(String(p.path)))
    host.mount("m", "render")
    await host.settle(12)
    expect(host.eval("w().value.find((r) => r.number === 2).checks.state")).toBe("pending")
    world.runs.b2 = [{ status: "completed", conclusion: "success" }]
    host.eval("w.refresh()")
    await host.settle(12)
    expect(host.eval("w().value.find((r) => r.number === 2).checks")).toEqual({ state: "passing", failing: 0, pending: 0, passing: 1 })
  })

  test("without a sign-in, a saved search on public repositories reads the public API with ETags", async () => {
    const { answer } = github()
    const host = new FakeHost(section(`{ show: "search", query: "repo:o/r" }`))
    host.handlers["integration.request"] = () => ({ ok: false, body: { code: "integration.unavailable", message: "no gh" } })
    const sent: Array<{ url: string; inm?: string }> = []
    host.handlers["net.fetch"] = (p) => {
      const url = String(p.url)
      const inm = (p.headers as Record<string, string>)["If-None-Match"]
      sent.push({ url, inm })
      const etag = `"${url.length}"`
      if (inm === etag) return ok({ status: 304, headers: { etag }, body: "" })
      return ok({ status: 200, headers: { ETag: etag }, body: JSON.stringify(answer(url.replace("https://api.github.com", ""))) })
    }
    host.mount("m", "render")
    await host.settle(12)
    expect((host.eval("w().value") as unknown[]).length).toBe(2)
    // The list, then each open row's pull request and checks: no status or reviews on the public budget.
    expect(sent.map((s) => new URL(s.url).pathname).sort()).toEqual([
      "/repos/o/r/commits/a1/check-runs", "/repos/o/r/commits/b2/check-runs", "/repos/o/r/pulls/1", "/repos/o/r/pulls/2", "/search/issues"
    ])
    expect(sent.every((s) => s.inm === undefined)).toBe(true)
    // Read again at once: every path is within its age, so nothing goes out (a 304 costs there too).
    host.eval("w.refresh()")
    await host.settle(12)
    expect(sent.length).toBe(5)
    // Sixteen minutes on: the same paths, each conditional.
    host.eval("{ const t0 = Date.now(); Date.now = () => t0 + 16 * 60_000 }")
    host.eval("w.refresh()")
    await host.settle(12)
    const second = sent.slice(5)
    expect(second.length).toBe(5)
    expect(second.every((s) => s.inm !== undefined)).toBe(true)
    expect((host.eval("w().value") as unknown[]).length).toBe(2)
  })

  test("the person's own lists need a sign-in or a login, and say so", async () => {
    const host = new FakeHost(section(`{ show: "mine" }`))
    host.handlers["integration.request"] = () => ({ ok: false, body: { code: "integration.unavailable", message: "no gh" } })
    host.mount("m", "render")
    await host.settle()
    expect(host.eval("w().status")).toBe("error")
    expect(host.eval("w().error.code")).toBe("integration.unavailable")
    expect(host.calls.some((c) => c.name === "net.fetch")).toBe(false)
  })

  test("a sandboxed install says to turn off Run sandboxed, not to sign in", async () => {
    const sandboxed = { ok: false, body: { code: "scope.missing", message: "the app runs sandboxed: no network", retryable: false } }
    const host = new FakeHost(section(`{ show: "mine", login: "octo" }`))
    host.handlers["integration.request"] = () => sandboxed
    host.handlers["net.fetch"] = () => sandboxed
    host.mount("m", "render")
    await host.settle()
    expect(host.eval("w().status")).toBe("error")
    expect(host.eval("w().error.code")).toBe("scope.missing")
    expect(host.eval("w().error.details.sandboxed")).toBe(true)
    expect(String(host.eval("w().error.message"))).toContain("Run sandboxed")
  })

  test("the public limit (403) says it resets and that a sign-in avoids it", async () => {
    const host = new FakeHost(section(`{ show: "mine", login: "octo" }`))
    host.handlers["integration.request"] = () => ({ ok: false, body: { code: "integration.unavailable", message: "no gh" } })
    host.handlers["net.fetch"] = () => ok({ status: 403, headers: {}, body: "{}" })
    host.mount("m", "render")
    await host.settle()
    expect(host.eval("w().status")).toBe("error")
    expect(host.eval("w().error.details.limit")).toBe("public")
    expect(String(host.eval("w().error.message"))).toContain("Sign in to GitHub")
  })

  test("params the schema refuses throw at the watch", () => {
    const host = new FakeHost(section(`{}`))
    expect(host.eval(`(() => { try { cmux.watch("github.changes", { show: "everything" }) } catch (e) { return e.code } })()`)).toBe("signal.params")
    expect(host.eval(`(() => { try { cmux.watch("github.changes", { repo: "not a repo" }) } catch (e) { return e.code } })()`)).toBe("signal.params")
  })
})
