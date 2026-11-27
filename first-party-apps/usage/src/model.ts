// The usage data model and its normalization from the proposed wire shapes
// (`account.list`, `account.usage`; README "Data shape"). `account.list` is the
// local router's status schema (`providers.<id>.accounts[]` plus a summary per
// provider) with a small envelope the usage server adds. Pure: no `cmux`
// calls here, so tests run it directly.

/** Router account states, most limiting first (the router's own order). */
export const STATES = ["error", "cooked", "temp", "active", "rec", "protected", "ready"] as const
export type AccountState = (typeof STATES)[number] | "unknown"

export interface Window {
  /** 0 to 100: what is left of the window. */
  leftPct: number
  /** Epoch ms of the reset, or null when the router does not know it. */
  resetAt: number | null
}

export interface Account {
  /** The router's id: opaque and stable. */
  id: string
  /** The router's label, shown as the router shows it. */
  label: string
  provider: string
  plan: string | null
  state: AccountState
  /** The 5-hour window; null for providers without one. */
  session: Window | null
  /** The weekly window; null for keyed providers. */
  weekly: Window | null
  /** Extra usage money still available, in USD. */
  extraUsd: number | null
  /** "subrouter" or "coderouter": which router reported it. */
  source: string | null
}

export interface ProviderSummary {
  usable: number
  total: number
  weeklyLeftSumPct: number
}

export interface Provider {
  id: string
  accounts: Account[]
  summary: ProviderSummary
}

export interface SourceStatus {
  id: string
  ok: boolean
  error: { code: string; message: string } | null
}

export interface Usage {
  /** The server's reading time (epoch ms): when the router last answered. */
  fetchedAt: number | null
  /** The server missed its own refreshes. */
  stale: boolean
  /** The last refresh failed; the providers are the last good reading. */
  error: { code: string; message: string } | null
  sources: SourceStatus[]
  providers: Provider[]
}

/** One history snapshot: the weekly window of every account at one time. */
export interface Snapshot {
  at: number
  accounts: Map<string, { provider: string; state: AccountState; weeklyLeftPct: number | null; weeklyResetAt: number | null }>
}

type Json = Record<string, unknown>
const obj = (v: unknown): Json => (v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : {})
const str = (v: unknown): string | null => (typeof v === "string" && v.length > 0 ? v : null)
/** Numbers arrive as JSON numbers or, for 64-bit millisecond values, decimal strings (catalog convention). */
export const num = (v: unknown): number | null => {
  const n = typeof v === "string" && v.trim() !== "" ? Number(v) : v
  return typeof n === "number" && Number.isFinite(n) ? n : null
}
/** ISO 8601 text or epoch milliseconds to epoch milliseconds. */
export function time(v: unknown): number | null {
  if (typeof v === "string" && /^\d{4}-\d\d-\d\dT/.test(v)) {
    const ms = Date.parse(v)
    return Number.isFinite(ms) ? ms : null
  }
  return num(v)
}
const pct = (v: unknown): number | null => {
  const n = num(v)
  return n === null ? null : Math.min(100, Math.max(0, n))
}

export const stateOf = (v: unknown): AccountState => ((STATES as readonly unknown[]).includes(v) ? (v as AccountState) : "unknown")

/** Usable: the router may route to it (not cooked, temp or error). */
export const isUsable = (s: AccountState) => s !== "cooked" && s !== "temp" && s !== "error"

function window(left: unknown, reset: unknown): Window | null {
  const leftPct = pct(left)
  return leftPct === null ? null : { leftPct, resetAt: time(reset) }
}

export function normalizeAccount(raw: unknown, provider: string): Account | null {
  const r = obj(raw)
  const id = str(r.id)
  if (!id) return null
  return {
    id,
    label: str(r.label) ?? id,
    provider: str(r.provider) ?? provider,
    plan: str(r.plan),
    state: stateOf(r.state),
    session: window(r.session_left_pct, r.session_reset_at),
    weekly: window(r.weekly_left_pct, r.weekly_reset_at),
    extraUsd: num(r.extra_usage_usd),
    source: str(r.source)
  }
}

/** In use first, then usable, then held out, then broken; within a state the earliest weekly reset first (use it or lose it). */
const DISPLAY_RANK: Record<AccountState, number> = { active: 0, rec: 1, ready: 2, protected: 3, temp: 4, cooked: 5, error: 6, unknown: 7 }

export function sortAccounts(accounts: Account[]): Account[] {
  return [...accounts].sort(
    (a, b) => DISPLAY_RANK[a.state] - DISPLAY_RANK[b.state] || (a.weekly?.resetAt ?? Infinity) - (b.weekly?.resetAt ?? Infinity) || a.label.localeCompare(b.label)
  )
}

/** The router's summary, recomputed when it is missing (same rule: usable = not cooked, temp or error). */
export function summarize(accounts: readonly Account[]): ProviderSummary {
  const usable = accounts.filter((a) => isUsable(a.state))
  return { usable: usable.length, total: accounts.length, weeklyLeftSumPct: usable.reduce((sum, a) => sum + (a.weekly?.leftPct ?? 0), 0) }
}

/** Claude and Codex first, the rest by id. */
const PROVIDER_ORDER = ["claude", "codex"]
const providerRank = (id: string) => {
  const i = PROVIDER_ORDER.indexOf(id)
  return i < 0 ? PROVIDER_ORDER.length : i
}

export function normalizeProviders(raw: unknown): Provider[] {
  const out: Provider[] = []
  for (const [id, value] of Object.entries(obj(raw))) {
    const p = obj(value)
    const accounts = (Array.isArray(p.accounts) ? p.accounts : []).map((a) => normalizeAccount(a, id)).filter((a): a is Account => a !== null)
    const s = obj(p.summary)
    const usable = num(s.usable)
    const total = num(s.total)
    const left = num(s.weekly_left_sum_pct)
    const summary = usable !== null && total !== null && left !== null ? { usable, total, weeklyLeftSumPct: left } : summarize(accounts)
    out.push({ id, accounts: sortAccounts(accounts), summary })
  }
  return out.sort((a, b) => providerRank(a.id) - providerRank(b.id) || a.id.localeCompare(b.id))
}

function normalizeError(raw: unknown): { code: string; message: string } | null {
  if (!raw) return null
  const r = obj(raw)
  return { code: str(r.code) ?? "usage.failed", message: str(r.message) ?? "" }
}

/** `account.list` result. */
export function normalizeUsage(value: unknown): Usage {
  const r = obj(value)
  const sources = (Array.isArray(r.sources) ? r.sources : []).map((s) => {
    const o = obj(s)
    const error = normalizeError(o.error)
    return { id: str(o.id) ?? "router", ok: o.ok !== false && error === null, error }
  })
  return {
    fetchedAt: time(r.fetched_at_ms) ?? time(r.generated_at),
    stale: r.stale === true,
    error: normalizeError(r.error),
    sources,
    providers: normalizeProviders(r.providers)
  }
}

/** `account.usage` result: `{snapshots: [{taken_at_ms, accounts: [{provider, id, state, weekly_left_pct, weekly_reset_at}]}]}`. */
export function normalizeHistory(value: unknown): Snapshot[] {
  const list = obj(value).snapshots
  if (!Array.isArray(list)) return []
  const out: Snapshot[] = []
  for (const raw of list) {
    const r = obj(raw)
    const at = time(r.taken_at_ms)
    if (at === null) continue
    const accounts: Snapshot["accounts"] = new Map()
    for (const a of Array.isArray(r.accounts) ? r.accounts : []) {
      const o = obj(a)
      const id = str(o.id)
      const provider = str(o.provider)
      if (!id || !provider) continue
      accounts.set(`${provider}/${id}`, { provider, state: stateOf(o.state), weeklyLeftPct: pct(o.weekly_left_pct), weeklyResetAt: time(o.weekly_reset_at) })
    }
    out.push({ at, accounts })
  }
  return out.sort((a, b) => a.at - b.at)
}

/** The current reading as a snapshot (the pace compares it with an older one). */
export function snapshotOf(usage: Usage, at: number): Snapshot {
  const accounts: Snapshot["accounts"] = new Map()
  for (const p of usage.providers) {
    for (const a of p.accounts) {
      accounts.set(`${p.id}/${a.id}`, { provider: p.id, state: a.state, weeklyLeftPct: a.weekly?.leftPct ?? null, weeklyResetAt: a.weekly?.resetAt ?? null })
    }
  }
  return { at, accounts }
}
