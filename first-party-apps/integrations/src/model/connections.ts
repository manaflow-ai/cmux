// Pure view model over the backend's Connection records (protocol
// integrations.ts, owner ConnectionDO). The app never stores a second copy:
// it renders what `integration.list` returns and re-reads on change events.

import { hostAllowed, type CatalogKind, type CredentialKind } from "@cmux/integrations-core"
import { t } from "../l10n.ts"
import { providerInfo, type ProviderId } from "./providers.ts"

/** Live (not revoked or expired) connections a team may have; generic connections count too. Mirrors the owner's MAX_CONNECTIONS. */
export const MAX_CONNECTIONS = 50

export type ConnectionStatus = "pending" | "active" | "needs_reauth" | "error" | "revoked" | "expired"
export type Sharing = "private" | "team"

/** The generic catalog of a connection (contract: content-addressed in ConnectionDO `catalog_blobs`, re-ingested daily). */
export interface ConnectionCatalog {
  readonly kind: CatalogKind
  readonly title: string
  readonly version?: string
  readonly digest: string
  readonly source_url?: string
  /**
   * Set when the daily re-ingest found a different digest; the owner posted a
   * feed notice `feed_item` about it. Cleared when the user opens it. (Field
   * name is this app's mock until the protocol lands.)
   */
  readonly changed?: { readonly at: number; readonly feed_item: string; readonly previous_digest: string } | null
}

/** `Cmux.Connection` as extended by the backend's final contract (README, "Contract (final)"). */
export interface Connection {
  readonly id: string
  readonly owner: string
  readonly created_by: string
  /** First-class provider, or a generic kind (`openapi`, `graphql`, `mcp`). */
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
  /** Generic connections only. */
  readonly catalog?: ConnectionCatalog
  /** How the gateway authenticates (the sealed secret stays in the gateway behind a `cred_…` handle). */
  readonly auth?: { readonly kind: CredentialKind }
  /** The owner opted this connection in to the `/v1/mcp` endpoint (off by default). */
  readonly mcp_exposed?: boolean
}

export interface TeamPolicy {
  /** Providers and generic kinds members may connect; null = all. */
  readonly allowed_providers: ReadonlyArray<string> | null
  /** Hosts generic connections may target (`api.example.com`, `*.example.com`); null = any public host. */
  readonly generic_hosts?: ReadonlyArray<string> | null
  readonly source: "default" | "admin" | "sso" | "mdm" | "team_policy"
  readonly locked: boolean
  readonly github?: { readonly scope: string; readonly require_org_admin: boolean; readonly repo_allowlist: ReadonlyArray<string> | null }
}

export interface Viewer {
  readonly user: string
  readonly team_admin: boolean
}

export interface ListResult {
  readonly connections: ReadonlyArray<Connection>
  readonly providers: ReadonlyArray<{ readonly provider: string; readonly configured: boolean }>
  readonly revision?: string
  /** Who is asking: decides who may share, sign in again and disconnect (the owner enforces). */
  readonly viewer?: Viewer
  /** The team's live connection count; the list holds only connections the caller may use. */
  readonly limit?: { readonly used: number; readonly max: number }
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

/** Does the team policy allow connecting this provider or generic kind? */
export const providerAllowed = (policy: TeamPolicy | null, provider: string): boolean =>
  !policy || policy.allowed_providers === null || policy.allowed_providers.includes(provider)

/** Does `generic_hosts` allow this host? The owner enforces it on connect, refresh and every call; this is the add flow's pre-check. */
export const genericHostAllowed = (policy: TeamPolicy | null, host: string): boolean => hostAllowed(host, policy?.generic_hosts ?? null)

/** Team connections used and the cap: the owner's count when it sends one, else the live connections in the list. */
export const connectionUsage = (list: ListResult | null): { readonly used: number; readonly max: number } =>
  list?.limit ?? { used: (list?.connections ?? []).filter(isLive).length, max: MAX_CONNECTIONS }

export const atLimit = (list: ListResult | null): boolean => {
  const u = connectionUsage(list)
  return u.used >= u.max
}

export interface Permissions {
  /** Who the caller disconnects as: the creator, a team admin (team-shared only, audited), or not at all. */
  readonly revoke: "creator" | "team_admin" | null
  /** Change sharing: the creator or a team admin. */
  readonly share: boolean
  /** Sign in again (keeps id, sharing and rules): the creator, or a team admin for a team-shared connection. */
  readonly reauth: boolean
}

/** What the caller may do with a connection. Display only: the owner (ConnectionDO) decides and audits. Unknown viewer: show the actions and let the owner answer. */
export const permissionsFor = (c: Connection, viewer: Viewer | null | undefined): Permissions => {
  if (!viewer) return { revoke: "creator", share: true, reauth: true }
  const creator = c.created_by === viewer.user
  const admin = viewer.team_admin && c.sharing === "team"
  return { revoke: creator ? "creator" : admin ? "team_admin" : null, share: creator || viewer.team_admin, reauth: creator || admin }
}

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
