// Invented usage data relative to `now`, in the proposed wire shapes. Shared by
// the bun tests and `preview/build.ts` (which writes the preview harness
// fixture files). No real accounts, emails or tokens.

const MIN = 60_000
const HOUR = 60 * MIN
const DAY = 24 * HOUR

/** A window that resets `left` ms from now and is `length` seconds long. */
const win = (now: number, id: string, kind: string, percent: number, lengthSeconds: number, left: number, scope: string | null = null) => ({
  id,
  kind,
  scope,
  used_percent: percent,
  window_seconds: lengthSeconds,
  resets_at_ms: String(now + left)
})

export function usageValue(now: number, options: { fetchedAgo?: number; stale?: boolean; codexError?: boolean } = {}) {
  const fetched = String(now - (options.fetchedAgo ?? 2 * MIN))
  const stale = options.stale ?? false
  return {
    revision: "7",
    accounts: [
      {
        id: "usage_account_1",
        provider: "claude-code",
        provider_title: "Claude Code",
        kind: "plan",
        label: "Personal",
        plan: "Max 20x",
        source: "oauth",
        fetched_at_ms: fetched,
        stale,
        error: null,
        windows: [
          win(now, "session", "session", 62, 5 * 3600, 2 * HOUR + 10 * MIN),
          win(now, "weekly", "weekly", 41, 7 * 86400, 3 * DAY + 4 * HOUR),
          win(now, "weekly:opus", "weekly", 83, 7 * 86400, 3 * DAY + 4 * HOUR, "Opus")
        ]
      },
      {
        id: "usage_account_2",
        provider: "codex",
        provider_title: "Codex",
        kind: "plan",
        label: "Work",
        plan: "Plus",
        source: "oauth",
        fetched_at_ms: fetched,
        stale,
        error: options.codexError ? { code: "auth.expired", message: "Sign-in expired. Run codex login.", retryable: false } : null,
        windows: options.codexError
          ? []
          : [win(now, "session", "session", 18, 5 * 3600, 4 * HOUR + 2 * MIN), win(now, "weekly", "weekly", 87, 7 * 86400, 1 * DAY + 6 * HOUR)]
      },
      {
        id: "usage_account_3",
        provider: "anthropic-api",
        provider_title: "Anthropic API",
        kind: "api",
        label: "Team key",
        plan: null,
        source: "admin-api",
        fetched_at_ms: fetched,
        stale,
        error: null,
        windows: [{ id: "budget", kind: "budget", used: 42.5, limit: 100, unit: "usd", window_seconds: 30 * 86400, resets_at_ms: String(now + 12 * DAY + 3 * HOUR) }]
      }
    ]
  }
}

export function poolsValue(now: number) {
  return {
    pools: [
      {
        id: "pool_team",
        name: "team",
        accounts: [
          {
            id: "seat_a",
            provider: "claude-code",
            label: "Seat A",
            plan: "Max 20x",
            fetched_at_ms: String(now - 3 * MIN),
            windows: [win(now, "session", "session", 34, 5 * 3600, 1 * HOUR + 25 * MIN), win(now, "weekly", "weekly", 55, 7 * 86400, 5 * DAY + 2 * HOUR)]
          },
          {
            id: "seat_b",
            provider: "codex",
            label: "Seat B",
            plan: "Pro",
            fetched_at_ms: String(now - 3 * MIN),
            windows: [win(now, "session", "session", 71, 5 * 3600, 3 * HOUR + 40 * MIN), win(now, "weekly", "weekly", 24, 7 * 86400, 6 * DAY)]
          }
        ]
      }
    ]
  }
}

/** Scope table entries for the proposed operations (preview harness `scopes`). */
export const proposedScopes = {
  "usage.get": { scope: "usage:read", class: "read" },
  "usage.refresh": { scope: "usage:write", class: "mutation" },
  "coderouter.usage.get": { scope: "coderouter:read", class: "read" },
  "app.settings.set": { scope: "settings:write", class: "mutation" }
}

export const grant = ["usage:read", "usage:write", "notification:write", "coderouter:read", "mcp:expose", "actions:run"]
