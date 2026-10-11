// Reference model of an MCP server change in an agent's own config file.
// The owner (README "Proposed operations") applies changes on its machine;
// this TypeScript model pins the behavior: test/merge-cases.json are the
// conformance vectors the owner must pass, and the app uses the same
// normalization to describe entries. Rules:
// - JSON: parse, change only the server table, re-serialize with the file's
//   indent and final newline. Comments (JSONC) are refused, never dropped.
// - TOML: edit only the `[<key>.<name>]` table and its subtables, line based,
//   so every other byte of the file stays as it was.
// - Disable: the agent's own `enabled` flag where it has one; otherwise the
//   entry is parked under `_cmuxDisabledMcpServers` and moved back on enable.
// - Previews never show a secret: env and header values, and any key that
//   names a token, key, secret or password, render as "•••".

import { type AgentInfo, type EntryDialect, PARK_KEY } from "./agents.ts"

export type McpEntry = {
  transport: "stdio" | "http"
  command?: string
  args?: string[]
  env?: Record<string, string>
  url?: string
  headers?: Record<string, string>
  enabled: boolean
}

export type McpChange =
  | { op: "add"; name: string; entry: McpEntry }
  | { op: "remove"; name: string }
  | { op: "enable"; name: string }
  | { op: "disable"; name: string }

export class MergeError extends Error {
  constructor(readonly code: "mcp.exists" | "mcp.not_found" | "config.unparseable" | "config.invalid_name", message: string) {
    super(message)
  }
}

const NAME = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/

// MARK: entries <-> agent dialects

export function toDialect(dialect: EntryDialect, e: McpEntry): Record<string, unknown> {
  const o: Record<string, unknown> = {}
  if (dialect === "opencode") {
    if (e.transport === "http") Object.assign(o, { type: "remote", url: e.url }, e.headers && Object.keys(e.headers).length ? { headers: e.headers } : {})
    else Object.assign(o, { type: "local", command: [e.command ?? "", ...(e.args ?? [])] }, e.env && Object.keys(e.env).length ? { environment: e.env } : {})
    o.enabled = e.enabled
    return o
  }
  if (e.transport === "http") Object.assign(o, dialect === "mcpServers" ? { type: "http", url: e.url } : { url: e.url }, e.headers && Object.keys(e.headers).length ? { headers: e.headers } : {})
  else Object.assign(o, { command: e.command ?? "" }, e.args?.length ? { args: e.args } : {}, e.env && Object.keys(e.env).length ? { env: e.env } : {})
  if (dialect === "codex" && !e.enabled) o.enabled = false
  return o
}

export function fromDialect(dialect: EntryDialect, raw: Record<string, unknown>): McpEntry {
  const strings = (v: unknown) => (Array.isArray(v) ? v.map(String) : undefined)
  const map = (v: unknown) => (v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v as Record<string, unknown>).map(([k, x]) => [k, String(x)])) : undefined)
  const enabled = raw.enabled !== false
  if (dialect === "opencode") {
    if (raw.type === "remote") return clean({ transport: "http", url: String(raw.url ?? ""), headers: map(raw.headers), enabled })
    const cmd = strings(raw.command) ?? []
    return clean({ transport: "stdio", command: cmd[0] ?? "", args: cmd.slice(1), env: map(raw.environment), enabled })
  }
  const url = raw.url ?? raw.httpUrl ?? raw.serverUrl
  if (typeof url === "string" && !raw.command) return clean({ transport: "http", url, headers: map(raw.headers), enabled })
  return clean({ transport: "stdio", command: String(raw.command ?? ""), args: strings(raw.args), env: map(raw.env), enabled })
}

function clean(e: McpEntry): McpEntry {
  const o: McpEntry = { transport: e.transport, enabled: e.enabled }
  if (e.command !== undefined) o.command = e.command
  if (e.args?.length) o.args = e.args
  if (e.env && Object.keys(e.env).length) o.env = e.env
  if (e.url !== undefined) o.url = e.url
  if (e.headers && Object.keys(e.headers).length) o.headers = e.headers
  return o
}

// MARK: JSON

const indentOf = (text: string) => /\n(\s+)"/.exec(text)?.[1] ?? "  "

function parseJson(text: string): Record<string, unknown> {
  if (text.trim() === "") return {}
  try {
    const v = JSON.parse(text)
    if (!v || typeof v !== "object" || Array.isArray(v)) throw new Error("not an object")
    return v as Record<string, unknown>
  } catch (e) {
    throw new MergeError("config.unparseable", `cannot parse the file as JSON without losing content: ${(e as Error).message}`)
  }
}

function mergeJson(agent: AgentInfo, text: string, change: McpChange): string {
  const doc = parseJson(text)
  const key = agent.mcp.key
  const table = { ...((doc[key] as Record<string, unknown>) ?? {}) }
  const parked = { ...((doc[PARK_KEY] as Record<string, unknown>) ?? {}) }
  const park = agent.mcp.disable === "park"
  const exists = change.name in table || change.name in parked
  switch (change.op) {
    case "add": {
      if (exists) throw new MergeError("mcp.exists", `${change.name} already exists`)
      if (park && !change.entry.enabled) parked[change.name] = toDialect(agent.mcp.dialect, { ...change.entry, enabled: true })
      else table[change.name] = toDialect(agent.mcp.dialect, change.entry)
      break
    }
    case "remove":
      if (!exists) throw new MergeError("mcp.not_found", `${change.name} does not exist`)
      delete table[change.name]
      delete parked[change.name]
      break
    case "enable":
    case "disable": {
      if (!exists) throw new MergeError("mcp.not_found", `${change.name} does not exist`)
      const on = change.op === "enable"
      if (park) {
        if (on && change.name in parked) {
          table[change.name] = parked[change.name]
          delete parked[change.name]
        } else if (!on && change.name in table) {
          parked[change.name] = table[change.name]
          delete table[change.name]
        }
      } else if (change.name in table) {
        const entry = { ...(table[change.name] as Record<string, unknown>) }
        entry.enabled = on
        table[change.name] = entry
      }
    }
  }
  const out: Record<string, unknown> = { ...doc }
  out[key] = table
  if (Object.keys(parked).length) out[PARK_KEY] = parked
  else delete out[PARK_KEY]
  return JSON.stringify(out, null, indentOf(text)) + (text === "" || text.endsWith("\n") ? "\n" : "")
}

// MARK: TOML (line based, only the server's tables change)

const bareKey = (k: string) => (/^[A-Za-z0-9_-]+$/.test(k) ? k : JSON.stringify(k))
const tomlValue = (v: unknown): string => (Array.isArray(v) ? `[${v.map(tomlValue).join(", ")}]` : typeof v === "boolean" ? String(v) : JSON.stringify(String(v)))

/** The [start, end) line range of `<key>.<name>` and its subtables, or null. */
function tomlBlock(lines: string[], key: string, name: string): [number, number] | null {
  const header = (l: string) => /^\s*\[([^\[\]]+)\]\s*(#.*)?$/.exec(l)?.[1]?.trim() ?? null
  const ours = (h: string) => {
    const prefixes = [`${key}.${name}`, `${key}.${JSON.stringify(name)}`]
    return prefixes.some((p) => h === p || h.startsWith(`${p}.`))
  }
  const start = lines.findIndex((l) => {
    const h = header(l)
    return h !== null && ours(h)
  })
  if (start < 0) return null
  let end = start + 1
  while (end < lines.length) {
    const h = header(lines[end]!)
    if (h !== null && !ours(h)) break
    end++
  }
  while (end > start + 1 && lines[end - 1]!.trim() === "") end--
  return [start, end]
}

function mergeToml(agent: AgentInfo, text: string, change: McpChange): string {
  const key = agent.mcp.key
  const lines = text === "" ? [] : text.replace(/\n$/, "").split("\n")
  const block = tomlBlock(lines, key, change.name)
  if (change.op === "add") {
    if (block) throw new MergeError("mcp.exists", `${change.name} already exists`)
    const o = toDialect("codex", change.entry)
    const head = `${key}.${bareKey(change.name)}`
    const out = [`[${head}]`]
    for (const [k, v] of Object.entries(o)) if (typeof v !== "object" || Array.isArray(v)) out.push(`${bareKey(k)} = ${tomlValue(v)}`)
    for (const [k, v] of Object.entries(o))
      if (v && typeof v === "object" && !Array.isArray(v)) {
        out.push(`[${head}.${bareKey(k)}]`)
        for (const [ek, ev] of Object.entries(v as Record<string, unknown>)) out.push(`${bareKey(ek)} = ${tomlValue(ev)}`)
      }
    const sep = lines.length && lines[lines.length - 1]!.trim() !== "" ? [""] : []
    return [...lines, ...sep, ...out].join("\n") + "\n"
  }
  if (!block) throw new MergeError("mcp.not_found", `${change.name} does not exist`)
  const [start, end] = block
  if (change.op === "remove") {
    const from = start > 0 && lines[start - 1]!.trim() === "" ? start - 1 : start
    const rest = [...lines.slice(0, from), ...lines.slice(end)]
    return rest.length ? rest.join("\n") + "\n" : ""
  }
  // enable / disable: only the server's own table, before its first subtable.
  let tableEnd = start + 1
  while (tableEnd < end && !/^\s*\[/.test(lines[tableEnd]!)) tableEnd++
  const flag = lines.slice(start + 1, tableEnd).findIndex((l) => /^\s*enabled\s*=/.test(l))
  const next = [...lines]
  if (change.op === "enable") {
    if (flag >= 0) next.splice(start + 1 + flag, 1)
  } else if (flag >= 0) next[start + 1 + flag] = "enabled = false"
  else next.splice(start + 1, 0, "enabled = false")
  return next.join("\n") + "\n"
}

/** Applies one change to the text of an agent's MCP config file. */
export function mergeMcp(agent: AgentInfo, text: string, change: McpChange): string {
  if (!NAME.test(change.name)) throw new MergeError("config.invalid_name", `invalid server name ${JSON.stringify(change.name)}`)
  return agent.mcp.format === "toml" ? mergeToml(agent, text, change) : mergeJson(agent, text, change)
}

/** Every server in a config text, as normalized entries (parked ones disabled). */
export function listMcp(agent: AgentInfo, text: string): Array<{ name: string; entry: McpEntry }> {
  if (agent.mcp.format === "json") {
    const doc = parseJson(text)
    const on = Object.entries((doc[agent.mcp.key] as Record<string, Record<string, unknown>>) ?? {}).map(([name, raw]) => ({ name, entry: fromDialect(agent.mcp.dialect, raw) }))
    const off = Object.entries((doc[PARK_KEY] as Record<string, Record<string, unknown>>) ?? {}).map(([name, raw]) => ({ name, entry: { ...fromDialect(agent.mcp.dialect, raw), enabled: false } }))
    return [...on, ...off]
  }
  const names = new Set<string>()
  for (const l of text.split("\n")) {
    const m = new RegExp(`^\\s*\\[${agent.mcp.key}\\.("([^"]+)"|[A-Za-z0-9_-]+)\\]`).exec(l)
    if (m) names.add(m[2] ?? m[1]!)
  }
  return [...names].map((name) => {
    const lines = text.split("\n")
    const [s, e] = tomlBlock(lines, agent.mcp.key, name)!
    const raw: Record<string, unknown> = {}
    let sub: Record<string, unknown> = raw
    for (const l of lines.slice(s + 1, e)) {
      const h = /^\s*\[[^\]]*\.([A-Za-z0-9_-]+)\]/.exec(l)
      if (h) {
        sub = raw[h[1]!] = {}
        continue
      }
      const kv = /^\s*([A-Za-z0-9_"-]+)\s*=\s*(.+?)\s*$/.exec(l)
      if (kv) {
        try {
          sub[kv[1]!.replace(/"/g, "")] = JSON.parse(kv[2]!)
        } catch {
          sub[kv[1]!.replace(/"/g, "")] = kv[2]
        }
      }
    }
    return { name, entry: fromDialect("codex", raw) }
  })
}

// MARK: previews without secrets

const SECRET_KEY = /(token|secret|password|passwd|api[_-]?key|authorization|cookie)/i
const SECRET_PARENT = /^(env|headers|environment|http_headers)$/

/** Masks secret values. JSON: structurally. TOML: per line, by key and by table. */
export function redactConfig(format: "json" | "toml", text: string): string {
  if (format === "json") {
    let doc: unknown
    try {
      doc = JSON.parse(text || "{}")
    } catch {
      return text.replace(/("(?:[^"\\]|\\.)*"\s*:\s*)"(?:[^"\\]|\\.)*"/g, (m, k: string) => (SECRET_KEY.test(k) ? `${k}"•••"` : m))
    }
    const walk = (v: unknown, parent: string): unknown => {
      if (Array.isArray(v)) return v.map((x) => walk(x, parent))
      if (v && typeof v === "object") return Object.fromEntries(Object.entries(v as Record<string, unknown>).map(([k, x]) => [k, typeof x === "string" && (SECRET_PARENT.test(parent) || SECRET_KEY.test(k)) ? "•••" : walk(x, k)]))
      return v
    }
    return JSON.stringify(walk(doc, ""), null, indentOf(text)) + (text.endsWith("\n") ? "\n" : "")
  }
  let table = ""
  return text
    .split("\n")
    .map((l) => {
      const h = /^\s*\[([^\]]+)\]/.exec(l)
      if (h) {
        table = h[1]!.split(".").pop()!.replace(/"/g, "")
        return l
      }
      const kv = /^(\s*([A-Za-z0-9_"-]+)\s*=\s*)(.+)$/.exec(l)
      if (kv && (SECRET_PARENT.test(table) || SECRET_KEY.test(kv[2]!))) return `${kv[1]}"•••"`
      return l
    })
    .join("\n")
}

/** The part of the file a preview shows: JSON configs show only the server tables (a user config such as ~/.claude.json holds unrelated account state). */
export function previewScope(agent: AgentInfo, text: string): string {
  if (agent.mcp.format === "toml") return redactConfig("toml", text)
  const doc = parseJson(text)
  const scoped: Record<string, unknown> = {}
  if (doc[agent.mcp.key] !== undefined) scoped[agent.mcp.key] = doc[agent.mcp.key]
  if (doc[PARK_KEY] !== undefined) scoped[PARK_KEY] = doc[PARK_KEY]
  return redactConfig("json", JSON.stringify(scoped, null, indentOf(text)) + "\n")
}
