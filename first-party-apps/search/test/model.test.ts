import { describe, expect, test } from "bun:test"
import { compile, fuzzy, nameSegments, snippet } from "../src/match.ts"
import { activeHit, group, groupLimit, rank, recencyBonus, type Hit } from "../src/model.ts"
import { effectiveSources, parseQuery, SOURCES } from "../src/query.ts"
import { markOpened, pushRecent } from "../src/recents.ts"
import { distinctRoots } from "../src/sources/local.ts"

describe("query syntax", () => {
  test("plain text searches every source with smart case", () => {
    const q = parseQuery("  auth token ")
    expect(q).toMatchObject({ text: "auth token", sources: null, regex: false, exact: false, caseSensitive: false, scope: null, error: null })
    expect(parseQuery("AuthToken").caseSensitive).toBe(true)
  })

  test("prefixes narrow sources and combine", () => {
    expect(parseQuery("t: npm ERR").sources).toEqual(["terminals"])
    expect(parseQuery("t:f: config").sources).toEqual(["terminals", "files"])
    expect(parseQuery("f:config.ts").text).toBe("config.ts")
    // A prefix only counts at the start.
    expect(parseQuery("see t: later").sources).toBeNull()
  })

  test("scope tokens override the scope anywhere in the query", () => {
    expect(parseQuery("auth in:here")).toMatchObject({ scope: "workspace", text: "auth" })
    expect(parseQuery("in:all t: auth")).toMatchObject({ scope: "all", text: "auth", sources: ["terminals"] })
  })

  test("regex literal, toggle, flags and errors", () => {
    expect(parseQuery("/err(or)?\\b/")).toMatchObject({ regex: true, text: "err(or)?\\b", caseSensitive: false })
    expect(parseQuery("/ERR/i").caseSensitive).toBe(false)
    expect(parseQuery("/ERR/").caseSensitive).toBe(true)
    expect(parseQuery("a+b", { regex: true }).regex).toBe(true)
    expect(parseQuery("/(unclosed/").error).not.toBeNull()
  })

  test("quotes make an exact phrase", () => {
    const q = parseQuery('"dev server"')
    expect(q).toMatchObject({ exact: true, text: "dev server" })
    expect(compile(q).name("development servers")).toBeNull()
  })

  test("prefixes win over the chip; disabled sources never run", () => {
    expect(effectiveSources(parseQuery("t: x"), "files", SOURCES)).toEqual(["terminals"])
    expect(effectiveSources(parseQuery("x"), "files", SOURCES)).toEqual(["files"])
    expect(effectiveSources(parseQuery("x"), null, ["files", "workspaces"])).toEqual(["workspaces", "files"])
  })
})

describe("matching", () => {
  const m = compile(parseQuery("auth"))
  test("name quality orders exact, prefix, word start, substring, fuzzy", () => {
    const q = (s: string) => m.name(s)?.quality ?? -1
    expect(q("auth")).toBe(100)
    expect(q("auth tests")).toBe(90)
    expect(q("api auth")).toBe(80)
    expect(q("oauth")).toBe(70)
    expect(q("a-u-t-h")).toBeGreaterThan(0)
    expect(q("a-u-t-h")).toBeLessThan(60)
    expect(q("hello")).toBe(-1)
  })

  test("multi-word queries match every word", () => {
    expect(compile(parseQuery("web login")).name("Sign in · web app login")?.quality).toBe(60)
  })

  test("fuzzy needs two characters and keeps runs ahead of scattered hits", () => {
    expect(fuzzy("a", "abc")).toBeNull()
    expect(fuzzy("cfg", "config")!.quality).toBeGreaterThan(fuzzy("cfg", "c_____f_____g")!.quality)
  })

  test("body search finds the first match; regex never returns an empty match", () => {
    expect(m.find("POST /v1/auth/refresh")).toEqual({ start: 9, length: 4 })
    expect(compile(parseQuery("/x*/")).find("abc")).toBeNull()
    expect(compile(parseQuery("/\\d{3}/")).find("HTTP 401")).toEqual({ start: 5, length: 3 })
  })

  test("snippets cut around the match with ellipses and squash whitespace", () => {
    const line = `${"a".repeat(60)}   needle   ${"b".repeat(60)}`
    const s = snippet(line, { start: 63, length: 6 }, 10)
    expect(s.match).toBe("needle")
    expect(s.before.startsWith("…")).toBe(true)
    expect(s.after.endsWith("…")).toBe(true)
    expect(s.before).not.toContain("   ")
    expect(nameSegments("auth tests", { start: 0, length: 4 })).toEqual({ before: "", match: "auth", after: " tests" })
  })
})

const hit = (over: Partial<Hit>): Hit => ({
  id: "x",
  source: "terminals",
  kind: "terminal",
  title: "t",
  location: "",
  symbol: "terminal",
  titleRange: null,
  preview: null,
  quality: 50,
  updatedAtMs: null,
  workspaceId: null,
  target: { op: "workspace.focus", params: { workspace: "w" } },
  score: 0,
  ...over
})

describe("ranking and grouping", () => {
  const now = 10 * 24 * 3600_000
  const ctx = { nowMs: now, scope: "all" as const, currentWorkspace: "here", opened: {} }

  test("recency adds up to 24 over a week", () => {
    expect(recencyBonus(now, now)).toBe(24)
    expect(recencyBonus(now - 7 * 24 * 3600_000, now)).toBe(0)
    expect(recencyBonus(null, now)).toBe(0)
  })

  test("current workspace and opened-from-search raise a hit", () => {
    const ranked = rank([[hit({ id: "a", quality: 70 }), hit({ id: "b", quality: 70, workspaceId: "here" }), hit({ id: "c", quality: 70 })]], { ...ctx, opened: { c: now } })
    expect(ranked.map((h) => h.id)).toEqual(["c", "b", "a"])
  })

  test("merging keeps the better copy of the same id", () => {
    const ranked = rank([[hit({ id: "a", quality: 40, title: "low" })], [hit({ id: "a", quality: 90, title: "high" })]], ctx)
    expect(ranked).toHaveLength(1)
    expect(ranked[0]!.title).toBe("high")
  })

  test("groups follow the fixed source order and cap", () => {
    const hits = rank([[hit({ id: "f", source: "files", quality: 99 }), ...[1, 2, 3, 4, 5].map((i) => hit({ id: `t${i}`, quality: 50 + i }))]], ctx)
    const groups = group(hits, groupLimit("compact", 5), new Set(["files"]))
    expect(groups.map((g) => g.source)).toEqual(["terminals", "files"])
    expect(groups[0]).toMatchObject({ total: 5, truncated: true })
    expect(groups[0]!.hits).toHaveLength(4)
    expect(groups[1]!.truncated).toBe(true)
    expect(groupLimit("full", 1)).toBe(40)
  })

  test("the active hit is the selection while present, else the best", () => {
    const ranked = rank([[hit({ id: "a", quality: 90 }), hit({ id: "b", quality: 50 })]], ctx)
    expect(activeHit(ranked, "b")!.id).toBe("b")
    expect(activeHit(ranked, "gone")!.id).toBe("a")
    expect(activeHit([], null)).toBeNull()
  })
})

describe("memory and roots", () => {
  test("recent searches dedupe, trim and cap at eight", () => {
    let list: string[] = []
    for (const q of ["a", "b", " a ", "", "c", "d", "e", "f", "g", "h", "i"]) list = pushRecent(list, q)
    expect(list).toEqual(["i", "h", "g", "f", "e", "d", "c", "a"])
  })

  test("opened map keeps the newest hundred", () => {
    let opened: Record<string, number> = {}
    for (let i = 0; i < 120; i++) opened = markOpened(opened, `h${i}`, i)
    expect(Object.keys(opened)).toHaveLength(100)
    expect(opened.h0).toBeUndefined()
    expect(opened.h119).toBe(119)
  })

  test("folder roots drop duplicates and nested folders", () => {
    expect(distinctRoots(["/a/b", "/a", "/a/", "/c/d", "/c/d/e", "/cd"])).toEqual(["/a", "/cd", "/c/d"])
  })
})
