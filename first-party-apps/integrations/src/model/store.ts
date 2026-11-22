// Session state of the app: what the owner (ConnectionDO through
// `integration.list` and `integration.policy.get`) last returned, the current
// screen, and one notice line. No second store: every reload replaces the list
// with the owner's answer, and change events trigger the reload (no polling).

import { CATALOG_BLOB_MAX_BYTES, EGRESS_LIMITS, type CatalogKind } from "@cmux/integrations-core"
import { t } from "../l10n.ts"
import { MAX_CONNECTIONS, sortConnections, type Connection, type ListResult, type TeamPolicy } from "./connections.ts"

export type Route = { readonly screen: "home" } | { readonly screen: "detail"; readonly id: string } | { readonly screen: "add" } | { readonly screen: "import"; readonly kind?: CatalogKind }

export interface Problem {
  readonly op: string
  readonly code: string
  readonly message: string
  /** Error details from the owner (`host` for egress errors, `max` for the limit). */
  readonly details?: Record<string, unknown>
}

export interface Notice {
  readonly text: string
  readonly tone: "secondary" | "warning" | "danger" | "success"
}

const [list, setList] = signal<ListResult | null>(null)
const [loadProblem, setLoadProblem] = signal<Problem | null>(null)
const [loading, setLoading] = signal(true)
const [teamPolicy, setTeamPolicy] = signal<TeamPolicy | null>(null)
const [route, setRoute] = signal<Route>({ screen: "home" })
const [notice, setNotice] = signal<Notice | null>(null)

export { list, loadProblem, loading, teamPolicy, route, setRoute, notice, setNotice }

export const codeOf = (e: unknown): string => (e && typeof e === "object" && "code" in e ? String((e as { code: unknown }).code) : "error")
const messageOf = (e: unknown): string => (e && typeof e === "object" && "message" in e ? String((e as { message: unknown }).message) : String(e))

const detailsOf = (e: unknown): Record<string, unknown> | undefined => {
  const d = e && typeof e === "object" && "details" in e ? (e as { details: unknown }).details : undefined
  return d && typeof d === "object" && !Array.isArray(d) ? (d as Record<string, unknown>) : undefined
}

export const problemOf = (op: string, e: unknown): Problem => {
  const details = detailsOf(e)
  return { op, code: codeOf(e), message: messageOf(e), ...(details ? { details } : {}) }
}

const MB = (bytes: number) => Math.round(bytes / (1024 * 1024))

/** Text for the gateway's egress and catalog errors; the app's own pre-checks use the same codes. */
export const egressText = (code: string, host?: string): string | null => {
  switch (code) {
    case "egress.private_target":
      return host ? t("egress.private.host", "{host} is a private, loopback or link-local address. cmux only connects to public hosts.", { host }) : t("egress.private", "That is a private, loopback or link-local address. cmux only connects to public hosts.")
    case "egress.credentials_in_url":
      return t("egress.credentials", "Remove the user name and password from the URL. Pick a sign-in method below instead.")
    case "egress.invalid_url":
      return t("egress.invalid", "Use an http or https URL.")
    case "egress.too_large":
      return t("egress.tooLarge", "The document is larger than {mb} MB.", { mb: MB(EGRESS_LIMITS.maxResponseBytes) })
    case "egress.timeout":
      return t("egress.timeout", "The server did not answer within {s} seconds.", { s: EGRESS_LIMITS.timeoutMs / 1000 })
    case "egress.host_not_allowed":
      return host ? t("egress.hostNotAllowed.host", "Your team does not allow APIs on {host}.", { host }) : t("egress.hostNotAllowed", "Your team does not allow APIs on this host.")
    case "catalog.too_large":
      return t("catalog.tooLarge", "This API has more tools than cmux can store (the catalog is over {mb} MB).", { mb: MB(CATALOG_BLOB_MAX_BYTES) })
    case "import.mcp_stdio":
      return t("import.error.stdio", "Local (stdio) MCP servers are not supported. Use the server's Streamable HTTP URL.")
    default:
      return null
  }
}

/** Missing ops say which op is missing; other errors keep the owner's message (never a provider body: the gateway redacts them). */
export const problemText = (p: Problem): string => {
  switch (p.code) {
    case "operation.unsupported":
      return t("error.missing", "{op} is not available yet.", { op: p.op })
    case "scope.missing":
      return t("error.scope", "This app may not call {op}.", { op: p.op })
    case "auth.unauthenticated":
      return t("error.signedOut", "Sign in to cmux to see your integrations.")
    case "policy.denied":
      return t("error.policyDenied", "Your team's policy does not allow this.")
    case "integration.not_configured":
      return t("error.notConfigured", "This provider is not set up on this server yet.")
    case "integration.limit":
      return t("error.limit", "Your team has {max} connections, the most it can have. Disconnect one to add another.", { max: typeof p.details?.max === "number" ? p.details.max : MAX_CONNECTIONS })
    case "auth.forbidden":
      return t("error.forbidden", "Only the person who connected it or a team admin can do this.")
    case "user.cancelled":
      return t("error.cancelled", "Cancelled. Nothing changed.")
    default:
      return egressText(p.code, typeof p.details?.host === "string" ? p.details.host : undefined) ?? p.message
  }
}

export const isMissing = (p: Problem | null): boolean => !!p && (p.code === "operation.unsupported" || p.code === "scope.missing")

export const say = (text: string, tone: Notice["tone"] = "secondary") => setNotice({ text, tone })
export const sayProblem = (p: Problem) => setNotice({ text: problemText(p), tone: isMissing(p) || p.code === "user.cancelled" ? "secondary" : "danger" })

let generation = 0

/** Re-reads connections and the team policy from their owner. A newer reload wins over an older one. */
export async function reload(): Promise<void> {
  const mine = ++generation
  const [listResult, policyResult] = await Promise.all([
    cmux.call<ListResult>("integration.list", {}).then(
      (value) => ({ ok: true as const, value }),
      (error: unknown) => ({ ok: false as const, error })
    ),
    cmux.call<TeamPolicy>("integration.policy.get", {}).then(
      (value) => value,
      () => null
    )
  ])
  if (mine !== generation) return
  if (listResult.ok) {
    setList(listResult.value)
    setLoadProblem(null)
  } else {
    setLoadProblem(problemOf("integration.list", listResult.error))
  }
  setTeamPolicy(policyResult)
  setLoading(false)
}

export const connections = computed(() => sortConnections(list()?.connections ?? []))

export const findConnection = (id: string): Connection | null => list()?.connections.find((c) => c.id === id) ?? null

/**
 * Applies one record the owner returned from a mutation (its answer, not a
 * guess), so the screen does not wait for the change event's reload.
 */
export function applyOwnerRecord(c: Connection): void {
  const cur = list()
  // A malformed answer is ignored; the change event's reload brings the truth.
  if (!cur || !c || typeof c.id !== "string" || typeof c.provider !== "string" || typeof c.status !== "string") return
  const rest = cur.connections.filter((x) => x.id !== c.id)
  setList({ ...cur, connections: [...rest, c] })
}

export const open = (r: Route) => {
  setNotice(null)
  setRoute(r)
}
