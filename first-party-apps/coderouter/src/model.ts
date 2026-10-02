// Data shapes of the proposed coderouter.* operations (README "Proposed
// operations") and pure helpers over them. Nothing here holds a secret: the
// host returns labels, masked prefixes and opaque handles only.

import { t } from "./l10n.ts"

export type Health = "ok" | "degraded" | "down" | "unknown"
export type ScopeKind = "personal" | "team"
export type Visibility = "private" | "team"
export type LocalStatus = "signed_in" | "expired" | "missing" | "unknown"
export type UsageWindow = "24h" | "7d" | "30d"
export type UsageGroup = "account" | "model" | "key"
export type Surface = "responses" | "messages"

export interface Totals {
  requests: number
  total_tokens: number
  api_equivalent_usd: number
}

/** `coderouter.status` */
export interface Status {
  signed_in: boolean
  user?: { name: string } | null
  scope?: { kind: ScopeKind; team_id: string; team_name: string } | null
  health: Health
  /** cmux agents launched in cmux terminals use CodeRouter. */
  agents_routed: boolean
  usage_today?: Totals | null
}

/** `coderouter.detect`: presence only, never a value. */
export interface Detected {
  provider: string
  name: string
  status: LocalStatus
  identity?: string | null
  plan?: string | null
  /** CodeRouter can hold this provider. */
  linkable: boolean
  /** Where it was found: a path with `~`, `$VAR`, or a Keychain service name. */
  source?: string | null
}

/** `coderouter.accounts.list` */
export interface Account {
  id: string
  provider: string
  name: string
  /** An email, a label or a masked key. Never a secret. */
  label: string
  state: "active" | "refreshing" | "expired" | "broken" | "disabled" | string
  visibility: Visibility
  /** The signed-in user imported it (only the importer changes a private account's sharing). */
  mine: boolean
  cooldown_until_ms?: number | null
}

/** `coderouter.keys.list`: metadata only. */
export interface ApiKey {
  id: string
  label: string
  /** The visible prefix, such as `crk_7Hq2`. */
  prefix: string
  created_at_ms: number
  last_used_at_ms?: number | null
  revoked: boolean
  usage_7d?: Totals | null
}

/** `coderouter.keys.create`: the value stays in the host behind `handle`. */
export interface KeyCreated {
  key: ApiKey
  handle: string
  handle_expires_at_ms?: number
}

export interface UsageRow extends Totals {
  id: string
  label: string
}

/** `coderouter.usage.get` */
export interface Usage {
  window: UsageWindow
  group_by: UsageGroup
  totals: Totals
  rows: UsageRow[]
}

export interface RouteEntry {
  account: string
  label: string
  name: string
  state: string
  cooldown_until_ms?: number | null
}

/** `coderouter.route.get` */
export interface Route {
  surface: Surface
  /** `ordered`: the router tries accounts in this order. `headroom`: it picks by remaining capacity. */
  strategy: "ordered" | "headroom"
  order: RouteEntry[]
}

/** `coderouter.route.test` */
export interface TestResult {
  ok: boolean
  model?: string
  account_label?: string
  provider_name?: string
  latency_ms?: number
  request_id?: string
  at_ms?: number
  error?: { code: string; message: string } | null
}

// MARK: Formatting

export function formatTokens(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return "0"
  if (n < 1000) return String(Math.round(n))
  if (n < 1_000_000) return `${trim(n / 1000)}k`
  if (n < 1_000_000_000) return `${trim(n / 1_000_000)}M`
  return `${trim(n / 1_000_000_000)}B`
}

const trim = (v: number) => (v >= 100 ? String(Math.round(v)) : v.toFixed(1).replace(/\.0$/, ""))

export function formatUsd(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return "$0"
  if (n < 0.01) return "<$0.01"
  if (n < 100) return `$${n.toFixed(2)}`
  return `$${Math.round(n).toLocaleString("en-US")}`
}

export function formatLatency(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return "–"
  return ms < 1000 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(1)} s`
}

export function relativeAge(ms: number | null | undefined, now: number): string {
  if (!ms) return t("age.never", "never used")
  const s = Math.max(0, (now - ms) / 1000)
  if (s < 60) return t("age.now", "just now")
  if (s < 3600) return t("age.minutes", "{n} min ago", { n: Math.floor(s / 60) })
  if (s < 86400) return t("age.hours", "{n} h ago", { n: Math.floor(s / 3600) })
  return t("age.days", "{n} d ago", { n: Math.floor(s / 86400) })
}

// MARK: Health

export function healthTone(h: Health | undefined): string {
  switch (h) {
    case "ok":
      return "success"
    case "degraded":
      return "warning"
    case "down":
      return "danger"
    default:
      return "tertiary"
  }
}

export function healthWord(h: Health | undefined): string {
  switch (h) {
    case "ok":
      return t("health.ok", "Healthy")
    case "degraded":
      return t("health.degraded", "Degraded")
    case "down":
      return t("health.down", "Down")
    default:
      return t("health.unknown", "Unknown")
  }
}

export const isHealthyAccount = (a: Account) => a.state === "active" || a.state === "refreshing"

export function accountTone(a: Account, now: number): string {
  if (!isHealthyAccount(a)) return a.state === "disabled" ? "tertiary" : "danger"
  if (a.cooldown_until_ms && a.cooldown_until_ms > now) return "warning"
  return "success"
}

export const accountStateWord = (a: Account, now: number) => stateWord(a.state, a.cooldown_until_ms, now)

export function stateWord(state: string, cooldownUntil: number | null | undefined, now: number): string {
  if (cooldownUntil && cooldownUntil > now && (state === "active" || state === "refreshing")) return t("account.cooling", "Cooling down")
  switch (state) {
    case "active":
      return t("account.active", "Active")
    case "refreshing":
      return t("account.refreshing", "Refreshing")
    case "expired":
      return t("account.expired", "Expired")
    case "broken":
      return t("account.broken", "Needs sign-in")
    case "disabled":
      return t("account.disabled", "Disabled")
    default:
      return state
  }
}

export const visibilityWord = (v: Visibility) => (v === "team" ? t("visibility.team", "Shared") : t("visibility.private", "Private"))

export function localStatusWord(d: Detected): string {
  switch (d.status) {
    case "signed_in":
      return d.provider === "openai" || d.provider === "anthropic" || d.provider === "openrouter" ? t("detect.key", "Key found") : t("detect.signedIn", "Signed in")
    case "expired":
      return t("detect.expired", "Expired")
    case "unknown":
      return t("detect.unknown", "Found")
    default:
      return t("detect.missing", "Not found")
  }
}

// MARK: Recommendation

/** The order the onboarding suggests connecting accounts: agent sign-ins first, then keys. */
export const PROVIDER_PRIORITY = ["codex", "claude", "openai", "anthropic", "openrouter", "bedrock"]

const rank = (p: string) => {
  const i = PROVIDER_PRIORITY.indexOf(p)
  return i < 0 ? PROVIDER_PRIORITY.length : i
}

export const isConnected = (provider: string, accounts: readonly Account[]) => accounts.some((a) => a.provider === provider)

/** Providers found on this Mac that CodeRouter can hold and that are not connected yet, best first. */
export function recommend(detected: readonly Detected[], accounts: readonly Account[]): Detected[] {
  return detected
    .filter((d) => d.linkable && d.status === "signed_in" && !isConnected(d.provider, accounts))
    .sort((a, b) => rank(a.provider) - rank(b.provider))
}

/** Found locally but not usable: an expired sign-in the user can renew. */
export const needsReauth = (detected: readonly Detected[]) => detected.filter((d) => d.status === "expired")

/** Relative bar lengths (0...1) for usage rows, by tokens. */
export function shares(rows: readonly UsageRow[]): number[] {
  const max = rows.reduce((m, r) => Math.max(m, r.total_tokens), 0)
  return rows.map((r) => (max > 0 ? r.total_tokens / max : 0))
}

/** Moves `id` to `index` (Reorderable's onMove), returning the new id order. */
export function moveTo(ids: readonly string[], id: string, index: number): string[] {
  const rest = ids.filter((x) => x !== id)
  if (rest.length === ids.length) return [...ids]
  const at = Math.max(0, Math.min(index, rest.length))
  return [...rest.slice(0, at), id, ...rest.slice(at)]
}

/** A short usage summary for the status item and the sidebar. */
export function usageSummary(u: Totals | null | undefined): string {
  if (!u || u.requests === 0) return t("usage.none", "No requests today")
  return t("usage.short", "{tokens} tok · {usd}", { tokens: formatTokens(u.total_tokens), usd: formatUsd(u.api_equivalent_usd) })
}
