// Session state of the app: what the owner (ConnectionDO through
// `integration.list` and `integration.policy.get`) last returned, the current
// screen, and one notice line. No second store: every reload replaces the list
// with the owner's answer, and change events trigger the reload (no polling).

import { t } from "../l10n.ts"
import { sortConnections, type Connection, type ListResult, type TeamPolicy } from "./connections.ts"
import type { CatalogKind } from "../core/types.ts"

export type Route = { readonly screen: "home" } | { readonly screen: "detail"; readonly id: string } | { readonly screen: "add" } | { readonly screen: "import"; readonly kind?: CatalogKind }

export interface Problem {
  readonly op: string
  readonly code: string
  readonly message: string
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

export const problemOf = (op: string, e: unknown): Problem => ({ op, code: codeOf(e), message: messageOf(e) })

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
    case "auth.forbidden":
      return t("error.forbidden", "Only the person who connected it can do this.")
    default:
      return p.message
  }
}

export const isMissing = (p: Problem | null): boolean => !!p && (p.code === "operation.unsupported" || p.code === "scope.missing")

export const say = (text: string, tone: Notice["tone"] = "secondary") => setNotice({ text, tone })
export const sayProblem = (p: Problem) => setNotice({ text: problemText(p), tone: isMissing(p) ? "secondary" : "danger" })

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
