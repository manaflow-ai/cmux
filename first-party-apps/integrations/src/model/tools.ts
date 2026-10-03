// Tool catalogs and per-tool policy of each connection. The gateway owns both
// (proposed `integration.tools.list` and `integration.tools.policy.set`); the
// app shows what it returns. Until those ops exist the app falls back to the
// backend's provider ops for first-class providers and to the catalog imported
// in this session for generic ones, and keeps policy edits for the session only.

import { resolveEffectivePolicy, type EffectivePolicy, type PolicyRule, type Catalog, type ToolAction, type ToolEntry } from "@cmux/integrations-core"
import { t } from "../l10n.ts"
import type { Connection } from "./connections.ts"
import { builtinTools } from "./providers.ts"
import { isMissing, problemOf, say, sayProblem, type Problem } from "./store.ts"

export interface ToolsState {
  readonly phase: "loading" | "ready" | "error"
  /** Policy address prefix: `<namespace>.<tool path>`. */
  readonly namespace: string
  readonly tools: ReadonlyArray<ToolEntry>
  readonly rules: ReadonlyArray<PolicyRule>
  /** gateway: from the owner. builtin: provider ops known to this app. session: imported in this session. */
  readonly source: "gateway" | "builtin" | "session"
  readonly problem?: Problem
  readonly catalog?: { readonly title: string; readonly version?: string; readonly digest?: string; readonly refreshed_at?: number }
}

interface ToolsListResult {
  readonly namespace: string
  readonly tools: ReadonlyArray<ToolEntry>
  readonly rules: ReadonlyArray<PolicyRule>
  readonly catalog?: ToolsState["catalog"]
}

const [byConnection, setByConnection] = signal<Record<string, ToolsState>>({})
/** Catalogs imported in this session, by digest (the fallback for generic connections). */
const sessionCatalogs = new Map<string, Catalog>()

export const toolsOf = (id: string): ToolsState | null => byConnection()[id] ?? null

/** Reads without subscribing, for builders keyed on a coarser computed. */
export const untrackedTools = (id: string): ToolsState | null => untrack(() => toolsOf(id))

const put = (id: string, s: ToolsState) => setByConnection({ ...byConnection(), [id]: s })

export const rememberCatalog = (c: Catalog) => sessionCatalogs.set(c.digest, c)

const fallback = (c: Connection, problem: Problem): ToolsState => {
  const imported = c.catalog ? sessionCatalogs.get(c.catalog.digest) : undefined
  if (imported) return { phase: "ready", namespace: imported.namespace, tools: imported.tools, rules: [], source: "session", problem, catalog: { title: imported.title, ...(imported.version ? { version: imported.version } : {}), digest: imported.digest } }
  const builtin = builtinTools(c.provider)
  if (builtin.length > 0) return { phase: "ready", namespace: c.provider, tools: builtin, rules: [], source: "builtin", problem }
  return { phase: "error", namespace: c.provider, tools: [], rules: [], source: "builtin", problem }
}

/** Loads one connection's tools and rules from the gateway, or the fallback when the op is missing. */
export async function loadTools(c: Connection): Promise<void> {
  const cur = toolsOf(c.id)
  if (!cur) put(c.id, { phase: "loading", namespace: c.provider, tools: [], rules: [], source: "gateway" })
  try {
    const v = await cmux.call<ToolsListResult>("integration.tools.list", { connection: c.id })
    put(c.id, { phase: "ready", namespace: v.namespace, tools: v.tools, rules: v.rules, source: "gateway", ...(v.catalog ? { catalog: v.catalog } : {}) })
  } catch (e) {
    const problem = problemOf("integration.tools.list", e)
    put(c.id, isMissing(problem) ? fallback(c, problem) : { phase: "error", namespace: c.provider, tools: [], rules: [], source: "gateway", problem })
  }
}

export const addressOf = (s: ToolsState, tool: ToolEntry) => `${s.namespace}.${tool.path}`

export const effectiveOf = (s: ToolsState, tool: ToolEntry): EffectivePolicy => resolveEffectivePolicy(addressOf(s, tool), s.rules, tool.default_action)

/** Counts of effective actions for a summary line. */
export const actionCounts = (s: ToolsState) => {
  const out = { allow: 0, ask: 0, block: 0 }
  for (const tool of s.tools) out[effectiveOf(s, tool).action]++
  return out
}

const withUserRule = (rules: ReadonlyArray<PolicyRule>, pattern: string, action: ToolAction | null): PolicyRule[] => {
  const rest = rules.filter((r) => !(r.owner === "user" && r.pattern === pattern))
  return action ? [...rest, { id: `local:${pattern}`, owner: "user", pattern, action }] : rest
}

/**
 * Sets (or with null clears) the caller's rule for one tool. The edit shows at
 * once; the gateway's answer replaces it. A missing op keeps the edit for this
 * session and says so; any other error puts the old rules back.
 */
export async function setToolAction(c: Connection, tool: ToolEntry, action: ToolAction | null): Promise<void> {
  const s = toolsOf(c.id)
  if (!s) return
  const pattern = addressOf(s, tool)
  put(c.id, { ...s, rules: withUserRule(s.rules, pattern, action) })
  try {
    const v = await cmux.call<{ rules: ReadonlyArray<PolicyRule> }>("integration.tools.policy.set", { connection: c.id, owner: "user", pattern, action })
    const now = toolsOf(c.id)
    if (now) put(c.id, { ...now, rules: v.rules })
  } catch (e) {
    const p = problemOf("integration.tools.policy.set", e)
    if (isMissing(p)) {
      say(t("policy.sessionOnly", "{op} is not available yet; this change lasts until cmux restarts.", { op: p.op }))
      return
    }
    const now = toolsOf(c.id)
    if (now) put(c.id, { ...now, rules: s.rules })
    sayProblem(p)
  }
}

export const sourceLabel = (s: ToolsState): string | null => {
  if (s.source === "builtin") return t("tools.builtin", "Built-in list")
  if (s.source === "session") return t("tools.session", "Imported in this session")
  return null
}

export const actionLabel = (a: ToolAction): string => (a === "allow" ? t("action.allow", "Allow") : a === "ask" ? t("action.ask", "Ask") : t("action.block", "Block"))

export const actionTone = (a: ToolAction): string => (a === "allow" ? "success" : a === "ask" ? "warning" : "danger")
