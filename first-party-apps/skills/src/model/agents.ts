// Where each agent keeps skills and MCP servers. Display paths only: the owner
// resolves real locations on its machine and the app never reads them.
// `mcp.format` and `mcp.key` drive the reference merge (model/mcp.ts).

export type ConfigFormat = "json" | "toml"
/** How an agent turns an MCP server off: its own `enabled` flag, or cmux keeps the entry in a sibling key the agent ignores. */
export type DisableMode = "flag" | "park"
/** The entry shape each agent's config uses. */
export type EntryDialect = "mcpServers" | "opencode" | "codex"

export type AgentInfo = {
  id: string
  name: string
  skills: { user: string; project: string } | null
  mcp: { format: ConfigFormat; user: string; project: string | null; key: string; dialect: EntryDialect; disable: DisableMode }
}

export const AGENTS: readonly AgentInfo[] = [
  {
    id: "claude",
    name: "Claude Code",
    skills: { user: "~/.claude/skills", project: ".claude/skills" },
    mcp: { format: "json", user: "~/.claude.json", project: ".mcp.json", key: "mcpServers", dialect: "mcpServers", disable: "park" }
  },
  {
    id: "codex",
    name: "Codex",
    skills: { user: "~/.codex/skills", project: ".codex/skills" },
    mcp: { format: "toml", user: "~/.codex/config.toml", project: ".codex/config.toml", key: "mcp_servers", dialect: "codex", disable: "flag" }
  },
  {
    id: "opencode",
    name: "OpenCode",
    skills: { user: "~/.config/opencode/skill", project: ".opencode/skill" },
    mcp: { format: "json", user: "~/.config/opencode/opencode.json", project: "opencode.json", key: "mcp", dialect: "opencode", disable: "flag" }
  },
  {
    id: "gemini",
    name: "Gemini CLI",
    skills: null,
    mcp: { format: "json", user: "~/.gemini/settings.json", project: ".gemini/settings.json", key: "mcpServers", dialect: "mcpServers", disable: "park" }
  }
]

const BY_ID = new Map(AGENTS.map((a) => [a.id, a]))
export const agentInfo = (id: string): AgentInfo | null => BY_ID.get(id) ?? null
export const agentName = (id: string) => agentInfo(id)?.name ?? id
export const agentRank = (id: string) => {
  const i = AGENTS.findIndex((a) => a.id === id)
  return i < 0 ? AGENTS.length : i
}

/** The sibling key that holds parked (disabled) entries for agents without an enabled flag. */
export const PARK_KEY = "_cmuxDisabledMcpServers"
