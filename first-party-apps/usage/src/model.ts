// The usage data model and its normalization from the proposed wire shapes
// (`usage.get`, `coderouter.usage.get`; README "Proposed operations"). Pure:
// no `cmux` calls here, so tests run it directly.

export type WindowKind = "session" | "weekly" | "monthly" | "daily" | "budget" | "credits" | "other"
export type AccountKind = "plan" | "api" | "pool"
export type Unit = "usd" | "tokens" | "requests" | "credits"

export interface UsageWindow {
  /** Stable within the account: "session", "weekly", "weekly:opus", "budget". */
  id: string
  kind: WindowKind
  /** The owner's English label, used only for kind "other". */
  label: string | null
  /** Model or feature the limit applies to ("Opus"); null for the main limit. */
  scope: string | null
  /** 0 to 100 (may exceed 100 when the provider reports overage). */
  usedPercent: number | null
  used: number | null
  limit: number | null
  unit: Unit | null
  windowSeconds: number | null
  resetsAt: number | null
}

export interface UsageError {
  code: string
  message: string
  retryable: boolean
}

export interface UsageAccount {
  /** Opaque and stable (`usage_account_…`); never an email. */
  id: string
  /** "claude-code", "codex", "anthropic-api", "openai-api", "coderouter". */
  provider: string
  providerTitle: string
  kind: AccountKind
  /** For pool accounts: the plan's own provider ("codex"); else null. */
  upstream: string | null
  /** "Personal", "Work": an email only when the user opted in at the service. */
  label: string | null
  plan: string | null
  windows: UsageWindow[]
  source: string | null
  fetchedAt: number | null
  stale: boolean
  error: UsageError | null
}

const KINDS: readonly WindowKind[] = ["session", "weekly", "monthly", "daily", "budget", "credits", "other"]
const UNITS: readonly Unit[] = ["usd", "tokens", "requests", "credits"]

type Json = Record<string, unknown>
const obj = (v: unknown): Json => (v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : {})
const str = (v: unknown): string | null => (typeof v === "string" && v.length > 0 ? v : null)
/** Numbers arrive as JSON numbers or, for 64-bit millisecond values, decimal strings (catalog convention). */
const num = (v: unknown): number | null => {
  const n = typeof v === "string" && v.trim() !== "" ? Number(v) : v
  return typeof n === "number" && Number.isFinite(n) ? n : null
}

/** The percent a window is used: the owner's percent, else used / limit. */
export function percentOf(w: UsageWindow): number | null {
  if (w.usedPercent !== null) return Math.max(0, w.usedPercent)
  if (w.used !== null && w.limit !== null && w.limit > 0) return Math.max(0, (w.used / w.limit) * 100)
  return null
}

export function normalizeWindow(raw: unknown, index: number): UsageWindow {
  const r = obj(raw)
  const kind = KINDS.includes(r.kind as WindowKind) ? (r.kind as WindowKind) : "other"
  const unit = UNITS.includes(r.unit as Unit) ? (r.unit as Unit) : null
  return {
    id: str(r.id) ?? `${kind}-${index}`,
    kind,
    label: str(r.label),
    scope: str(r.scope),
    usedPercent: num(r.used_percent),
    used: num(r.used),
    limit: num(r.limit),
    unit,
    windowSeconds: num(r.window_seconds),
    resetsAt: num(r.resets_at_ms)
  }
}

function normalizeError(raw: unknown): UsageError | null {
  if (!raw) return null
  const r = obj(raw)
  return { code: str(r.code) ?? "usage.failed", message: str(r.message) ?? "", retryable: r.retryable === true }
}

const KIND_ORDER: Record<WindowKind, number> = { session: 0, daily: 1, weekly: 2, monthly: 3, budget: 4, credits: 5, other: 6 }

/** Main limits first (session, weekly), model-scoped ones after their main window. */
export function sortWindows(windows: UsageWindow[]): UsageWindow[] {
  return [...windows].sort((a, b) => KIND_ORDER[a.kind] - KIND_ORDER[b.kind] || Number(a.scope !== null) - Number(b.scope !== null))
}

export function normalizeAccount(raw: unknown, fallbackKind: AccountKind = "plan"): UsageAccount | null {
  const r = obj(raw)
  const id = str(r.id)
  const provider = str(r.provider)
  if (!id || !provider) return null
  const kind = r.kind === "plan" || r.kind === "api" || r.kind === "pool" ? r.kind : fallbackKind
  const windows = Array.isArray(r.windows) ? r.windows.map(normalizeWindow) : []
  return {
    id,
    provider,
    providerTitle: str(r.provider_title) ?? provider,
    kind,
    upstream: str(r.upstream),
    label: str(r.label),
    plan: str(r.plan),
    windows: sortWindows(windows),
    source: str(r.source),
    fetchedAt: num(r.fetched_at_ms),
    stale: r.stale === true,
    error: normalizeError(r.error)
  }
}

/** `usage.get` result: `{accounts: [...]}`. */
export function normalizeUsage(value: unknown): UsageAccount[] {
  const list = obj(value).accounts
  return Array.isArray(list) ? list.map((a) => normalizeAccount(a)).filter((a): a is UsageAccount => a !== null) : []
}

/** `coderouter.usage.get` result: `{pools: [{id, name, accounts: [...]}]}`; each pool account becomes a "pool" account. */
export function normalizePools(value: unknown, poolWord: string): UsageAccount[] {
  const pools = obj(value).pools
  if (!Array.isArray(pools)) return []
  const out: UsageAccount[] = []
  for (const p of pools) {
    const pool = obj(p)
    const name = str(pool.name) ?? str(pool.id) ?? poolWord
    for (const raw of Array.isArray(pool.accounts) ? pool.accounts : []) {
      const r = obj(raw)
      const a = normalizeAccount({ ...r, provider: "coderouter", upstream: str(r.provider), kind: "pool" }, "pool")
      if (a) out.push({ ...a, id: `${str(pool.id) ?? name}/${a.id}`, providerTitle: "CodeRouter", label: [name, a.label].filter(Boolean).join(" · ") })
    }
  }
  return out
}

export type Severity = "normal" | "warning" | "danger"

/** danger at or above the highest threshold, warning at or above the lowest. */
export function severityOf(percent: number | null, thresholds: readonly number[]): Severity {
  if (percent === null || thresholds.length === 0) return "normal"
  const sorted = [...thresholds].sort((a, b) => a - b)
  if (percent >= sorted[sorted.length - 1]!) return "danger"
  if (percent >= sorted[0]!) return "warning"
  return "normal"
}

export interface Tightest {
  account: UsageAccount
  window: UsageWindow
  percent: number
}

/** The most used window across accounts without an account error; ties go to the earlier reset. */
export function tightest(accounts: readonly UsageAccount[]): Tightest | null {
  let best: Tightest | null = null
  for (const account of accounts) {
    if (account.error) continue
    for (const window of account.windows) {
      const percent = percentOf(window)
      if (percent === null) continue
      const earlier = best && percent === best.percent && (window.resetsAt ?? Infinity) < (best.window.resetsAt ?? Infinity)
      if (!best || percent > best.percent || earlier) best = { account, window, percent }
    }
  }
  return best
}

/** Session and weekly (main, unscoped) windows of one account: the pair the compact meters show. */
export function sessionAndWeek(account: UsageAccount): { session: UsageWindow | null; week: UsageWindow | null } {
  const main = account.windows.filter((w) => w.scope === null)
  return { session: main.find((w) => w.kind === "session") ?? null, week: main.find((w) => w.kind === "weekly") ?? null }
}
