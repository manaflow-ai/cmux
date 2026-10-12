// Adapted from executor (https://github.com/UsefulSoftwareCo/executor), MIT License, Copyright (c) 2026 Rhys Sullivan
// Upstream: packages/core/sdk/src/policies.ts (matchPattern, isValidPattern,
// patternSpecificity, resolveToolPolicy, resolveEffectivePolicy) and the
// approval defaults in packages/plugins/openapi/src/sdk/invoke.ts
// (annotationsForOperation), packages/plugins/graphql/src/sdk/plugin.ts
// (annotationsFor) and packages/plugins/mcp/src/sdk/plugin.ts (toToolDef).
// Changes for cmux: actions are allow/ask/block (upstream approve,
// require_approval, block); owners are team (outer) and user (inner); rules
// are ordered by specificity instead of fractional position keys; defaults
// derive from cmux op classes, so destructive tools default to block, and
// only a rule for the exact tool may loosen a block default.

import type { CatalogKind, OpClass, ToolAction } from "./types.ts"

// ---------------------------------------------------------------------------
// Defaults: op class from the spec, action from the op class.
// ---------------------------------------------------------------------------

const READ_METHODS = new Set(["get", "head", "options"])

/** OpenAPI: safe methods read, DELETE is destructive, every other method mutates shared state. */
export const opClassForHttp = (method: string): OpClass => {
  const m = method.toLowerCase()
  if (READ_METHODS.has(m)) return "read"
  if (m === "delete") return "destructive"
  return "mutate-shared"
}

/**
 * GraphQL: queries read and mutations mutate. GraphQL has no destructive
 * marker, so a mutation whose root field name starts with a destructive verb
 * is classed destructive (a name heuristic; the spec cannot say more).
 */
const DESTRUCTIVE_VERB = /^(delete|remove|destroy|purge|drop|erase|wipe)(?=[A-Z_]|$)/

export const opClassForGraphql = (kind: "query" | "mutation", fieldName: string): OpClass => {
  if (kind === "query") return "read"
  return DESTRUCTIVE_VERB.test(fieldName) ? "destructive" : "mutate-shared"
}

/**
 * MCP: `readOnlyHint` reads, an explicit `destructiveHint: true` is
 * destructive, anything else mutates. Upstream approves un-annotated tools; cmux
 * asks, because the MCP default for an un-annotated tool is "may write".
 */
export const opClassForMcp = (annotations: { readOnlyHint?: boolean; destructiveHint?: boolean } | undefined): OpClass => {
  if (annotations?.readOnlyHint === true) return "read"
  if (annotations?.destructiveHint === true) return "destructive"
  return "mutate-shared"
}

/** The default action of an op class: reads and own-data writes run, shared and external effects ask, destructive and money effects are blocked. */
export const defaultActionFor = (opClass: OpClass): ToolAction => {
  switch (opClass) {
    case "read":
    case "mutate-own":
      return "allow"
    case "destructive":
    case "money":
      return "block"
    default:
      return "ask"
  }
}

export const opClassFor = (kind: CatalogKind, input: { method?: string; field?: string; annotations?: { readOnlyHint?: boolean; destructiveHint?: boolean } }): OpClass => {
  if (kind === "openapi") return opClassForHttp(input.method ?? "get")
  if (kind === "graphql") return opClassForGraphql(input.method === "mutation" ? "mutation" : "query", input.field ?? "")
  return opClassForMcp(input.annotations)
}

// ---------------------------------------------------------------------------
// Patterns. Grammar (matched against `<namespace>.<tool path>`):
//   `*`                  every tool
//   `petstore.pets.list` exact
//   `petstore.pets.*`    subtree: the literal prefix plus anything deeper
//   `petstore.*.delete`  a non-trailing `*` matches exactly one segment
// A `*` is always a whole segment; `pe*` and a leading `*.x` are invalid.
// ---------------------------------------------------------------------------

export const matchPattern = (pattern: string, address: string): boolean => {
  if (pattern === "*") return true
  const patternSegments = pattern.split(".")
  const toolSegments = address.split(".")
  for (let i = 0; i < patternSegments.length; i++) {
    const seg = patternSegments[i]!
    if (seg === "*") {
      if (i === patternSegments.length - 1) return toolSegments.length >= i
      if (i >= toolSegments.length) return false
      continue
    }
    if (i >= toolSegments.length || toolSegments[i] !== seg) return false
  }
  return patternSegments.length === toolSegments.length
}

export const isValidPattern = (pattern: string): boolean => {
  if (pattern.length === 0) return false
  if (pattern === "*") return true
  if (pattern.startsWith(".") || pattern.endsWith(".")) return false
  if (pattern.includes("..")) return false
  if (pattern.startsWith("*")) return false
  for (const seg of pattern.split(".")) {
    if (seg.length === 0) return false
    if (seg.includes("*") && seg !== "*") return false
  }
  return true
}

/**
 * Higher is more specific: `*` 0, `a.*` 2, `a.b.*` 4, `a.b` 5, `a.b.c` 7.
 * A more specific rule of the same owner wins over a broader one.
 */
export const patternSpecificity = (pattern: string): number => {
  if (pattern === "*") return 0
  if (pattern.endsWith(".*")) return pattern.slice(0, -2).split(".").length * 2
  return pattern.split(".").length * 2 + 1
}

// ---------------------------------------------------------------------------
// Resolution: each owner contributes its first matching rule (most specific
// first); the most restrictive action across owners wins, so a user rule can
// never weaken a team rule.
// ---------------------------------------------------------------------------

export interface PolicyRule {
  readonly id: string
  readonly owner: "team" | "user"
  readonly pattern: string
  readonly action: ToolAction
}

export interface EffectivePolicy {
  readonly action: ToolAction
  readonly source: "team" | "user" | "default"
  readonly pattern?: string
  readonly ruleId?: string
}

const restriction: Record<ToolAction, number> = { allow: 1, ask: 2, block: 3 }

/** The more restrictive of two actions. */
export const stricter = (a: ToolAction, b: ToolAction): ToolAction => (restriction[b] > restriction[a] ? b : a)

/** A pattern without a `*` segment names one exact tool. */
const isExact = (pattern: string): boolean => !pattern.split(".").includes("*")

/**
 * Most specific first. A one-segment wildcard (`a.*.c`) scores the same as an
 * exact rule of the same length (`a.b.c`), so at equal specificity an exact
 * rule comes first: a rule id never decides between an exact and a wildcard
 * rule. The id only orders two equally specific wildcards.
 */
const byPrecedence = (a: PolicyRule, b: PolicyRule) =>
  patternSpecificity(b.pattern) - patternSpecificity(a.pattern) || Number(isExact(b.pattern)) - Number(isExact(a.pattern)) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)

export const resolveToolPolicy = (address: string, rules: readonly PolicyRule[]): EffectivePolicy | undefined => {
  const firstByOwner = new Map<string, PolicyRule>()
  for (const rule of [...rules].sort(byPrecedence)) {
    if (firstByOwner.has(rule.owner)) continue
    if (matchPattern(rule.pattern, address)) firstByOwner.set(rule.owner, rule)
  }
  let selected: PolicyRule | undefined
  for (const rule of firstByOwner.values()) {
    if (!selected || restriction[rule.action] > restriction[selected.action]) selected = rule
  }
  return selected ? { action: selected.action, source: selected.owner, pattern: selected.pattern, ruleId: selected.id } : undefined
}

/**
 * A matching rule wins over the default derived from the spec; with no rule
 * the default applies. Exception for tools whose default is Block (destructive
 * and money ops): only a rule for that exact tool may loosen it. A broader
 * rule (`ns.*`, `ns.*.delete`, `*`) that would allow or ask counts as the
 * default for its owner, so a subtree rule never unblocks a destructive tool
 * by accident. Across owners the most restrictive action still wins.
 */
export const resolveEffectivePolicy = (address: string, rules: readonly PolicyRule[], defaultAction: ToolAction): EffectivePolicy => {
  if (defaultAction !== "block") return resolveToolPolicy(address, rules) ?? { action: defaultAction, source: "default" }
  const byOwner = new Map<string, PolicyRule>()
  for (const rule of [...rules].sort(byPrecedence)) {
    // byPrecedence puts an owner's exact rule before its equally specific wildcard.
    if (!byOwner.has(rule.owner) && matchPattern(rule.pattern, address)) byOwner.set(rule.owner, rule)
  }
  let selected: EffectivePolicy | undefined
  for (const rule of byOwner.values()) {
    const effective: EffectivePolicy = rule.action !== "block" && rule.pattern !== address ? { action: "block", source: "default" } : { action: rule.action, source: rule.owner, pattern: rule.pattern, ruleId: rule.id }
    if (!selected || restriction[effective.action] > restriction[selected.action]) selected = effective
  }
  return selected ?? { action: "block", source: "default" }
}

/** cmux grant shape for an action (identity-and-permissions: grants carry op classes and an approval mode). */
export const grantFor = (action: ToolAction): { granted: boolean; approval: "none" | "per_call" } | null =>
  action === "block" ? null : { granted: true, approval: action === "ask" ? "per_call" : "none" }
