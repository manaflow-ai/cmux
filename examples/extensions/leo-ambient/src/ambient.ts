// The model: what the three watch sources say, folded into what the rings, the checks line and the
// machine bars draw. Pure functions over the rows, so the views stay small and the tests need no host.

/** A `chat.list` row, only the fields this reads. */
export interface ChatRow {
  harness?: string | null
  family?: string | null
  state?: string | null
  usage?: { tokens_24h?: number | null; cost_usd_24h?: number | null } | null
  limits?: { windows?: { id: string; used_percent: number; resets_at?: number | null }[]; plan?: string | null } | null
}

/** One limit window of one provider: percent used and when it resets (Unix ms). */
export interface Window { usedPercent: number; resetsAtMs: number | null }

/** What one provider's agents spend: the rings are `session` (5 hours) and `weekly`. */
export interface Provider {
  id: string
  name: string
  chats: number
  working: number
  tokens24h: number | null
  costUsd24h: number | null
  session: Window | null
  weekly: Window | null
}

const NAMES: Record<string, string> = { claude: "Claude", codex: "Codex", gemini: "Gemini", opencode: "OpenCode", cursor: "Cursor", amp: "Amp" }
export const nameOf = (id: string) => NAMES[id] ?? id.charAt(0).toUpperCase() + id.slice(1)

const add = (a: number | null, b: number | null | undefined) => (typeof b === "number" && Number.isFinite(b) ? (a ?? 0) + b : a)

/** Each chat's account reports the same windows, so a provider's ring is its most used chat's
 * window: the one that will stop first. A count no chat reported stays null, never 0. */
function fuller(w: Window | null, id: string, row: ChatRow): Window | null {
  const found = row.limits?.windows?.find((x) => x.id === id)
  if (!found || !Number.isFinite(found.used_percent)) return w
  if (w && w.usedPercent >= found.used_percent) return w
  return { usedPercent: Math.min(100, Math.max(0, found.used_percent)), resetsAtMs: found.resets_at ? found.resets_at * 1000 : null }
}

/** Providers by spend, most first; a provider with no usage and no limits is left out. */
export function providers(rows: readonly ChatRow[]): Provider[] {
  const by = new Map<string, Provider>()
  for (const row of rows) {
    const id = (row.family || row.harness || "").toLowerCase()
    if (!id) continue
    const p = by.get(id) ?? { id, name: nameOf(id), chats: 0, working: 0, tokens24h: null, costUsd24h: null, session: null, weekly: null }
    p.chats += 1
    if (row.state === "working") p.working += 1
    p.tokens24h = add(p.tokens24h, row.usage?.tokens_24h)
    p.costUsd24h = add(p.costUsd24h, row.usage?.cost_usd_24h)
    p.session = fuller(p.session, "session", row)
    p.weekly = fuller(p.weekly, "weekly", row)
    by.set(id, p)
  }
  return [...by.values()]
    .filter((p) => p.tokens24h !== null || p.session || p.weekly)
    .sort((a, b) => (b.costUsd24h ?? 0) - (a.costUsd24h ?? 0) || (b.tokens24h ?? 0) - (a.tokens24h ?? 0) || a.name.localeCompare(b.name))
}

/** A `github.changes` item, only the fields this reads. */
export interface Change {
  id: number
  number: number
  title: string
  url: string
  repo: string
  draft: boolean
  checks: { state: "failing" | "pending" | "passing" | "none"; failing: number; pending: number; passing: number }
}

export type CiState = "failing" | "pending" | "passing" | "none"
export interface CiSummary { state: CiState; failing: number; pending: number; passing: number; total: number; worst: Change[] }

const RANK: Record<CiState, number> = { failing: 0, pending: 1, passing: 2, none: 3 }

/** The checks on the person's open pull requests: one word for all of them (any red is red), the
 * counts, and the pull requests to look at first (red, then running). */
export function ci(changes: readonly Change[]): CiSummary {
  const count = (s: CiState) => changes.filter((c) => c.checks.state === s).length
  const failing = count("failing"), pending = count("pending"), passing = count("passing")
  const state: CiState = failing ? "failing" : pending ? "pending" : passing ? "passing" : "none"
  const worst = [...changes].sort((a, b) => RANK[a.checks.state] - RANK[b.checks.state] || b.number - a.number)
  return { state, failing, pending, passing, total: changes.length, worst }
}

/** A `fleet.hosts` item, only the fields this reads. */
export interface Host {
  name: string
  reachable: boolean
  busy?: number | null
  liveSessions?: number | null
  deviceSymbol?: string | null
}

export interface FleetSummary { hosts: Host[]; reachable: number; busy: number | null; sessions: number }

/** The person's machines, busiest first, and the mean busy share of the ones that answered. */
export function fleet(hosts: readonly Host[]): FleetSummary {
  const up = hosts.filter((h) => h.reachable)
  const known = up.map((h) => h.busy).filter((b): b is number => typeof b === "number" && Number.isFinite(b))
  const busy = known.length ? known.reduce((a, b) => a + Math.min(1, Math.max(0, b)), 0) / known.length : null
  const sessions = up.reduce((a, h) => a + (h.liveSessions ?? 0), 0)
  const sorted = [...hosts].sort((a, b) => Number(b.reachable) - Number(a.reachable) || (b.busy ?? -1) - (a.busy ?? -1) || a.name.localeCompare(b.name))
  return { hosts: sorted, reachable: up.length, busy, sessions }
}

export function tokens(n: number | null): string {
  if (n === null) return "–"
  if (n >= 1e9) return `${(n / 1e9).toFixed(1)}B`
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`
  if (n >= 1e4) return `${(n / 1e3).toFixed(0)}k`
  return String(Math.round(n))
}
export const dollars = (n: number | null) => (n === null ? "–" : `$${n.toFixed(n >= 100 ? 0 : 2)}`)

export function countdown(at: number | null, now: number): string {
  if (at === null) return ""
  const min = Math.max(0, Math.round((at - now) / 60_000))
  if (min >= 1440) return `${Math.floor(min / 1440)}d ${Math.floor((min % 1440) / 60)}h`
  if (min >= 60) return `${Math.floor(min / 60)}h ${min % 60}m`
  return `${min}m`
}
