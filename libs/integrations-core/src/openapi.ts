// Adapted from executor (https://github.com/UsefulSoftwareCo/executor), MIT License, Copyright (c) 2026 Rhys Sullivan
// Upstream: packages/plugins/openapi/src/sdk/extract.ts (extractParameters,
// extractRequestBody, buildInputSchema, deriveOperationId, extractServerList,
// securityScopeAlternatives, extract) and packages/plugins/openapi/src/sdk/openapi-utils.ts
// (DocResolver, declaredContents).
// Changes for cmux: plain TypeScript (no Effect, no Option); JSON documents
// only (the gateway parses YAML before the core sees it); no streaming split,
// file hints, multipart rewriting or response schemas (the catalog lists tools,
// the gateway invokes them); each operation gets a cmux op class and default action.

import { opClassForHttp, defaultActionFor } from "./policy.ts"
import { planToolPaths } from "./openapi-paths.ts"
import { isRecord, type ToolEntry } from "./types.ts"

type Doc = Record<string, unknown>
type Obj = Record<string, unknown>

const HTTP_METHODS = ["get", "put", "post", "delete", "patch", "head", "options", "trace"] as const
const VALID_PARAM_LOCATIONS = new Set(["path", "query", "header", "cookie"])

/** Resolves local `$ref` pointers (`#/components/...`) in one document. */
export class DocResolver {
  constructor(readonly doc: Doc) {}

  resolve<T>(value: unknown): T | null {
    if (isRecord(value) && typeof value.$ref === "string") return this.resolvePointer(value.$ref) as T | null
    return (value ?? null) as T | null
  }

  private resolvePointer(ref: string): unknown {
    if (!ref.startsWith("#/")) return null
    let current: unknown = this.doc
    for (const raw of ref.slice(2).split("/")) {
      const segment = raw.replace(/~1/g, "/").replace(/~0/g, "~")
      if (!isRecord(current)) return null
      current = current[segment]
    }
    return current
  }
}

export interface OperationParameter {
  readonly name: string
  readonly location: "path" | "query" | "header" | "cookie"
  readonly required: boolean
  readonly schema?: unknown
  readonly description?: string
}

export interface ExtractedOperation {
  readonly operationId: string
  readonly toolPath?: string
  readonly method: (typeof HTTP_METHODS)[number]
  readonly pathTemplate: string
  readonly summary?: string
  readonly description?: string
  readonly tags: string[]
  readonly parameters: OperationParameter[]
  readonly inputSchema?: Record<string, unknown>
  readonly deprecated: boolean
  readonly requiredScopeAlternatives?: ReadonlyArray<ReadonlyArray<string>>
}

export interface ExtractionResult {
  readonly title?: string
  readonly description?: string
  readonly version?: string
  readonly servers: string[]
  readonly operations: ExtractedOperation[]
}

const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined)

const extractParameters = (pathItem: Obj, operation: Obj, r: DocResolver): OperationParameter[] => {
  const merged = new Map<string, Obj>()
  for (const raw of [...(Array.isArray(pathItem.parameters) ? pathItem.parameters : []), ...(Array.isArray(operation.parameters) ? operation.parameters : [])]) {
    const p = r.resolve<Obj>(raw)
    if (!p || typeof p.name !== "string" || typeof p.in !== "string") continue
    merged.set(`${p.in}:${p.name}`, p)
  }
  return [...merged.values()]
    .filter((p) => VALID_PARAM_LOCATIONS.has(p.in as string))
    .map((p) => ({
      name: p.name as string,
      location: p.in as OperationParameter["location"],
      required: p.in === "path" ? true : p.required === true,
      ...(p.schema !== undefined ? { schema: p.schema } : {}),
      ...(str(p.description) ? { description: str(p.description) } : {})
    }))
}

/** Request body: required flag, the first declared media type and its schema, and every declared media type. */
const extractRequestBody = (operation: Obj, r: DocResolver): { required: boolean; contentType: string; schema?: unknown; contentTypes: string[] } | undefined => {
  if (!operation.requestBody) return undefined
  const body = r.resolve<Obj>(operation.requestBody)
  if (!body || !isRecord(body.content)) return undefined
  const entries = Object.entries(body.content)
  if (entries.length === 0) return undefined
  const [contentType, media] = entries[0]!
  return { required: body.required === true, contentType, schema: isRecord(media) ? media.schema : undefined, contentTypes: entries.map(([mt]) => mt) }
}

/** JSON Schema of the tool input: parameters by name, plus `body` and `contentType` when the operation takes a body. */
export const buildInputSchema = (parameters: readonly OperationParameter[], body: ReturnType<typeof extractRequestBody>): Record<string, unknown> | undefined => {
  const properties: Record<string, unknown> = {}
  const required: string[] = []
  for (const param of parameters) {
    properties[param.name] = param.schema ?? { type: "string" }
    if (param.required) required.push(param.name)
  }
  if (body) {
    properties.body = body.schema ?? { type: "object" }
    if (body.required) required.push("body")
    if (body.contentTypes.length > 1) properties.contentType = { type: "string", enum: body.contentTypes, default: body.contentType }
  }
  if (Object.keys(properties).length === 0) return undefined
  return { type: "object", properties, ...(required.length > 0 ? { required } : {}), additionalProperties: false }
}

const deriveOperationId = (method: string, pathTemplate: string, operation: Obj): string =>
  str(operation.operationId) ?? (`${method}_${pathTemplate.replace(/[^a-zA-Z0-9]+/g, "_")}`.replace(/^_+|_+$/g, "") || `${method}_operation`)

const explicitToolPath = (operation: Obj): string | undefined => {
  const value = operation["x-cmux-toolPath"]
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined
}

/** Server URLs with `{var}` placeholders filled from their defaults. */
const extractServerList = (servers: unknown): string[] =>
  (Array.isArray(servers) ? servers : []).flatMap((server) => {
    if (!isRecord(server) || typeof server.url !== "string") return []
    let url = server.url
    if (isRecord(server.variables)) {
      for (const [name, v] of Object.entries(server.variables)) {
        if (isRecord(v) && v.default !== undefined) url = url.split(`{${name}}`).join(String(v.default))
      }
    }
    return [url]
  })

/**
 * OAuth scope requirements per operation (OpenAPI Security Requirement
 * Objects): the array is an OR of alternatives; the schemes inside one object
 * are ANDed, so their scopes union. An absent operation `security` inherits the
 * document default; `security: []` disables auth.
 */
const securityScopeAlternatives = (operation: Obj, documentSecurity: unknown): string[][] | undefined => {
  const security = operation.security !== undefined ? operation.security : documentSecurity
  if (!Array.isArray(security) || security.length === 0) return undefined
  const alternatives: string[][] = []
  const seen = new Set<string>()
  for (const requirement of security) {
    if (!isRecord(requirement)) continue
    const scopes = new Set<string>()
    for (const schemeScopes of Object.values(requirement)) {
      if (!Array.isArray(schemeScopes)) continue
      for (const scope of schemeScopes) if (typeof scope === "string" && scope.trim().length > 0) scopes.add(scope)
    }
    if (scopes.size === 0) continue
    const alternative = [...scopes].sort()
    const key = alternative.join(" ")
    if (seen.has(key)) continue
    seen.add(key)
    alternatives.push(alternative)
  }
  return alternatives.length > 0 ? alternatives : undefined
}

export class OpenApiExtractionError extends Error {}

/** Extracts every operation of an OpenAPI 3.x document (sorted by path, then method order). */
export const extract = (doc: Doc): ExtractionResult => {
  if (!isRecord(doc.paths)) throw new OpenApiExtractionError("OpenAPI document has no paths defined")
  const r = new DocResolver(doc)
  const info = isRecord(doc.info) ? doc.info : {}
  const operations: ExtractedOperation[] = []
  const paths = Object.entries(doc.paths).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
  for (const [pathTemplate, rawItem] of paths) {
    const pathItem = r.resolve<Obj>(rawItem)
    if (!pathItem) continue
    for (const method of HTTP_METHODS) {
      const operation = pathItem[method]
      if (!isRecord(operation)) continue
      const parameters = extractParameters(pathItem, operation, r)
      const inputSchema = buildInputSchema(parameters, extractRequestBody(operation, r))
      const scopes = securityScopeAlternatives(operation, doc.security)
      const toolPath = explicitToolPath(operation)
      operations.push({
        operationId: deriveOperationId(method, pathTemplate, operation),
        ...(toolPath ? { toolPath } : {}),
        method,
        pathTemplate,
        ...(str(operation.summary) ? { summary: str(operation.summary) } : {}),
        ...(str(operation.description) ? { description: str(operation.description) } : {}),
        tags: (Array.isArray(operation.tags) ? operation.tags : []).filter((t): t is string => typeof t === "string" && t.trim().length > 0),
        parameters,
        ...(inputSchema ? { inputSchema } : {}),
        deprecated: operation.deprecated === true,
        ...(scopes ? { requiredScopeAlternatives: scopes } : {})
      })
    }
  }
  return { title: str(info.title), description: str(info.description), version: str(info.version), servers: extractServerList(doc.servers), operations }
}

/** Catalog tools of an extraction: planned `group.leaf` paths, op class from the method, default action from the class. */
export const toolsFromOpenApi = (result: ExtractionResult): ToolEntry[] => {
  const ops = result.operations
  const plans = planToolPaths(ops.map((op) => ({ operationId: op.operationId, explicitToolPath: op.toolPath, method: op.method, pathTemplate: op.pathTemplate, tag0: op.tags[0] })))
  return plans.map((plan) => {
    const op = ops[plan.operationIndex]!
    const opClass = opClassForHttp(op.method)
    return {
      path: plan.toolPath,
      title: op.summary ?? op.operationId,
      ...(op.description ? { description: op.description } : {}),
      kind: "openapi" as const,
      method: op.method.toUpperCase(),
      target: op.pathTemplate,
      op_class: opClass,
      default_action: defaultActionFor(opClass),
      ...(op.inputSchema ? { input_schema: op.inputSchema } : {}),
      ...(op.deprecated ? { deprecated: true } : {}),
      ...(op.requiredScopeAlternatives ? { scopes: op.requiredScopeAlternatives } : {})
    }
  })
}
