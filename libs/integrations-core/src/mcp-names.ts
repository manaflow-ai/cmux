// The cmux MCP endpoint's tool names and the tools it lists. cmux code (no
// upstream code).
//
// One endpoint per principal (MCP_ENDPOINT_PATH) lists the tools of every
// connection whose owner opted it in to MCP. A tool's MCP name is
// `<namespace>__<path>` in the alphabet MCP clients accept for tool names
// (`[A-Za-z0-9_-]`, at most 64 characters). A path's dots become `-`, so a
// plain path encodes without loss. A name that would lose information (other
// characters, a `-` in the path, an unclean namespace) or would be longer than
// 64 characters ends with `_` and 8 hex digits of a hash of the full address,
// cut so the whole name is 64 characters at most. `assignMcpToolNames` gives a
// set of tools unique names in a fixed order, so the result does not depend on
// the order of its input. Block tools are not listed; Ask tools are listed and
// wait for approval through the feed or MCP elicitation.

import { grantFor, resolveEffectivePolicy, type PolicyRule } from "./policy.ts"
import { compareCodePoints, fnv1a } from "./text.ts"
import type { ToolAction, ToolEntry } from "./types.ts"

export const MCP_ENDPOINT_PATH = "/v1/mcp"
export const MCP_TOOL_NAME_MAX = 64
export const MCP_TOOL_NAME_PATTERN = /^[A-Za-z0-9_-]{1,64}$/
/** cmux connects to remote MCP servers over Streamable HTTP only; stdio servers are not supported. */
export const MCP_TRANSPORT = "streamable_http" as const
export type McpTransport = typeof MCP_TRANSPORT

const SEPARATOR = "__"
const HASH_SUFFIX_LENGTH = 9 // "_" + 8 hex digits

/** A namespace in the name alphabet, without `__` runs or edge underscores (so the first `__` of a name ends the namespace). */
const cleanNamespace = (namespace: string): string =>
  namespace
    .replace(/[^A-Za-z0-9_-]+/g, "_")
    .replace(/_{2,}/g, "_")
    .replace(/^[_-]+|[_-]+$/g, "") || "api"

const encodePath = (path: string): string => path.replace(/\./g, "-").replace(/[^A-Za-z0-9_-]/g, "_") || "tool"

/** True when `<namespace>__<path>` can be read back to the same namespace and path. */
const isLossless = (namespace: string, path: string): boolean => cleanNamespace(namespace) === namespace && /^[A-Za-z0-9_.]+$/.test(path) && !path.startsWith(".") && !path.endsWith(".")

/**
 * The MCP name of one tool. `salt` > 0 asks for an alternative hashed name;
 * `assignMcpToolNames` uses it to resolve the rare collision.
 */
export const mcpToolName = (namespace: string, path: string, salt = 0): string => {
  const plain = `${cleanNamespace(namespace)}${SEPARATOR}${encodePath(path)}`
  if (salt === 0 && isLossless(namespace, path) && plain.length <= MCP_TOOL_NAME_MAX) return plain
  const suffix = `_${fnv1a(`${namespace}.${path}${salt > 0 ? `#${salt}` : ""}`)}`
  return `${plain.slice(0, MCP_TOOL_NAME_MAX - HASH_SUFFIX_LENGTH)}${suffix}`
}

export interface McpNameInput {
  /** Unique per entry, for example `<connection id>:<tool path>`. */
  readonly key: string
  readonly namespace: string
  readonly path: string
}

/**
 * Unique names for a set of tools. Entries are named in code-point order of
 * `<namespace>.<path>` then key; an entry whose name is taken gets the next
 * salted hash. Deterministic for a given set, whatever the input order.
 */
export const assignMcpToolNames = (entries: ReadonlyArray<McpNameInput>): Map<string, string> => {
  const sortKey = (e: McpNameInput) => `${e.namespace}.${e.path}\u0000${e.key}`
  const sorted = [...entries].sort((a, b) => compareCodePoints(sortKey(a), sortKey(b)))
  const taken = new Set<string>()
  const out = new Map<string, string>()
  for (const e of sorted) {
    let salt = 0
    let name = mcpToolName(e.namespace, e.path)
    while (taken.has(name)) name = mcpToolName(e.namespace, e.path, ++salt)
    taken.add(name)
    out.set(e.key, name)
  }
  return out
}

export interface McpConnectionInput {
  readonly connection: string
  /** The connection's owner opted it in to the MCP endpoint. */
  readonly mcp_exposed: boolean
  readonly namespace: string
  readonly tools: ReadonlyArray<ToolEntry>
  /** Team and user rules for this principal; the most restrictive wins. */
  readonly rules: ReadonlyArray<PolicyRule>
}

export interface McpListedTool {
  readonly name: string
  readonly connection: string
  /** Policy address `<namespace>.<path>`. */
  readonly address: string
  readonly action: Exclude<ToolAction, "block">
  /** `per_call`: the call waits for approval in the feed or through MCP elicitation. */
  readonly approval: "none" | "per_call"
}

/**
 * The tools the MCP endpoint lists for one principal: only opted-in
 * connections, without Block tools, sorted by name. Names are assigned over
 * every tool of the opted-in connections (Block tools included), so blocking
 * one tool never renames another.
 */
export const mcpListedTools = (connections: ReadonlyArray<McpConnectionInput>): McpListedTool[] => {
  const exposed = connections.filter((c) => c.mcp_exposed)
  const names = assignMcpToolNames(exposed.flatMap((c) => c.tools.map((t) => ({ key: `${c.connection}:${t.path}`, namespace: c.namespace, path: t.path }))))
  const out: McpListedTool[] = []
  for (const c of exposed) {
    for (const t of c.tools) {
      const address = `${c.namespace}.${t.path}`
      const action = resolveEffectivePolicy(address, c.rules, t.default_action).action
      const grant = grantFor(action)
      if (action === "block" || !grant) continue
      out.push({ name: names.get(`${c.connection}:${t.path}`)!, connection: c.connection, address, action, approval: grant.approval })
    }
  }
  return out.sort((a, b) => compareCodePoints(a.name, b.name))
}
