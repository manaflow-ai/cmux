// Adapted from executor (https://github.com/UsefulSoftwareCo/executor), MIT License, Copyright (c) 2026 Rhys Sullivan
// Upstream: packages/plugins/openapi/src/sdk/definitions.ts (planToolPaths and helpers).
// Changes for cmux: no Effect `Option`; the explicit tool path comes from
// `x-cmux-toolPath` instead of the upstream vendor extension; paths sort in
// code-point order (localeCompare differs between JavaScriptCore and QuickJS).
//
// Derives structured `group.leaf` tool paths from OpenAPI operations: flat
// operation ids like `pets_listPets` become `pets.listPets`, and collisions get
// a version segment, a method suffix, then a hash suffix.

const splitWords = (value: string): string[] =>
  value
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/([A-Z]+)([A-Z][a-z0-9]+)/g, "$1 $2")
    .replace(/[^a-zA-Z0-9]+/g, " ")
    .trim()
    .split(/\s+/)
    .filter((part) => part.length > 0)

export const toCamelCase = (value: string): string => {
  const words = splitWords(value).map((w) => w.toLowerCase())
  if (words.length === 0) return "tool"
  const [first, ...rest] = words
  return `${first}${rest.map((p) => `${p[0]?.toUpperCase() ?? ""}${p.slice(1)}`).join("")}`
}

const toPascalCase = (value: string): string => {
  const camel = toCamelCase(value)
  return `${camel[0]?.toUpperCase() ?? ""}${camel.slice(1)}`
}

const VERSION_SEGMENT_REGEX = /^v\d+(?:[._-]\d+)?$/i
const IGNORED_PATH_SEGMENTS = new Set(["api"])

const pathSegmentsFromTemplate = (pathTemplate: string): string[] =>
  pathTemplate
    .split("/")
    .map((s) => s.trim())
    .filter((s) => s.length > 0)

const isPathParameterSegment = (segment: string): boolean => segment.startsWith("{") && segment.endsWith("}")

const normalizeGroupSegment = (value: string | undefined): string | null => {
  const candidate = value?.trim()
  if (!candidate) return null
  return toCamelCase(candidate)
}

const deriveVersionSegment = (pathTemplate: string): string | undefined =>
  pathSegmentsFromTemplate(pathTemplate)
    .map((s) => s.toLowerCase())
    .find((s) => VERSION_SEGMENT_REGEX.test(s))

const derivePathGroup = (pathTemplate: string): string => {
  for (const segment of pathSegmentsFromTemplate(pathTemplate)) {
    const lower = segment.toLowerCase()
    if (VERSION_SEGMENT_REGEX.test(lower)) continue
    if (IGNORED_PATH_SEGMENTS.has(lower)) continue
    if (isPathParameterSegment(segment)) continue
    return normalizeGroupSegment(segment) ?? "root"
  }
  return "root"
}

const splitOperationIdSegments = (value: string): string[] =>
  value
    .split(/[/.]+/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0)

const deriveLeafSeed = (operationId: string, group: string): string => {
  const segments = splitOperationIdSegments(operationId)
  if (segments.length > 1) {
    const [first, ...rest] = segments
    if ((normalizeGroupSegment(first) ?? first) === group && rest.length > 0) return rest.join(" ")
  }
  return operationId
}

const fallbackLeafSeed = (method: string, pathTemplate: string, group: string): string => {
  const relevant = pathSegmentsFromTemplate(pathTemplate)
    .filter((s) => !VERSION_SEGMENT_REGEX.test(s.toLowerCase()))
    .filter((s) => !IGNORED_PATH_SEGMENTS.has(s.toLowerCase()))
    .filter((s) => !isPathParameterSegment(s))
    .map((s) => normalizeGroupSegment(s) ?? s)
    .filter((s) => s !== group)
  const suffix = relevant.map((s) => toPascalCase(s)).join("")
  return `${method}${suffix || "Operation"}`
}

const deriveLeaf = (operationId: string, method: string, pathTemplate: string, group: string): string => {
  const preferred = toCamelCase(deriveLeafSeed(operationId, group))
  if (preferred.length > 0 && preferred !== group) return preferred
  return toCamelCase(fallbackLeafSeed(method, pathTemplate, group))
}

/** The per-operation metadata the planner needs (no schemas). */
export interface OperationPathInput {
  readonly operationId: string
  readonly explicitToolPath: string | undefined
  readonly method: string
  readonly pathTemplate: string
  /** The first non-empty tag, used to seed the group segment. */
  readonly tag0: string | undefined
}

export interface PlannedToolPath {
  readonly toolPath: string
  readonly group: string
  readonly leaf: string
  /** Index into the planner's input array. */
  readonly operationIndex: number
}

interface RawToolPath {
  toolPath: string
  group: string
  leaf: string
  versionSegment: string | undefined
  method: string
  operationHash: string
  operationIndex: number
}

const resolveCollisions = (definitions: RawToolPath[]): PlannedToolPath[] => {
  const staged = definitions.map((d) => ({ ...d }))
  const applyFactory = (factory: (d: RawToolPath) => string) => {
    const byPath = new Map<string, RawToolPath[]>()
    for (const item of staged) {
      const bucket = byPath.get(item.toolPath) ?? []
      bucket.push(item)
      byPath.set(item.toolPath, bucket)
    }
    for (const bucket of byPath.values()) {
      if (bucket.length < 2) continue
      for (const d of bucket) d.toolPath = factory(d)
    }
  }
  // Round 1: version segment. Round 2: method suffix. Round 3: hash suffix.
  applyFactory((d) => (d.versionSegment ? `${d.group}.${d.versionSegment}.${d.leaf}` : d.toolPath))
  const prefix = (d: RawToolPath) => (d.versionSegment ? `${d.group}.${d.versionSegment}` : d.group)
  applyFactory((d) => `${prefix(d)}.${d.leaf}${toPascalCase(d.method)}`)
  applyFactory((d) => `${prefix(d)}.${d.leaf}${toPascalCase(d.method)}${d.operationHash.slice(0, 8)}`)
  return staged.map((d) => ({ toolPath: d.toolPath, group: d.group, leaf: d.leaf, operationIndex: d.operationIndex }))
}

/** Deterministic 32-bit string hash in base 36 (not cryptographic). */
export const stableHash = (value: unknown): string => {
  const str = JSON.stringify(value, Object.keys(value as Record<string, unknown>).sort())
  let hash = 0
  for (let i = 0; i < str.length; i++) hash = ((hash << 5) - hash + str.charCodeAt(i)) | 0
  return Math.abs(hash).toString(36).padStart(8, "0")
}

/** Plan `group.leaf` tool paths; the result is sorted by path and points back into `inputs`. */
export const planToolPaths = (inputs: readonly OperationPathInput[]): PlannedToolPath[] => {
  const raw: RawToolPath[] = inputs.map((op, index) => {
    const operationHash = stableHash({ method: op.method, path: op.pathTemplate, operationId: op.operationId })
    const versionSegment = deriveVersionSegment(op.pathTemplate)
    if (op.explicitToolPath) {
      const [group = "root", ...leafParts] = op.explicitToolPath.split(".").filter(Boolean)
      const leaf = leafParts.join(".") || group
      return { toolPath: op.explicitToolPath, group, leaf, versionSegment, method: op.method, operationHash, operationIndex: index }
    }
    const group = normalizeGroupSegment(op.tag0) ?? derivePathGroup(op.pathTemplate)
    const leaf = deriveLeaf(op.operationId, op.method, op.pathTemplate, group)
    return { toolPath: `${group}.${leaf}`, group, leaf, versionSegment, method: op.method, operationHash, operationIndex: index }
  })
  return resolveCollisions(raw).sort((a, b) => (a.toolPath < b.toolPath ? -1 : a.toolPath > b.toolPath ? 1 : 0))
}
