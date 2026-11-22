// Skills and MCP servers as the owner lists them (skill.list, mcp_server.list),
// grouped and filtered for the views. Pure functions.

import { agentRank } from "./agents.ts"

export type Scope = "user" | "project"
export type Sandbox = "none" | "standard" | "contained" | "complete"
export type SourceKind = "local" | "git" | "store" | "agent"
export type Source = { kind: SourceKind; label: string; url?: string | null; ref?: string | null }

type Common = {
  /** Owner id: skl_… or mcp_…, one per (agent, scope, root, name). */
  id: string
  name: string
  agent: string
  scope: Scope
  /** Root handle of the project folder for project scope. */
  root?: string | null
  enabled: boolean
  source: Source
  /** What it asks for, in cmux scope words ("process:execute", "net:api.example.com", "fs:read:project"). */
  requests: string[]
  sandbox: Sandbox
  /** Display path of the file or folder ("~/.codex/config.toml", ".claude/skills/release"). */
  path_label: string
}

export type Skill = Common & { kind: "skill"; description: string }
export type McpServer = Common & { kind: "mcp"; transport: "stdio" | "http"; command_label?: string | null; url?: string | null; env_keys: string[] }
export type Item = Skill | McpServer

export type Project = { root: string; label: string; workspace?: string | null }

export const itemKey = (i: Pick<Item, "kind" | "agent" | "scope" | "root" | "name">) => `${i.kind}:${i.agent}:${i.scope}:${i.root ?? ""}:${i.name}`

/** One logical item across agents: the same skill or server name in the same scope. */
export type Group = { key: string; kind: Item["kind"]; name: string; scope: Scope; root: string | null; items: Item[] }

export function groupByName(items: readonly Item[]): Group[] {
  const map = new Map<string, Group>()
  for (const i of items) {
    const key = `${i.kind}:${i.scope}:${i.root ?? ""}:${i.name}`
    const g = map.get(key) ?? { key, kind: i.kind, name: i.name, scope: i.scope, root: i.root ?? null, items: [] }
    g.items.push(i)
    map.set(key, g)
  }
  for (const g of map.values()) g.items.sort((a, b) => agentRank(a.agent) - agentRank(b.agent))
  return [...map.values()].sort((a, b) => (a.scope === b.scope ? 0 : a.scope === "project" ? -1 : 1) || (a.kind === b.kind ? 0 : a.kind === "skill" ? -1 : 1) || a.name.localeCompare(b.name))
}

export type Filter = { kind: "all" | "skill" | "mcp" | "off"; agent: string | null; scope: "all" | Scope; query: string }
export const DEFAULT_FILTER: Filter = { kind: "all", agent: null, scope: "all", query: "" }

export function matches(i: Item, f: Filter): boolean {
  if (f.kind === "off" ? i.enabled : f.kind !== "all" && i.kind !== f.kind) return false
  if (f.agent && i.agent !== f.agent) return false
  if (f.scope !== "all" && i.scope !== f.scope) return false
  const q = f.query.trim().toLowerCase()
  return !q || i.name.toLowerCase().includes(q) || (i.kind === "skill" && i.description.toLowerCase().includes(q))
}

export type Tone = "secondary" | "warning" | "danger"

/** Risk tone of one request (permissions model: neutral read, warning write/network, danger execute/external). */
export function requestTone(r: string): Tone {
  if (/:(execute|external)\b/.test(r) || r.startsWith("process:")) return "danger"
  if (/:write\b/.test(r) || r.startsWith("net:")) return "warning"
  return "secondary"
}

export function worstTone(requests: readonly string[]): Tone {
  const tones = requests.map(requestTone)
  return tones.includes("danger") ? "danger" : tones.includes("warning") ? "warning" : "secondary"
}

/** Unsandboxed items that execute processes are the ones the user should look at first. */
export const needsAttention = (i: Item) => i.enabled && i.sandbox === "none" && worstTone(i.requests) === "danger"
