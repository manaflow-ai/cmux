// Conformance vectors for an MCP config change (README "Proposed operations").
// The owner's native implementation must turn `before` into exactly `after`,
// or fail with `error`. test/merge-cases.json is generated from this file by
// `bun first-party-apps/skills/test/merge-cases.ts` so other languages can load it.

import type { McpChange } from "../src/model/mcp.ts"

export type MergeCase = { name: string; agent: string; before: string; change: McpChange; after?: string; error?: string }

const j = (o: unknown) => JSON.stringify(o, null, 2) + "\n"
const http = { transport: "http" as const, url: "https://docs.example.com/mcp", enabled: true }
const stdio = { transport: "stdio" as const, command: "npx", args: ["-y", "@acme/db-mcp"], env: { DB_URL: "postgres://localhost/dev" }, enabled: true }
const codexBase = ['model = "gpt-codex"', "", "[mcp_servers.linear]", 'url = "https://mcp.linear.app/mcp"', "", "[profiles.fast]", 'model = "small"', ""].join("\n")

export const CASES: MergeCase[] = [
  { name: "json add to empty file creates the table", agent: "claude", before: "", change: { op: "add", name: "docs", entry: http }, after: j({ mcpServers: { docs: { type: "http", url: "https://docs.example.com/mcp" } } }) },
  {
    name: "json add keeps other keys and their order",
    agent: "claude",
    before: j({ theme: "dark", mcpServers: { linear: { type: "http", url: "https://mcp.linear.app/mcp" } }, tips: 3 }),
    change: { op: "add", name: "db", entry: stdio },
    after: j({ theme: "dark", mcpServers: { linear: { type: "http", url: "https://mcp.linear.app/mcp" }, db: { command: "npx", args: ["-y", "@acme/db-mcp"], env: { DB_URL: "postgres://localhost/dev" } } }, tips: 3 })
  },
  { name: "json keeps a tab indent", agent: "gemini", before: '{\n\t"mcpServers": {}\n}\n', change: { op: "add", name: "docs", entry: http }, after: '{\n\t"mcpServers": {\n\t\t"docs": {\n\t\t\t"type": "http",\n\t\t\t"url": "https://docs.example.com/mcp"\n\t\t}\n\t}\n}\n' },
  { name: "json add of an existing name fails", agent: "claude", before: j({ mcpServers: { docs: { url: "x" } } }), change: { op: "add", name: "docs", entry: http }, error: "mcp.exists" },
  { name: "jsonc with comments is refused", agent: "opencode", before: '{\n  // mine\n  "mcp": {}\n}\n', change: { op: "add", name: "docs", entry: http }, error: "config.unparseable" },
  {
    name: "json disable parks the entry when the agent has no flag, enable moves it back",
    agent: "claude",
    before: j({ mcpServers: { linear: { type: "http", url: "u" } } }),
    change: { op: "disable", name: "linear" },
    after: j({ mcpServers: {}, _cmuxDisabledMcpServers: { linear: { type: "http", url: "u" } } })
  },
  { name: "json enable of a parked entry", agent: "claude", before: j({ mcpServers: {}, _cmuxDisabledMcpServers: { linear: { type: "http", url: "u" } } }), change: { op: "enable", name: "linear" }, after: j({ mcpServers: { linear: { type: "http", url: "u" } } }) },
  { name: "opencode disable uses its enabled flag", agent: "opencode", before: j({ mcp: { b: { type: "local", command: ["x"], enabled: true } } }), change: { op: "disable", name: "b" }, after: j({ mcp: { b: { type: "local", command: ["x"], enabled: false } } }) },
  { name: "opencode add writes local with a command array", agent: "opencode", before: j({ mcp: {} }), change: { op: "add", name: "db", entry: stdio }, after: j({ mcp: { db: { type: "local", command: ["npx", "-y", "@acme/db-mcp"], environment: { DB_URL: "postgres://localhost/dev" }, enabled: true } } }) },
  { name: "json remove deletes a parked entry too", agent: "gemini", before: j({ mcpServers: {}, _cmuxDisabledMcpServers: { a: { command: "x" } } }), change: { op: "remove", name: "a" }, after: j({ mcpServers: {} }) },
  { name: "json remove of a missing name fails", agent: "gemini", before: j({ mcpServers: {} }), change: { op: "remove", name: "a" }, error: "mcp.not_found" },
  {
    name: "toml add appends a table and an env subtable, other bytes stay",
    agent: "codex",
    before: codexBase,
    change: { op: "add", name: "db", entry: stdio },
    after: codexBase + ["", "[mcp_servers.db]", 'command = "npx"', 'args = ["-y", "@acme/db-mcp"]', "[mcp_servers.db.env]", 'DB_URL = "postgres://localhost/dev"', ""].join("\n")
  },
  { name: "toml disable inserts the flag after the header", agent: "codex", before: codexBase, change: { op: "disable", name: "linear" }, after: codexBase.replace('[mcp_servers.linear]\n', '[mcp_servers.linear]\nenabled = false\n') },
  { name: "toml enable removes the flag", agent: "codex", before: codexBase.replace('[mcp_servers.linear]\n', '[mcp_servers.linear]\nenabled = false\n'), change: { op: "enable", name: "linear" }, after: codexBase },
  { name: "toml disable rewrites an existing flag", agent: "codex", before: codexBase.replace('[mcp_servers.linear]\n', '[mcp_servers.linear]\nenabled = true\n'), change: { op: "disable", name: "linear" }, after: codexBase.replace('[mcp_servers.linear]\n', '[mcp_servers.linear]\nenabled = false\n') },
  { name: "toml remove deletes the table and keeps the next one", agent: "codex", before: codexBase, change: { op: "remove", name: "linear" }, after: ['model = "gpt-codex"', "", "[profiles.fast]", 'model = "small"', ""].join("\n") },
  {
    name: "toml remove takes subtables with it",
    agent: "codex",
    before: ["[mcp_servers.db]", 'command = "npx"', "[mcp_servers.db.env]", 'K = "v"', "", "[mcp_servers.dbx]", 'command = "y"', ""].join("\n"),
    change: { op: "remove", name: "db" },
    after: ["", "[mcp_servers.dbx]", 'command = "y"', ""].join("\n")
  },
  { name: "toml quoted table names", agent: "codex", before: '[mcp_servers."my.server"]\ncommand = "x"\n', change: { op: "disable", name: "my.server" }, after: '[mcp_servers."my.server"]\nenabled = false\ncommand = "x"\n' },
  { name: "invalid names are refused", agent: "codex", before: "", change: { op: "add", name: "bad name", entry: http }, error: "config.invalid_name" }
]

if (import.meta.main) {
  const { writeFileSync } = await import("node:fs")
  writeFileSync(new URL("./merge-cases.json", import.meta.url), JSON.stringify(CASES, null, 2) + "\n")
  console.log(`${CASES.length} cases written`)
}
