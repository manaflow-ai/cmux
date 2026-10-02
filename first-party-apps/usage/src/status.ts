// The JSON the `status` command returns (`cmux apps run cmux/usage#status`,
// MCP tool). Pure, stable snake_case keys. Provider summaries and pace by
// default; account rows (with the router's labels) only when asked for.

import { isStale } from "./format.ts"
import type { Usage } from "./model.ts"
import { sessionPace, weeklyPace, type ProviderPace } from "./pace.ts"

export interface StatusArgs {
  provider?: string
  accounts?: boolean
  refresh?: boolean
}

const r2 = (n: number | null) => (n === null ? null : Math.round(n * 100) / 100)
const iso = (ms: number | null) => (ms === null ? null : new Date(ms).toISOString())

export function statusJSON(
  usage: Usage | null,
  paces: readonly ProviderPace[],
  options: { now: number; staleMs: number; state: string; problem: { code: string; message: string } | null; provider?: string; accounts?: boolean }
) {
  const at = usage?.fetchedAt ?? options.now
  const list = (usage?.providers ?? []).filter((p) => !options.provider || p.id === options.provider)
  return {
    state: options.state,
    problem: options.problem,
    fetched_at: iso(usage?.fetchedAt ?? null),
    stale: usage ? isStale(usage, options.now, options.staleMs) : false,
    providers: list.map((p) => {
      const pace = paces.find((x) => x.provider === p.id) ?? null
      return {
        id: p.id,
        summary: { usable: p.summary.usable, total: p.summary.total, weekly_left_sum_pct: p.summary.weeklyLeftSumPct },
        pace: pace && {
          verdict: pace.verdict,
          ratio: r2(pace.ratio),
          actual_pct_per_hour: r2(pace.actualPerHour),
          ideal_pct_per_hour: r2(pace.idealPerHour),
          left_sum_pct: pace.leftSumPct,
          counted: pace.counted,
          usable: pace.usable,
          baseline_at: iso(pace.baselineAt)
        },
        ...(options.accounts
          ? {
              accounts: p.accounts.map((a) => ({
                id: a.id,
                label: a.label,
                plan: a.plan,
                state: a.state,
                session_left_pct: a.session?.leftPct ?? null,
                session_reset_at: iso(a.session?.resetAt ?? null),
                weekly_left_pct: a.weekly?.leftPct ?? null,
                weekly_reset_at: iso(a.weekly?.resetAt ?? null),
                extra_usage_usd: a.extraUsd,
                weekly_pace: r2(weeklyPace(a, at)?.ratio ?? null),
                session_pace: r2(sessionPace(a, at)?.ratio ?? null)
              }))
            }
          : {})
      }
    })
  }
}
