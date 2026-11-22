import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { toAgentResult } from "../src/agent.ts"
import { runSearch, type SearchRequest, type SearchResponse } from "../src/engine.ts"
import { parseQuery, SOURCES } from "../src/query.ts"

const fixture = (name: string) => JSON.parse(readFileSync(join(import.meta.dir, "../preview", name), "utf8")) as { ops: Record<string, any> }

/** A host answering from a preview fixture: plain values, `$error`, `$sequence`. */
export function fixtureCall(ops: Record<string, any>, calls: Array<{ op: string; params: any }> = []) {
  const seq = new Map<string, number>()
  return async (op: string, params: unknown) => {
    calls.push({ op, params })
    if (!(op in ops)) throw Object.assign(new Error(`no ${op}`), { code: "operation.unsupported" })
    let v = ops[op]
    if (v && typeof v === "object" && "$sequence" in v) {
      const i = seq.get(op) ?? 0
      seq.set(op, i + 1)
      v = v.$sequence[Math.min(i, v.$sequence.length - 1)]
    }
    if (v && typeof v === "object" && "$error" in v) throw Object.assign(new Error(v.$error.message), { code: v.$error.code })
    return v
  }
}

const request = (raw: string, over: Partial<SearchRequest> = {}): SearchRequest => ({
  query: parseQuery(raw),
  sources: SOURCES,
  scope: "all",
  density: "full",
  limit: 50,
  searchId: "t",
  opened: {},
  selfId: "cmux/search",
  nowMs: 1_800_000_000_000,
  ...over
})

describe("engine", () => {
  test("every source answers and results group in source order", async () => {
    const r = await runSearch(request("auth"), fixtureCall(fixture("full.json").ops))
    expect(r.groups.map((g) => g.source)).toEqual(["workspaces", "terminals", "browser", "apps", "files"])
    expect(r.unavailable).toEqual([])
    // The named tab in the current workspace beats an equally good name elsewhere.
    expect(r.top!.title).toBe("auth tests")
    expect(r.top!.target).toEqual({ op: "tab.focus", params: { tab: "tab_2", workspace: "workspace_api" } })
    const text = r.ranked.find((h) => h.id === "terminalText:terminal_1:row_8812")!
    expect(text.preview).toEqual({ before: "POST /v1/", match: "auth", after: "/refresh 401 Unauthorized (token expired) 12ms" })
    expect(text.target).toMatchObject({ op: "tab.focus", reveal: { terminal: "terminal_1", row: "row_8812" } })
    expect(r.groups.find((g) => g.source === "files")!.truncated).toBe(true)
  })

  test("proposed ops get the query, flags, roots and a per-source search id", async () => {
    const calls: Array<{ op: string; params: any }> = []
    await runSearch(request("/Auth\\w+/"), fixtureCall(fixture("full.json").ops, calls))
    const fs = calls.find((c) => c.op === "fs.search")!.params
    expect(fs).toMatchObject({ query: "Auth\\w+", regex: true, case_sensitive: true, mode: "both", search_id: "t:files" })
    expect(fs.roots.sort()).toEqual(["/Users/dev/src/api-server", "/Users/dev/src/web-app"])
    expect(calls.find((c) => c.op === "terminal.search")!.params).toMatchObject({ include_closed: true, search_id: "t:terminals" })
  })

  test("without the proposed ops: names, visible screens, and a reason per missing source", async () => {
    const r = await runSearch(request("auth"), fixtureCall(fixture("today.json").ops))
    expect(r.unavailable.map((u) => `${u.source}:${u.op}:${u.code}`).sort()).toEqual([
      "apps:search.providers.query:operation.unsupported",
      "browser:browser.history.search:operation.unsupported",
      "files:fs.search:operation.unsupported",
      "terminals:terminal.search:operation.unsupported"
    ])
    const screen = r.ranked.filter((h) => h.screenOnly)
    expect(screen.length).toBeGreaterThan(0)
    expect(screen[0]!.preview!.match.toLowerCase()).toBe("auth")
    expect(r.ranked.some((h) => h.kind === "workspace")).toBe(true)
  })

  test("this-workspace scope keeps only the current workspace and skips global sources", async () => {
    const calls: Array<{ op: string; params: any }> = []
    const r = await runSearch(request("auth", { scope: "workspace" }), fixtureCall(fixture("full.json").ops, calls))
    expect(r.ranked.every((h) => h.workspaceId === "workspace_api" || h.source === "files")).toBe(true)
    expect(calls.some((c) => c.op === "browser.history.search" || c.op === "search.providers.query")).toBe(false)
    expect(calls.find((c) => c.op === "terminal.search")!.params.terminals.sort()).toEqual(["terminal_1", "terminal_2"])
    expect(calls.find((c) => c.op === "fs.search")!.params.roots).toEqual(["/Users/dev/src/api-server"])
  })

  test("partial results arrive before the slow sources finish", async () => {
    const ops = fixture("full.json").ops
    let release!: () => void
    const gate = new Promise<void>((r) => (release = r))
    const base = fixtureCall(ops)
    const partials: SearchResponse[] = []
    const done = runSearch(request("auth"), async (op, p) => (op === "fs.search" ? gate.then(() => base(op, p)) : base(op, p)), (r) => partials.push(r))
    await new Promise((r) => setTimeout(r, 5))
    expect(partials.at(-1)!.pending).toEqual(["files"])
    expect(partials.at(-1)!.ranked.length).toBeGreaterThan(0)
    release()
    expect((await done).pending).toEqual([])
  })

  test("an invalid regex and an empty query search nothing", async () => {
    const calls: Array<{ op: string; params: any }> = []
    const call = fixtureCall(fixture("full.json").ops, calls)
    expect((await runSearch(request("/(/"), call)).unavailable[0]!.code).toBe("query.invalid")
    expect((await runSearch(request("   "), call)).ranked).toEqual([])
    expect(calls).toEqual([])
  })

  test("the agent result names every field and the op that opens each hit", async () => {
    const r = toAgentResult(await runSearch(request("auth"), fixtureCall(fixture("full.json").ops)), 3)
    expect(r.results).toHaveLength(3)
    expect(r.truncated).toBe(true)
    expect(Object.keys(r.results[0]!).sort()).toEqual(["id", "kind", "location", "match", "open", "preview", "score", "source", "title", "updated_at_ms", "workspace"])
    expect(r.results[0]).toMatchObject({ title: "auth tests", match: "auth", open: { op: "tab.focus" } })
  })
})
