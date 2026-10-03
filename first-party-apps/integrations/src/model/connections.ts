// Pure view model over the backend's Connection records (protocol
// integrations.ts, owner ConnectionDO). The app never stores a second copy:
// it renders what `integration.list` returns and re-reads on change events.

import type { CatalogKind } from "@cmux/integrations-core"
import { t } from "../l10n.ts"
import { providerInfo, type ProviderId } from "./providers.ts"

export type ConnectionStatus = "pending" | "active" | "needs_reauth" | "error" | "revoked" | "expired"
export type Sharing = "private" | "team"

/** `Cmux.Connection` plus the fields this app proposes (README, "Proposed operations"). */
export interface Connection {
  readonly id: string
  readonly owner: string
  readonly created_by: string
  readonly provider: string
  readonly account: { readonly key: string; readonly name: string; readonly url?: string } | null
  readonly scopes_requested: ReadonlyArray<string>
  readonly scopes_granted: ReadonlyArray<string>
  readonly status: ConnectionStatus
  readonly status_detail?: string
  readonly sharing: Sharing
  readonly resources?: { readonly repos: ReadonlyArray<string> | null }
  readonly created_at: number
  readonly updated_at: number
  /** Proposed: generic connections carry their imported catalog's summary. */
  readonly catalog?: { readonly kind: CatalogKind; readonly title: string; readonly version?: string; readonly digest: string; readonly tools: number; readonly source_url?: string }
  /** Proposed: what the caller may do (only the creator revokes in phase 1). */
  readonly capabilities?: { readonly revoke?: boolean; readonly share?: boolean; readonly reauth?: boolean }
}

export interface TeamPolicy {
  readonly allowed_providers: ReadonlyArray<string> | null
  readonly source: "default" | "admin" | "sso" | "mdm" | "team_policy"
  readonly locked: boolean
  readonly github?: { readonly scope: string; readonly require_org_admin: boolean; readonly repo_allowlist: ReadonlyArray<string> | null }
}

export interface ListResult {
  readonly connections: ReadonlyArray<Connection>
  readonly providers: ReadonlyArray<{ readonly provider: string; readonly configured: boolean }>
}

const ATTENTION: ReadonlySet<ConnectionStatus> = new Set(["needs_reauth", "error"])

export const needsAttention = (c: Connection) => ATTENTION.has(c.status)

/** Revoked and expired connections are history; the list hides them. */
export const isLive = (c: Connection) => c.status !== "revoked" && c.status !== "expired"

const rank: Record<ConnectionStatus, number> = { needs_reauth: 0, error: 1, pending: 2, active: 3, expired: 4, revoked: 5 }

/** Attention first, then pending, then active; by name inside a group. */
const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0)

export const sortConnections = (list: ReadonlyArray<Connection>): Connection[] =>
  [...list].filter(isLive).sort((a, b) => rank[a.status] - rank[b.status] || cmp(displayName(a).toLowerCase(), displayName(b).toLowerCase()) || cmp(a.id, b.id))

export const providerOf = (c: Connection): ProviderId => (c.catalog?.kind ?? c.provider) as ProviderId

export const displayName = (c: Connection): string => c.catalog?.title ?? c.account?.name ?? providerInfo(c.provider).name

/** Second line: provider and sharing. */
export const subtitle = (c: Connection): string => {
  const provider = providerInfo(providerOf(c)).name
  return c.sharing === "team" ? t("row.subtitle.team", "{provider} · Shared with team", { provider }) : t("row.subtitle.private", "{provider} · Only you", { provider })
}

export const statusLabel = (s: ConnectionStatus): string => {
  switch (s) {
    case "active":
      return t("status.active", "Connected")
    case "pending":
      return t("status.pending", "Waiting for approval")
    case "needs_reauth":
      return t("status.needsReauth", "Needs sign-in")
    case "error":
      return t("status.error", "Error")
    case "revoked":
      return t("status.revoked", "Disconnected")
    case "expired":
      return t("status.expired", "Link expired")
  }
}

export const statusTone = (s: ConnectionStatus): string => {
  switch (s) {
    case "active":
      return "success"
    case "needs_reauth":
      return "warning"
    case "error":
      return "danger"
    default:
      return "secondary"
  }
}

/** Does the team policy allow connecting this provider? Generic kinds are allowed unless the list exists and omits them. */
export const providerAllowed = (policy: TeamPolicy | null, provider: string): boolean =>
  !policy || policy.allowed_providers === null || policy.allowed_providers.includes(provider)

/** Configured on this deployment? Providers the backend does not list are "not available yet". */
export const providerConfigured = (list: ListResult | null, provider: string): boolean => !!list?.providers.some((p) => p.provider === provider && p.configured)

export const policySourceLabel = (p: TeamPolicy): string | null => {
  switch (p.source) {
    case "sso":
      return t("policy.source.sso", "Team policy managed by single sign-on")
    case "mdm":
      return t("policy.source.mdm", "Team policy managed by device management")
    case "team_policy":
      return t("policy.source.team", "Team policy managed by team settings")
    case "admin":
      return t("policy.source.admin", "Team policy set by an admin")
    default:
      return null
  }
}

export interface Counts {
  readonly total: number
  readonly attention: number
  readonly pending: number
}

export const counts = (list: ReadonlyArray<Connection>): Counts => {
  const live = list.filter(isLive)
  return { total: live.length, attention: live.filter(needsAttention).length, pending: live.filter((c) => c.status === "pending").length }
}
