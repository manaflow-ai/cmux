// Adapted from executor (https://github.com/UsefulSoftwareCo/executor), MIT License, Copyright (c) 2026 Rhys Sullivan
// Upstream: packages/plugins/mcp/src/sdk/manifest.ts (sanitize, uniqueId,
// extractManifestFromListToolsResult, deriveMcpNamespace), the tool annotation
// shape of packages/plugins/mcp/src/sdk/types.ts (McpToolAnnotations) and the
// destructive-hint approval of packages/plugins/mcp/src/sdk/plugin.ts (toToolDef).
// Changes for cmux: plain TypeScript (no Effect Schema decoding; invalid
// entries are skipped one by one); no `_meta` passthrough (the catalog does not
// invoke); no URL global (QuickJS hosts may lack it); un-annotated tools ask
// instead of running without approval.

import { defaultActionFor, opClassForMcp } from "./policy.ts"
import { isRecord, type ToolEntry } from "./types.ts"

export interface McpToolAnnotations {
  readonly title?: string
  readonly readOnlyHint?: boolean
  readonly destructiveHint?: boolean
  readonly idempotentHint?: boolean
  readonly openWorldHint?: boolean
}

export interface McpToolManifestEntry {
  readonly toolId: string
  readonly toolName: string
  readonly description: string | null
  readonly inputSchema?: unknown
  readonly annotations?: McpToolAnnotations
}

export interface McpServerMetadata {
  readonly name: string | null
  readonly version: string | null
}

export interface McpToolManifest {
  readonly server: McpServerMetadata | null
  readonly tools: readonly McpToolManifestEntry[]
}

const sanitize = (value: string): string => {
  const s = value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
  return s || "tool"
}

const uniqueId = (value: string, seen: Map<string, number>): string => {
  const base = sanitize(value)
  const n = (seen.get(base) ?? 0) + 1
  seen.set(base, n)
  return n === 1 ? base : `${base}_${n}`
}

const BOOL_HINTS = ["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"] as const

const readAnnotations = (value: unknown): McpToolAnnotations | undefined => {
  if (!isRecord(value)) return undefined
  const out: Record<string, unknown> = {}
  if (typeof value.title === "string") out.title = value.title
  for (const key of BOOL_HINTS) if (typeof value[key] === "boolean") out[key] = value[key]
  return Object.keys(out).length > 0 ? (out as McpToolAnnotations) : undefined
}

/** A `tools/list` result (one page or merged pages) into manifest entries with address-safe ids. */
export const extractManifestFromListToolsResult = (listToolsResult: unknown, metadata?: { serverInfo?: unknown }): McpToolManifest => {
  const seen = new Map<string, number>()
  const listed = isRecord(listToolsResult) && Array.isArray(listToolsResult.tools) ? listToolsResult.tools : []
  const info = metadata?.serverInfo
  const server = isRecord(info) ? { name: typeof info.name === "string" ? info.name : null, version: typeof info.version === "string" ? info.version : null } : null
  const tools = listed.flatMap((tool): McpToolManifestEntry[] => {
    if (!isRecord(tool) || typeof tool.name !== "string") return []
    const toolName = tool.name.trim()
    if (!toolName) return []
    const annotations = readAnnotations(tool.annotations)
    const inputSchema = tool.inputSchema ?? tool.parameters
    return [
      {
        toolId: uniqueId(toolName, seen),
        toolName,
        description: typeof tool.description === "string" ? tool.description : null,
        ...(inputSchema !== undefined ? { inputSchema } : {}),
        ...(annotations ? { annotations } : {})
      }
    ]
  })
  return { server, tools }
}

const slugify = (value: string): string =>
  value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")

/** Host name of an http(s) URL without the URL global. */
export const hostnameOf = (url: string): string | null => {
  const m = /^[a-z][a-z0-9+.-]*:\/\/(?:[^@/?#]*@)?([^:/?#]+)/i.exec(url.trim())
  return m ? m[1]!.toLowerCase() : null
}

/** Address namespace of a server: its name, else the endpoint host, else `mcp`. */
export const deriveMcpNamespace = (input: { name?: string | null; endpoint?: string | null }): string => {
  if (input.name?.trim()) return slugify(input.name) || "mcp"
  const host = input.endpoint?.trim() ? hostnameOf(input.endpoint) : null
  if (host) return slugify(host) || "mcp"
  return "mcp"
}

/** Catalog tools: read-only hints run, destructive hints are blocked, anything else asks. */
export const toolsFromMcp = (manifest: McpToolManifest): ToolEntry[] =>
  manifest.tools.map((entry) => {
    const opClass = opClassForMcp(entry.annotations)
    return {
      path: entry.toolId,
      title: entry.annotations?.title ?? entry.toolName,
      description: entry.description ?? `MCP tool: ${entry.toolName}`,
      kind: "mcp" as const,
      target: entry.toolName,
      op_class: opClass,
      default_action: defaultActionFor(opClass),
      ...(entry.inputSchema !== undefined ? { input_schema: entry.inputSchema } : {})
    }
  })
