import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { agentInfo, AGENTS } from "../src/model/agents.ts"
import { busyChange, type ChangeState, type Plan, reduceChange } from "../src/model/change.ts"
import { DEFAULT_FILTER, groupByName, type Item, matches, needsAttention, requestTone, worstTone } from "../src/model/items.ts"
import { diffLines, unifiedPatch } from "../src/model/linediff.ts"
import { listMcp, MergeError, mergeMcp, previewScope, redactConfig } from "../src/model/mcp.ts"
import { parsePatch } from "../src/model/patch.ts"
import { parseServerLine, parseSource } from "../src/model/source.ts"
import { CASES, type MergeCase } from "./merge-cases.ts"

describe("MCP config merge conformance vectors", () => {
  test("the JSON copy matches the source", () => {
    expect(JSON.parse(readFileSync(new URL("./merge-cases.json", import.meta.url), "utf8"))).toEqual(JSON.parse(JSON.stringify(CASES)))
  })
  for (const c of CASES as MergeCase[]) {
    test(c.name, () => {
      const agent = agentInfo(c.agent)!
      if (c.error) {
        let code = ""
        try {
          mergeMcp(agent, c.before, c.change)
        } catch (e) {
          code = (e as MergeError).code
        }
        expect(code).toBe(c.error)
      } else expect(mergeMcp(agent, c.before, c.change)).toBe(c.after!)
    })
  }
  test("add then remove returns the original text (TOML and JSON)", () => {
    const toml = CASES.find((c) => c.agent === "codex" && c.change.op === "add")!
    const codex = agentInfo("codex")!
    expect(mergeMcp(codex, mergeMcp(codex, toml.before, toml.change), { op: "remove", name: "db" })).toBe(toml.before)
    const claude = agentInfo("claude")!
    const before = JSON.stringify({ mcpServers: { a: { command: "x" } } }, null, 2) + "\n"
    const added = mergeMcp(claude, before, { op: "add", name: "b", entry: { transport: "http", url: "https://e.example/mcp", enabled: true } })
    expect(mergeMcp(claude, added, { op: "remove", name: "b" })).toBe(before)
  })
  test("disable then enable is the identity for every agent", () => {
    for (const agent of AGENTS) {
      const start = mergeMcp(agent, "", { op: "add", name: "s", entry: { transport: "stdio", command: "x", args: ["y"], enabled: true } })
      expect(mergeMcp(agent, mergeMcp(agent, start, { op: "disable", name: "s" }), { op: "enable", name: "s" }).replace(/,?\n\s*"enabled": true/, "")).toBe(start.replace(/,?\n\s*"enabled": true/, ""))
    }
  })
  test("listMcp reads back what merge wrote, with enabled state", () => {
    for (const agent of AGENTS) {
      let text = mergeMcp(agent, "", { op: "add", name: "db", entry: { transport: "stdio", command: "npx", args: ["-y", "m"], env: { K: "v" }, enabled: true } })
      text = mergeMcp(agent, text, { op: "add", name: "docs", entry: { transport: "http", url: "https://d.example/mcp", enabled: true } })
      text = mergeMcp(agent, text, { op: "disable", name: "docs" })
      const list = listMcp(agent, text).sort((a, b) => a.name.localeCompare(b.name))
      expect(list.map((x) => [x.name, x.entry.transport, x.entry.enabled])).toEqual([
        ["db", "stdio", true],
        ["docs", "http", false]
      ])
      expect(list[0]!.entry).toMatchObject({ command: "npx", args: ["-y", "m"], env: { K: "v" } })
    }
  })
})

describe("previews never show secrets", () => {
  test("env, headers and secret-named keys are masked in JSON and TOML", () => {
    const json = redactConfig("json", JSON.stringify({ mcpServers: { a: { command: "x", env: { DB_URL: "postgres://u:pw@h/db" }, headers: { Authorization: "Bearer abc" } } }, apiKey: "sk-1" }, null, 2))
    expect(json).not.toContain("pw@h")
    expect(json).not.toContain("Bearer abc")
    expect(json).not.toContain("sk-1")
    expect(json).toContain('"command": "x"')
    const toml = redactConfig("toml", '[mcp_servers.a]\ncommand = "x"\nbearer_token = "t1"\n[mcp_servers.a.env]\nK = "secret-value"\n[mcp_servers.b]\nurl = "https://u.example"')
    expect(toml).not.toContain("secret-value")
    expect(toml).not.toContain("t1")
    expect(toml).toContain('url = "https://u.example"')
  })
  test("JSON previews show only the server tables, never other account state", () => {
    const claude = agentInfo("claude")!
    const text = JSON.stringify({ oauthAccount: { emailAddress: "someone@example.com" }, mcpServers: { a: { command: "x" } } }, null, 2) + "\n"
    const preview = previewScope(claude, text)
    expect(preview).not.toContain("example.com")
    expect(preview).toContain('"a"')
  })
  test("a planned patch built from previews carries no secret value", () => {
    const codex = agentInfo("codex")!
    const before = '[mcp_servers.gh]\ncommand = "docker"\n[mcp_servers.gh.env]\nGITHUB_TOKEN = "ghp_fake_value"\n'
    const after = mergeMcp(codex, before, { op: "disable", name: "gh" })
    const patch = unifiedPatch("config.toml", previewScope(codex, before), previewScope(codex, after))
    expect(patch).toContain("+enabled = false")
    expect(patch).not.toContain("ghp_fake_value")
  })
})

describe("line diff and patch parsing", () => {
  test("diffLines keeps order and line numbers; deletions before additions", () => {
    const d = diffLines("a\nb\nc\n", "a\nx\nc\n")
    expect(d.map((l) => `${l.kind}:${l.text}`)).toEqual(["context:a", "del:b", "add:x", "context:c"])
    expect(d[2]!.newLine).toBe(2)
  })
  test("unifiedPatch round-trips through parsePatch", () => {
    const before = Array.from({ length: 20 }, (_, i) => `line ${i}`).join("\n") + "\n"
    const after = before.replace("line 3\n", "line three\n").replace("line 17\n", "")
    const files = parsePatch(unifiedPatch("f.txt", before, after, 2))
    expect(files).toHaveLength(1)
    expect(files[0]!.path).toBe("f.txt")
    expect(files[0]!.hunks).toHaveLength(2)
    expect([files[0]!.additions, files[0]!.deletions]).toEqual([1, 2])
    expect(unifiedPatch("f", "same\n", "same\n")).toBe("")
  })
  test("new and deleted files", () => {
    const created = parsePatch("--- /dev/null\n+++ b/skills/x/SKILL.md\n@@ -0,0 +1,2 @@\n+---\n+name: x\n")
    expect(created[0]).toMatchObject({ path: "skills/x/SKILL.md", oldPath: null, additions: 2 })
    const deleted = parsePatch("--- a/old.md\n+++ /dev/null\n@@ -1 +0,0 @@\n-gone\n")
    expect(deleted[0]).toMatchObject({ path: "old.md", deletions: 1 })
  })
})

const item = (over: Partial<Item> & Pick<Item, "name" | "agent">): Item =>
  ({ id: `${over.agent}-${over.name}`, kind: "mcp", scope: "user", enabled: true, source: { kind: "local", label: "" }, requests: [], sandbox: "standard", path_label: "", transport: "stdio", env_keys: [], ...over }) as Item

describe("items", () => {
  test("one group per name and scope across agents, project first, skills first", () => {
    const groups = groupByName([item({ name: "linear", agent: "codex" }), item({ name: "linear", agent: "claude" }), item({ name: "x", agent: "claude", scope: "project", root: "root_1" }), item({ name: "s", agent: "codex", kind: "skill", description: "" } as Partial<Item> & { name: string; agent: string })])
    expect(groups.map((g) => g.name)).toEqual(["x", "s", "linear"])
    expect(groups[2]!.items.map((i) => i.agent)).toEqual(["claude", "codex"])
  })
  test("filters by kind, off, agent, scope and query", () => {
    const off = item({ name: "a", agent: "codex", enabled: false })
    expect(matches(off, { ...DEFAULT_FILTER, kind: "off" })).toBe(true)
    expect(matches(item({ name: "a", agent: "codex" }), { ...DEFAULT_FILTER, kind: "off" })).toBe(false)
    expect(matches(off, { ...DEFAULT_FILTER, kind: "skill" })).toBe(false)
    expect(matches(off, { ...DEFAULT_FILTER, agent: "claude" })).toBe(false)
    expect(matches(off, { ...DEFAULT_FILTER, scope: "project" })).toBe(false)
    expect(matches(off, { ...DEFAULT_FILTER, query: "A" })).toBe(true)
  })
  test("risk tones and attention", () => {
    expect(requestTone("process:execute")).toBe("danger")
    expect(requestTone("slack:external")).toBe("danger")
    expect(requestTone("net:api.example.com")).toBe("warning")
    expect(requestTone("fs:write:project")).toBe("warning")
    expect(requestTone("fs:read:project")).toBe("secondary")
    expect(worstTone(["fs:read:project", "net:x"])).toBe("warning")
    expect(needsAttention(item({ name: "g", agent: "codex", sandbox: "none", requests: ["process:execute"] }))).toBe(true)
    expect(needsAttention(item({ name: "g", agent: "codex", sandbox: "contained", requests: ["process:execute"] }))).toBe(false)
    expect(needsAttention(item({ name: "g", agent: "codex", sandbox: "none", requests: ["process:execute"], enabled: false }))).toBe(false)
  })
})

describe("planned change state machine", () => {
  const intent = { op: "mcp_server.add", params: {}, title: "Add" }
  const plan: Plan = { diff: "diff_1", title: "Add", files: [] }
  const review = reduceChange(reduceChange({ phase: "idle" }, { type: "ask", intent }), { type: "planned", plan })
  test("ask -> planned -> apply -> applied", () => {
    expect(review.phase).toBe("review")
    const applying = reduceChange(review, { type: "apply" })
    expect(busyChange(applying)).toBe(true)
    expect(reduceChange(applying, { type: "applied" }).phase).toBe("applied")
  })
  test("a stale apply re-plans once and marks the new review; a second stale fails", () => {
    const stale = reduceChange(reduceChange(review, { type: "apply" }), { type: "stale" })
    expect(stale.phase).toBe("planning")
    const again = reduceChange(stale, { type: "planned", plan })
    expect(again).toMatchObject({ phase: "review", note: "stale" })
    const failed = reduceChange(reduceChange(again, { type: "apply" }), { type: "stale" }) as Extract<ChangeState, { phase: "failed" }>
    expect(failed).toMatchObject({ phase: "failed", code: "diff.stale" })
  })
  test("cancel and new asks never interrupt an apply in flight", () => {
    const applying = reduceChange(review, { type: "apply" })
    expect(reduceChange(applying, { type: "cancel" })).toBe(applying)
    expect(reduceChange(applying, { type: "ask", intent })).toBe(applying)
    expect(reduceChange(review, { type: "cancel" }).phase).toBe("idle")
  })
  test("events out of order are ignored", () => {
    const idle: ChangeState = { phase: "idle" }
    for (const ev of [{ type: "planned", plan }, { type: "apply" }, { type: "applied" }, { type: "stale" }, { type: "error", code: "x", message: "" }] as const) expect(reduceChange(idle, ev)).toBe(idle)
    expect(reduceChange(review, { type: "planned", plan })).toBe(review)
  })
})

describe("install sources", () => {
  test("git URLs, shorthand, refs, subfolders and store ids", () => {
    expect(parseSource("acme/agent-skills")).toMatchObject({ ok: true, source: { git: "https://github.com/acme/agent-skills.git", ref: null, path: null } })
    expect(parseSource("https://github.com/acme/agent-skills.git//release-notes#v1.4.0")).toMatchObject({ ok: true, source: { git: "https://github.com/acme/agent-skills.git", ref: "v1.4.0", path: "release-notes" }, label: "acme/agent-skills/release-notes@v1.4.0" })
    expect(parseSource("git@github.com:acme/skills.git")).toMatchObject({ ok: true })
    expect(parseSource("store:acme/pdf-tools")).toMatchObject({ ok: true, source: { store: "acme/pdf-tools" } })
  })
  test("rejects other schemes, path escapes and junk", () => {
    expect(parseSource("")).toEqual({ ok: false, reason: "empty" })
    expect(parseSource("http://example.com/x.git")).toEqual({ ok: false, reason: "scheme" })
    expect(parseSource("file:///etc/passwd")).toEqual({ ok: false, reason: "scheme" })
    expect(parseSource("https://github.com/a/b.git//../../etc")).toEqual({ ok: false, reason: "shape" })
    expect(parseSource("acme/skills#$(rm -rf)")).toEqual({ ok: false, reason: "shape" })
    expect(parseSource("just words here")).toEqual({ ok: false, reason: "shape" })
  })
  test("server lines", () => {
    expect(parseServerLine("docs https://docs.example.com/mcp")).toEqual({ name: "docs", transport: "http", url: "https://docs.example.com/mcp" })
    expect(parseServerLine("db npx -y @acme/db-mcp")).toEqual({ name: "db", transport: "stdio", command: "npx", args: ["-y", "@acme/db-mcp"] })
    expect(parseServerLine("docs http://insecure.example")).toBeNull()
    expect(parseServerLine("onlyname")).toBeNull()
    expect(parseServerLine("bad/name cmd")).toBeNull()
  })
})
