/** cmux-old.ts: the v0.65.0-style request replay (fake origin, temp git repo for extraction). */
import { afterAll, describe, expect, it } from "bun:test"
import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { extractRequests, newestSpec, normalizePath, PLACEHOLDER, readGaps, replay, statusClass, type Spec } from "../cmux-old.ts"
import { compatProblems } from "../compat.ts"
import { writeReceipt } from "../receipts.ts"

describe("request extraction from a release tag", () => {
  it("reads paths, methods and header names from shipped Swift only", () => {
    const repo = mkdtempSync(join(tmpdir(), "cmuxold-repo-"))
    const git = (...a: Array<string>) => execFileSync("git", ["-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", ...a], { encoding: "utf8" })
    git("init", "-q")
    mkdirSync(join(repo, "Packages/Cloud/Sources"), { recursive: true })
    mkdirSync(join(repo, "Packages/Cloud/Tests"), { recursive: true })
    writeFileSync(
      join(repo, "Packages/Cloud/Sources/VM.swift"),
      [
        'var request = URLRequest(url: base.appendingPathComponent("/api/vm/\\(encodedID)/exec"))',
        'request.httpMethod = "POST"',
        'request.setValue("Bearer \\(token)", forHTTPHeaderField: "Authorization")',
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        'let list = URLRequest(url: URL(string: origin + "/api/vm?limit=20")!)',
      ].join("\n"),
    )
    writeFileSync(join(repo, "Packages/Cloud/Tests/VMTests.swift"), 'let t = "/api/test-only"\n')
    git("add", ".")
    git("commit", "-qm", "r")
    git("tag", "v1.0.0")
    expect(extractRequests(repo, "v1.0.0")).toEqual([
      { method: "GET", path: "/api/vm", headers: [], sources: ["Packages/Cloud/Sources/VM.swift:17"] },
      { method: "POST", path: `/api/vm/${PLACEHOLDER}/exec`, headers: ["Authorization"], sources: ["Packages/Cloud/Sources/VM.swift:1"] },
    ])
  })
  it("normalizes interpolations (nested parentheses too) and drops the query", () => {
    expect(normalizePath("/api/teams/\\(team)/members/\\(user.id(for: x))?expand=1")).toBe(`/api/teams/${PLACEHOLDER}/members/${PLACEHOLDER}`)
    expect([200, 401, 403, 400, 404, 405, 503].map(statusClass)).toEqual(["2xx", "auth", "auth", "4xx-input", "404", "405", "5xx"])
  })
})

describe("replay against an origin", () => {
  const state = { vmGone: false, dropKey: false, postGone: false, recover: 503 }
  const server = Bun.serve({
    port: 0,
    fetch(req) {
      const path = new URL(req.url).pathname
      if (path === "/api/whats-new") return Response.json(state.dropKey ? { announcements: [] } : { announcements: [], visibleEntryIds: [] })
      if (path === "/api/vm" && !state.vmGone) return new Response("unauthorized", { status: 401 })
      if (path === "/api/feedback" && req.method === "POST" && !state.postGone) return new Response("bad", { status: 400 })
      if (path === "/api/billing/recover") return new Response("x", { status: state.recover })
      return new Response("nope", { status: 404 })
    },
  })
  afterAll(() => server.stop(true))
  const origin = `http://127.0.0.1:${server.port}`
  const spec: Spec = {
    schema: 1,
    tag: "v1.0.0",
    sha: "abc",
    origin: "https://cmux.com",
    generated_at: "2026-10-09T00:00:00Z",
    requests: [
      { method: "GET", path: "/api/vm", headers: [], sources: [], expect: "auth" },
      { method: "GET", path: "/api/whats-new", headers: [], sources: [], expect: "2xx", keys: ["announcements", "visibleEntryIds"] },
      { method: "GET", path: "/api/broken-then", headers: [], sources: [], expect: "5xx" },
      { method: "POST", path: "/api/feedback", headers: [], sources: [], expect: undefined },
      { method: "POST", path: "/api/billing/recover", headers: [], sources: [], expect: undefined },
    ],
  }
  const gaps = [{ method: "POST", path: "/api/billing/recover", status: 503, reason: "staging config" }]

  it("passes when every request answers as the release saw it (a recorded gap is a warning)", async () => {
    const r = await replay(spec, origin, gaps)
    expect(r.failures).toEqual([])
    expect(r.warnings.join()).toContain("known staging gap")
    expect(r.lines.some((l) => l.startsWith("SKIP GET /api/broken-then"))).toBe(true)
  })
  it("fails a removed route, a JSON field the release reads, and a POST route that is gone", async () => {
    Object.assign(state, { vmGone: true, dropKey: true, postGone: true })
    const r = await replay(spec, origin, gaps)
    Object.assign(state, { vmGone: false, dropKey: false, postGone: false })
    expect(r.failures.join("\n")).toContain("GET /api/vm: answered 404 (404), v1.0.0 saw auth")
    expect(r.failures.join("\n")).toContain("JSON lacks visibleEntryIds")
    expect(r.failures.join("\n")).toContain("POST /api/feedback: answered 404")
  })
  it("a gap counts only for its exact status", async () => {
    state.recover = 500
    const r = await replay(spec, origin, gaps)
    state.recover = 503
    expect(r.failures.join()).toContain("/api/billing/recover")
  })
})

describe("the committed spec and the release check", () => {
  it("the newest committed spec is v0.65.0 with its commit and requests; every gap has a reason", () => {
    const spec = newestSpec()!
    expect(spec.tag).toBe("v0.65.0")
    expect(spec.sha).toMatch(/^[0-9a-f]{40}$/)
    expect(spec.requests.length).toBeGreaterThan(20)
    for (const g of readGaps()) expect(g.reason.length).toBeGreaterThan(10)
  })
  it("production refuses a smoke of an older release than the latest stable one", () => {
    const dir = mkdtempSync(join(tmpdir(), "cmuxold-receipts-"))
    const now = Date.parse("2026-10-09T12:00:00Z")
    for (const action of ["compat-static", "compat-smoke"] as const) writeReceipt(dir, { action, tree: "compat", target: "production", result: "pass", at: new Date(now - 3600_000).toISOString(), setHash: "k", release: "v0.65.0", by: "t" })
    expect(compatProblems(dir, "k", "production", now, "v0.65.0")).toEqual([])
    expect(compatProblems(dir, "k", "production", now, "v0.66.0").join()).toContain("latest stable release is v0.66.0")
  })
})
