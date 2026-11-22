// One importer for generic integrations: detects whether a document is an
// OpenAPI 3 description, a GraphQL introspection result or an MCP `tools/list`
// result, and turns it into a `Catalog` with tools, per-tool defaults and the
// auth methods the document declares. The format extractors it calls are
// adapted from executor (MIT, see NOTICE); this file is cmux code.

import { authMethodsFromOpenApi } from "./openapi-auth.ts"
import { DocResolver, extract as extractOpenApi, toolsFromOpenApi } from "./openapi.ts"
import { extract as extractGraphql, introspectionSchemaOf, toolsFromGraphql } from "./graphql.ts"
import { deriveMcpNamespace, extractManifestFromListToolsResult, hostnameOf, toolsFromMcp } from "./mcp.ts"
import { CATALOG_BLOB_MAX_BYTES } from "./egress.ts"
import { fnv1a, utf8Length } from "./text.ts"
import { isRecord, type Catalog, type CatalogKind, type ToolEntry } from "./types.ts"

export type ImportErrorCode = "import.unknown_format" | "import.swagger2" | "import.no_tools" | "import.invalid_json" | "import.mcp_stdio" | "catalog.too_large"

export class ImportError extends Error {
  constructor(
    readonly code: ImportErrorCode,
    message: string
  ) {
    super(message)
  }
}

/**
 * A local MCP server launch config (`{command, args}`, `{type: "stdio"}`, or a
 * `mcpServers` map of them). cmux connects to MCP servers over Streamable HTTP
 * only, so these are recognized in order to refuse them with a clear error.
 */
export const isStdioMcpConfig = (doc: unknown): boolean => {
  if (!isRecord(doc)) return false
  const one = (v: unknown) => isRecord(v) && (typeof v.command === "string" || v.type === "stdio" || v.transport === "stdio")
  if (one(doc)) return true
  const servers = isRecord(doc.mcpServers) ? doc.mcpServers : isRecord(doc.servers) ? doc.servers : null
  return !!servers && Object.values(servers).some(one)
}

const LAUNCHERS = /^(npx|bunx|uvx|pnpm|yarn|npm|node|deno|bun|python3?|pipx|docker|podman|go|cargo)(\s|$)/

/** Pasted text that is a command line (a local stdio MCP server), not a URL or a document. */
export const isCommandLine = (text: string): boolean => {
  const v = text.trim()
  return LAUNCHERS.test(v) || /^(\.{0,2}\/|~\/)\S*(\s|$)/.test(v)
}

/** The kind of a parsed document, or null when it is none of the three. */
export const detectKind = (doc: unknown): CatalogKind | "swagger2" | "mcp_stdio" | null => {
  if (!isRecord(doc)) return null
  if (typeof doc.openapi === "string" && doc.openapi.startsWith("3")) return "openapi"
  if (typeof doc.swagger === "string") return "swagger2"
  if (isStdioMcpConfig(doc)) return "mcp_stdio"
  if (introspectionSchemaOf(doc)) return "graphql"
  const result = isRecord(doc.result) ? doc.result : doc // a JSON-RPC response or its result
  if (Array.isArray(result.tools)) return "mcp"
  return null
}

const slug = (value: string): string =>
  value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 40)

/**
 * Changes when a tool appears, disappears, moves or changes method or op class;
 * descriptions do not count. FNV-1a is a cheap change detector; the gateway
 * content-addresses `catalog_blobs` with a real hash.
 */
export const catalogDigest = (kind: CatalogKind, tools: readonly ToolEntry[]): string =>
  `${kind}:${fnv1a(tools.map((t) => `${t.path} ${t.method ?? ""} ${t.target} ${t.op_class}`).join("\n"))}`

export interface ImportOptions {
  /** Where the document came from (a spec URL or MCP endpoint); names the namespace when the document has no title. */
  readonly sourceUrl?: string
  /** MCP `initialize` server info, when known. */
  readonly serverInfo?: unknown
}

/** Ingests one parsed document. Throws `ImportError` for unknown formats or documents without tools. */
export const importDocument = (doc: unknown, options: ImportOptions = {}): Catalog => {
  const kind = detectKind(doc)
  if (kind === "swagger2") throw new ImportError("import.swagger2", "Swagger 2.0 documents are not supported; convert to OpenAPI 3")
  if (kind === "mcp_stdio") throw new ImportError("import.mcp_stdio", "Local (stdio) MCP servers are not supported; use the server's Streamable HTTP URL")
  if (!kind) throw new ImportError("import.unknown_format", "Not an OpenAPI 3 document, a GraphQL introspection result or an MCP tool list")
  const host = options.sourceUrl ? hostnameOf(options.sourceUrl) : null
  let catalog: Omit<Catalog, "digest">
  if (kind === "openapi") {
    const record = doc as Record<string, unknown>
    const result = extractOpenApi(record)
    const baseUrl = result.servers[0]
    const title = result.title ?? host ?? "API"
    catalog = {
      kind,
      namespace: slug(result.title ?? "") || slug(host ?? (baseUrl ? hostnameOf(baseUrl) ?? "" : "")) || "api",
      title,
      ...(result.version ? { version: result.version } : {}),
      ...(baseUrl ? { base_url: baseUrl } : {}),
      tools: toolsFromOpenApi(result),
      auth: authMethodsFromOpenApi(record, new DocResolver(record))
    }
  } else if (kind === "graphql") {
    const { fields } = extractGraphql(doc)
    catalog = {
      kind,
      namespace: slug(host ?? "") || "graphql",
      title: host ?? "GraphQL API",
      ...(options.sourceUrl ? { base_url: options.sourceUrl } : {}),
      tools: toolsFromGraphql(fields),
      auth: [{ kind: "bearer", label: "Bearer token", headers: ["Authorization"] }]
    }
  } else {
    const record = doc as Record<string, unknown>
    const manifest = extractManifestFromListToolsResult(isRecord(record.result) ? record.result : record, { serverInfo: options.serverInfo })
    const name = manifest.server?.name ?? null
    catalog = {
      kind,
      namespace: deriveMcpNamespace({ name, endpoint: options.sourceUrl ?? null }),
      title: name ?? host ?? "MCP server",
      ...(manifest.server?.version ? { version: manifest.server.version } : {}),
      ...(options.sourceUrl ? { base_url: options.sourceUrl } : {}),
      tools: toolsFromMcp(manifest),
      // A tool list declares no auth. Remote MCP servers use OAuth (PKCE and dynamic client registration, discovered by the gateway) or a static token; `authChoices` offers both.
      auth: []
    }
  }
  if (catalog.tools.length === 0) throw new ImportError("import.no_tools", "The document declares no operations")
  const out = { ...catalog, digest: catalogDigest(kind, catalog.tools) }
  if (catalogBlobBytes(out) > CATALOG_BLOB_MAX_BYTES) throw new ImportError("catalog.too_large", `The catalog is larger than ${CATALOG_BLOB_MAX_BYTES} bytes`)
  return out
}

/** Size of a catalog as the ConnectionDO stores it in `catalog_blobs` (UTF-8 JSON). */
export const catalogBlobBytes = (catalog: Catalog): number => utf8Length(JSON.stringify(catalog))

/** Parses pasted text (JSON only; the gateway parses YAML) and ingests it. */
export const importText = (text: string, options: ImportOptions = {}): Catalog => {
  let doc: unknown
  try {
    doc = JSON.parse(text)
  } catch {
    throw new ImportError("import.invalid_json", "The text is not JSON")
  }
  return importDocument(doc, options)
}

/** Counts of default actions, for summaries ("12 allowed, 4 ask, 1 blocked"). */
export const defaultCounts = (tools: readonly ToolEntry[]) => {
  const counts = { allow: 0, ask: 0, block: 0 }
  for (const t of tools) counts[t.default_action]++
  return counts
}
