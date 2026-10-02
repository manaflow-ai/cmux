import { describe, expect, test } from "bun:test"
import { fetchGithub, githubQueries, loadChecks, mergeGithub, parseSearch, searchPath, summarizeChecks } from "../src/github.ts"
import { githubData } from "./fixtures.ts"

const NOW = Date.UTC(2026, 9, 2, 12, 0)
const ALL = { reviewRequests: true, failingChecks: true, mentions: true, mentionDays: 7 }
const err = (code: string) => Object.assign(new Error(code), { code })

describe("github", () => {
  test("queries per enabled kind; mentions are bounded by date", () => {
    expect(githubQueries(ALL, NOW).map((q) => q.kind)).toEqual(["reviewRequested", "checksFailing", "mention"])
    expect(githubQueries(ALL, NOW)[2]!.query).toContain("updated:>=2026-09-25")
    expect(githubQueries({ ...ALL, mentions: false, reviewRequests: false }, NOW).map((q) => q.query)).toEqual(["is:open is:pr author:@me status:failure archived:false"])
    expect(searchPath("is:pr author:@me")).toBe("/search/issues?q=is%3Apr%20author%3A%40me&sort=updated&order=desc&per_page=30")
  })

  test("parses search items and keeps the more urgent reason per pull request", () => {
    const g = githubData(NOW)
    const review = parseSearch("reviewRequested", g.review)
    expect(review[0]).toMatchObject({ id: "github:example-org/payments#412", detail: "payments #412", author: "river", mine: false, url: "https://github.com/example-org/payments/pull/412" })
    const mention = parseSearch("mention", g.review)
    expect(mergeGithub([mention, review]).map((i) => i.kind)).toEqual(["reviewRequested"])
    expect(parseSearch("mention", { items: [{ title: "no repo" }] })).toEqual([])
    expect(parseSearch("mention", "nope")).toEqual([])
  })

  test("missing scope and missing gateway are states, not errors", async () => {
    expect(await fetchGithub(() => Promise.reject(err("scope.missing")), ALL, NOW)).toEqual({ status: "notGranted", items: [], errors: [] })
    expect(await fetchGithub(() => Promise.reject(err("operation.unsupported")), ALL, NOW)).toEqual({ status: "unavailable", items: [], errors: [] })
    const g = githubData(NOW)
    const partial = await fetchGithub((path) => (path.includes("mentions") ? Promise.reject(new Error("GitHub 502")) : Promise.resolve(path.includes("review") ? g.review : g.failing)), ALL, NOW)
    expect(partial.status).toBe("partial")
    expect(partial.errors).toEqual(["GitHub 502"])
    expect(partial.items.map((i) => i.kind).sort()).toEqual(["checksFailing", "reviewRequested"])
    expect((await fetchGithub(() => Promise.reject(new Error("boom")), ALL, NOW)).status).toBe("error")
  })

  test("check summary: failure outranks pending; empty is neutral", async () => {
    const g = githubData(NOW)
    const calls: string[] = []
    const summary = await loadChecks((path) => (calls.push(path), Promise.resolve(path.includes("check-runs") ? g.checks : g.pull)), "example-org/api-server", 88)
    expect(calls).toEqual(["/repos/example-org/api-server/pulls/88", "/repos/example-org/api-server/commits/4f2a9c1/check-runs?per_page=100"])
    expect(summary).toEqual({ state: "fail", failed: ["unit tests", "integration"], counts: { fail: 2, pending: 0, pass: 2, cancel: 0, skip: 0 } })
    expect(summarizeChecks([{ status: "in_progress" }, { status: "completed", conclusion: "success" }]).state).toBe("pending")
    expect(summarizeChecks([{ status: "completed", conclusion: "skipped" }]).state).toBe("neutral")
    expect(summarizeChecks([]).state).toBe("neutral")
    expect(summarizeChecks([{ status: "completed", conclusion: "cancelled" }, { status: "completed", conclusion: "success" }]).state).toBe("neutral")
  })
})
