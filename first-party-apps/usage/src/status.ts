// The JSON the `status` command returns (CLI `cmux apps run cmux/usage#status`,
// MCP tool). Pure: stable snake_case keys for agents, no credentials, no emails
// (the service never sends them unless the user opted in).

import { isStale } from "./format.ts"
import { percentOf, severityOf, tightest, type UsageAccount } from "./model.ts"
import { paceOf } from "./pace.ts"

export interface StatusArgs {
  provider?: string
  refresh?: boolean
}

const round1 = (n: number) => Math.round(n * 10) / 10

export function statusJSON(accounts: readonly UsageAccount[], options: { now: number; staleMs: number; thresholds: readonly number[]; state: string; problem: { code: string; message: string } | null; provider?: string }) {
  const { now } = options
  const list = options.provider ? accounts.filter((a) => a.provider === options.provider) : accounts
  const top = tightest(list)
  return {
    generated_at_ms: now,
    state: options.state,
    problem: options.problem,
    tightest: top
      ? { account: top.account.id, provider: top.account.provider, window: top.window.id, used_percent: round1(top.percent), resets_at_ms: top.window.resetsAt }
      : null,
    accounts: list.map((a) => ({
      id: a.id,
      provider: a.provider,
      provider_title: a.providerTitle,
      kind: a.kind,
      upstream: a.upstream,
      label: a.label,
      plan: a.plan,
      source: a.source,
      fetched_at_ms: a.fetchedAt,
      stale: isStale(a, now, options.staleMs),
      error: a.error,
      windows: a.windows.map((w) => {
        const percent = percentOf(w)
        const pace = paceOf(w, now)
        return {
          id: w.id,
          kind: w.kind,
          scope: w.scope,
          used_percent: percent === null ? null : round1(percent),
          used: w.used,
          limit: w.limit,
          unit: w.unit,
          window_seconds: w.windowSeconds,
          resets_at_ms: w.resetsAt,
          resets_in_seconds: w.resetsAt === null ? null : Math.max(0, Math.round((w.resetsAt - now) / 1000)),
          severity: severityOf(percent, options.thresholds),
          pace: pace
            ? { expected_percent: round1(pace.expectedPercent), delta_percent: round1(pace.deltaPercent), runs_out_at_ms: pace.runsOutAt === null ? null : Math.round(pace.runsOutAt), lasts_to_reset: pace.lastsToReset }
            : null
        }
      })
    }))
  }
}
