// Invented usage data relative to `now`, in the proposed wire shapes
// (`account.list`: the router status schema plus the server's envelope;
// `account.usage`: compact snapshots). Shared by the bun tests and
// `preview/build.ts`. No real accounts, labels, ids, emails or tokens.

const MIN = 60_000
const HOUR = 60 * MIN
const DAY = 24 * HOUR

type Raw = {
  id: string
  label: string
  provider: string
  plan: string | null
  state: string
  session_left_pct: number | null
  session_reset_at: string | null
  weekly_left_pct: number | null
  weekly_reset_at: string | null
  extra_usage_usd: number | null
  source: string
}

const iso = (ms: number) => new Date(ms).toISOString()

function acct(now: number, provider: string, n: number, label: string, state: string, session: [number, number] | null, weekly: [number, number] | null, extra: number | null = null, plan: string | null = null): Raw {
  return {
    id: `${provider}_acct_${n}`,
    label,
    provider,
    plan,
    state,
    session_left_pct: session ? session[0] : null,
    session_reset_at: session ? iso(now + session[1]) : null,
    weekly_left_pct: weekly ? weekly[0] : null,
    weekly_reset_at: weekly ? iso(now + weekly[1]) : null,
    extra_usage_usd: extra,
    source: "subrouter"
  }
}

export function accountsAt(now: number): Record<string, Raw[]> {
  return {
    claude: [
      acct(now, "claude", 1, "alder", "active", [41, 2 * HOUR + 10 * MIN], [58, 2 * DAY + 4 * HOUR]),
      acct(now, "claude", 2, "birch", "rec", [100, 4 * HOUR + 50 * MIN], [72, 4 * DAY + 9 * HOUR]),
      acct(now, "claude", 3, "cedar", "ready", [88, 3 * HOUR + 5 * MIN], [34, 19 * HOUR], 12.5),
      acct(now, "claude", 4, "dogwood", "protected", [96, 1 * HOUR + 40 * MIN], [9, 3 * DAY + 2 * HOUR]),
      acct(now, "claude", 5, "elm", "temp", [0, 38 * MIN], [47, 5 * DAY + 1 * HOUR]),
      acct(now, "claude", 6, "fir", "cooked", [100, 4 * HOUR], [0, 1 * DAY + 7 * HOUR]),
      acct(now, "claude", 7, "ginkgo", "error", null, null)
    ],
    codex: [
      acct(now, "codex", 1, "harbor", "active", null, [44, 3 * DAY + 6 * HOUR], null, "pro"),
      acct(now, "codex", 2, "inlet", "rec", null, [81, 6 * DAY + 2 * HOUR], null, "pro"),
      acct(now, "codex", 3, "jetty", "ready", null, [63, 4 * DAY + 11 * HOUR], null, "team"),
      acct(now, "codex", 4, "keel", "ready", null, [27, 1 * DAY + 3 * HOUR], null, "pro"),
      acct(now, "codex", 5, "lagoon", "protected", null, [12, 2 * DAY + 20 * HOUR], null, "pro"),
      acct(now, "codex", 6, "marina", "cooked", null, [0, 5 * DAY + 8 * HOUR], null, "pro")
    ],
    kimi: [acct(now, "kimi", 1, "key-one", "rec", null, null, null, "API key")]
  }
}

const summary = (accounts: Raw[]) => {
  const usable = accounts.filter((a) => a.state !== "cooked" && a.state !== "temp" && a.state !== "error")
  return { usable: usable.length, total: accounts.length, weekly_left_sum_pct: usable.reduce((s, a) => s + (a.weekly_left_pct ?? 0), 0) }
}

export interface UsageOptions {
  fetchedAgo?: number
  stale?: boolean
  error?: { code: string; message: string } | null
  sources?: Array<{ id: string; ok: boolean; error: { code: string; message: string } | null }>
  only?: string[]
}

export function usageValue(now: number, options: UsageOptions = {}) {
  const fetched = now - (options.fetchedAgo ?? 2 * MIN)
  const all = accountsAt(fetched)
  const providers: Record<string, { accounts: Raw[]; summary: ReturnType<typeof summary> }> = {}
  for (const [id, accounts] of Object.entries(all)) if (!options.only || options.only.includes(id)) providers[id] = { accounts, summary: summary(accounts) }
  return {
    schema_version: 1,
    generated_at: iso(fetched),
    fetched_at_ms: String(fetched),
    stale: options.stale ?? false,
    error: options.error ?? null,
    sources: options.sources ?? [
      { id: "subrouter", ok: true, error: null },
      { id: "coderouter", ok: true, error: null }
    ],
    providers
  }
}

/**
 * One snapshot `ago` before the reading, built so each provider's actual burn
 * is `ratios[provider]` times its ideal burn: the drop is spread over the
 * accounts that are in use or next.
 */
export function historyValue(now: number, ratios: Record<string, number>, options: { fetchedAgo?: number; ago?: number } = {}) {
  const fetched = now - (options.fetchedAgo ?? 2 * MIN)
  const ago = options.ago ?? 45 * MIN
  const accounts = accountsAt(fetched)
  const rows: Array<{ provider: string; id: string; state: string; weekly_left_pct: number | null; weekly_reset_at: string | null }> = []
  for (const [provider, list] of Object.entries(accounts)) {
    const counted = list.filter((a) => a.state !== "error")
    let ideal = 0
    for (const a of counted) if (a.weekly_left_pct !== null && a.weekly_reset_at) ideal += a.weekly_left_pct / ((Date.parse(a.weekly_reset_at) - fetched) / HOUR)
    const burners = counted.filter((a) => (a.state === "active" || a.state === "rec") && a.weekly_left_pct !== null)
    const drop = (ratios[provider] ?? 1) * ideal * (ago / HOUR)
    for (const a of list) {
      const extra = burners.includes(a) ? drop / burners.length : 0
      rows.push({ provider, id: a.id, state: a.state, weekly_left_pct: a.weekly_left_pct === null ? null : a.weekly_left_pct + extra, weekly_reset_at: a.weekly_reset_at })
    }
  }
  return { snapshots: [{ taken_at_ms: String(fetched - ago), accounts: rows }] }
}

/** Scope table entries for the proposed operations (preview harness `scopes`). */
export const proposedScopes = {
  "account.list": { scope: "account:read", class: "read" },
  "account.usage": { scope: "account:read", class: "read" },
  "account.refresh": { scope: "account:write", class: "mutation" },
  "app.settings.set": { scope: "settings:write", class: "mutation" }
}

export const grant = ["account:read", "account:write", "notification:write", "mcp:expose", "actions:run"]

/** Claude on pace, Codex over pace. */
export const DEFAULT_RATIOS = { claude: 1.0, codex: 1.4 }
