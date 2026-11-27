import { describe, expect, test } from "bun:test"
import { assignMcpToolNames, MCP_TOOL_NAME_MAX, MCP_TOOL_NAME_PATTERN, mcpListedTools, mcpToolName } from "../src/mcp-names.ts"
import type { PolicyRule } from "../src/policy.ts"
import type { ToolEntry } from "../src/types.ts"

const tool = (path: string, default_action: ToolEntry["default_action"] = "allow"): ToolEntry => ({ path, title: path, kind: "openapi", target: path, op_class: default_action === "block" ? "destructive" : default_action === "ask" ? "mutate-shared" : "read", default_action })

describe("MCP tool names", () => {
  test("plain addresses become <namespace>__<path> with dots as dashes", () => {
    expect(mcpToolName("taskboard_api", "tasks.listTasks")).toBe("taskboard_api__tasks-listTasks")
    expect(mcpToolName("docs_server", "create_page")).toBe("docs_server__create_page")
    expect(mcpToolName("example_com", "query.viewer")).toBe("example_com__query-viewer")
  })

  test("every name fits the MCP client alphabet and 64 characters", () => {
    const inputs: Array<[string, string]> = [
      ["taskboard_api", "tasks.listTasks"],
      ["a".repeat(80), "b"],
      ["ns", `${"segment.".repeat(20)}leaf`],
      ["Weird Name!", "päth.with spaces"],
      ["ns", "a-b"],
      ["", ""]
    ]
    for (const [ns, path] of inputs) {
      const name = mcpToolName(ns, path)
      expect(name).toMatch(MCP_TOOL_NAME_PATTERN)
      expect(name.length).toBeLessThanOrEqual(MCP_TOOL_NAME_MAX)
    }
  })

  test("a long name is cut and ends with a hash of the full address", () => {
    const path = `${"projects.".repeat(10)}listEverything`
    const name = mcpToolName("taskboard_api", path)
    expect(name).toHaveLength(64)
    expect(name.startsWith("taskboard_api__projects-projects-")).toBe(true)
    expect(name).toMatch(/_[0-9a-f]{8}$/)
  })

  test("deterministic: the same address always gives the same name", () => {
    const path = `${"x.".repeat(40)}y`
    expect(mcpToolName("ns", path)).toBe(mcpToolName("ns", path))
    expect(mcpToolName("ns", path, 1)).toBe(mcpToolName("ns", path, 1))
    expect(mcpToolName("ns", path, 1)).not.toBe(mcpToolName("ns", path))
  })

  test("addresses that share a cut prefix get different names", () => {
    const prefix = "a".repeat(70)
    const one = mcpToolName("ns", `${prefix}.one`)
    const two = mcpToolName("ns", `${prefix}.two`)
    expect(one.slice(0, 55)).toBe(two.slice(0, 55))
    expect(one).not.toBe(two)
  })

  test("lossy encodings get a hash, so a dash in a path cannot collide with a dot", () => {
    expect(mcpToolName("ns", "a.b")).toBe("ns__a-b")
    expect(mcpToolName("ns", "a-b")).toMatch(/^ns__a-b_[0-9a-f]{8}$/)
    expect(mcpToolName("my ns", "x")).not.toBe(mcpToolName("my_ns", "x"))
  })

  test("assignMcpToolNames: unique names, independent of input order", () => {
    // Same namespace and path in two connections (two accounts of one API) collide on purpose.
    const entries = [
      { key: "conn_b:tasks.list", namespace: "taskboard", path: "tasks.list" },
      { key: "conn_a:tasks.list", namespace: "taskboard", path: "tasks.list" },
      { key: "conn_a:tasks.get", namespace: "taskboard", path: "tasks.get" },
      { key: "conn_c:x", namespace: "other", path: "x" }
    ]
    const forward = assignMcpToolNames(entries)
    const backward = assignMcpToolNames([...entries].reverse())
    expect([...forward.entries()].sort()).toEqual([...backward.entries()].sort())
    expect(new Set(forward.values()).size).toBe(entries.length)
    expect(forward.get("conn_a:tasks.list")).toBe("taskboard__tasks-list") // first in key order keeps the plain name
    expect(forward.get("conn_b:tasks.list")).toMatch(/^taskboard__tasks-list_[0-9a-f]{8}$/)
  })

  test("assignMcpToolNames: a hashed name that equals a plain one is moved", () => {
    const hashed = mcpToolName("ns", "a-b")
    const plainPath = hashed.slice("ns__".length).replace(/-/g, ".")
    const names = assignMcpToolNames([
      { key: "k1", namespace: "ns", path: "a-b" },
      { key: "k2", namespace: "ns", path: plainPath }
    ])
    expect(names.get("k1")).not.toBe(names.get("k2"))
  })
})

describe("MCP listing", () => {
  const rules: PolicyRule[] = [
    { id: "t1", owner: "team", pattern: "tb.tasks.list", action: "ask" },
    { id: "u1", owner: "user", pattern: "tb.tasks.list", action: "allow" },
    { id: "u2", owner: "user", pattern: "tb.health.get", action: "block" }
  ]
  const tools = [tool("tasks.list"), tool("tasks.delete", "block"), tool("health.get"), tool("projects.create", "ask")]

  test("only opted-in connections are listed", () => {
    expect(mcpListedTools([{ connection: "conn_1", mcp_exposed: false, namespace: "tb", tools, rules }])).toEqual([])
  })

  test("Block tools are hidden; Ask tools are listed with per-call approval; the most restrictive rule wins", () => {
    const listed = mcpListedTools([{ connection: "conn_1", mcp_exposed: true, namespace: "tb", tools, rules }])
    expect(listed).toEqual([
      { name: "tb__projects-create", connection: "conn_1", address: "tb.projects.create", action: "ask", approval: "per_call" },
      { name: "tb__tasks-list", connection: "conn_1", address: "tb.tasks.list", action: "ask", approval: "per_call" }
    ])
  })

  test("blocking one tool does not rename another", () => {
    const a = `${"z".repeat(70)}.one`
    const b = `${"z".repeat(70)}.two`
    const base = { connection: "conn_1", mcp_exposed: true, namespace: "ns", tools: [tool(a), tool(b)] }
    const before = mcpListedTools([{ ...base, rules: [] }]).find((t) => t.address === `ns.${b}`)!.name
    const after = mcpListedTools([{ ...base, rules: [{ id: "u", owner: "user", pattern: `ns.${a}`, action: "block" }] }])
    expect(after).toHaveLength(1)
    expect(after[0]!.name).toBe(before)
  })
})
