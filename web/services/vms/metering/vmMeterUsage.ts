// Monthly usage per team and user, read from ClickHouse: VM seconds and vCPU
// seconds from `vm_runtime_intervals` (the deduplicated view over
// `vm_runtime_events`) and model tokens from the coderouter `usage_events`
// ledger. Stripe receives only these totals. `meteredSeconds` is the same
// arithmetic in TypeScript; tests and the live check compare the two.
import {
  defaultClickHouseDependencies,
  query,
  type ClickHouseDependencies,
  type ClickHouseFailure,
} from "../../coderouter/clickhouse";

export type MeterPeriod = { readonly start: Date; readonly end: Date };

/** Seconds of the intervals inside the period; open intervals run to `asOf`. */
export function meteredSeconds(
  intervals: readonly { readonly startedAt: Date; readonly endedAt: Date | null }[],
  period: MeterPeriod,
  asOf: Date,
): number {
  const cap = Math.min(asOf.getTime(), period.end.getTime());
  let ms = 0;
  for (const interval of intervals) {
    const end = Math.min(interval.endedAt?.getTime() ?? cap, cap);
    const start = Math.max(interval.startedAt.getTime(), period.start.getTime());
    if (end > start) ms += end - start;
  }
  return Math.round(ms / 1000);
}

export type MonthlyUsageRow = {
  readonly teamId: string;
  readonly userId: string;
  readonly vmSeconds: number;
  readonly vcpuSeconds: number;
  readonly intervals: number;
  readonly inputTokens: number;
  readonly cachedInputTokens: number;
  readonly outputTokens: number;
  readonly apiEquivalentUsd: number;
};

const OVERLAP_MS = `greatest(toInt64(0), dateDiff('millisecond',
      greatest(started_at, {period_start:DateTime64(3, 'UTC')}),
      least(ifNull(ended_at, {as_of:DateTime64(3, 'UTC')}), {as_of:DateTime64(3, 'UTC')})))`;

export const VM_MONTHLY_USAGE_SQL = `SELECT team_id, stack_user_id,
  round(sum(${OVERLAP_MS}) / 1000) AS vm_seconds,
  round(sum(${OVERLAP_MS} * vcpus) / 1000) AS vcpu_seconds,
  count() AS intervals
FROM {db}.vm_runtime_intervals
WHERE started_at < {as_of:DateTime64(3, 'UTC')}
  AND (ended_at IS NULL OR ended_at > {period_start:DateTime64(3, 'UTC')})
GROUP BY team_id, stack_user_id`;

export const TOKEN_MONTHLY_USAGE_SQL = `SELECT team_id, stack_user_id,
  sum(input_tokens) AS input_tokens,
  sum(cached_input_tokens) AS cached_input_tokens,
  sum(output_tokens) AS output_tokens,
  sum(api_equivalent_usd) AS api_equivalent_usd
FROM {db}.usage_events
WHERE event_time >= {period_start:DateTime64(3, 'UTC')}
  AND event_time < {period_end:DateTime64(3, 'UTC')}
GROUP BY team_id, stack_user_id`;

type VmRow = { team_id?: unknown; stack_user_id?: unknown; vm_seconds?: unknown; vcpu_seconds?: unknown; intervals?: unknown };
type TokenRow = {
  team_id?: unknown; stack_user_id?: unknown; input_tokens?: unknown;
  cached_input_tokens?: unknown; output_tokens?: unknown; api_equivalent_usd?: unknown;
};

export type MonthlyUsageDependencies = {
  readonly clickhouse?: ClickHouseDependencies;
  readonly now?: () => Date;
};

/** Usage for one UTC calendar month (`month` is 1-12). */
export async function monthlyUsage(
  month: { readonly year: number; readonly month: number },
  dependencies: MonthlyUsageDependencies = {},
): Promise<{ readonly ok: true; readonly rows: MonthlyUsageRow[] } | ClickHouseFailure> {
  const period = {
    start: new Date(Date.UTC(month.year, month.month - 1, 1)),
    end: new Date(Date.UTC(month.year, month.month, 1)),
  };
  return usageForPeriod(period, dependencies);
}

/** Usage for any period, for subscription periods that are not calendar months. */
export async function usageForPeriod(
  period: MeterPeriod,
  dependencies: MonthlyUsageDependencies = {},
): Promise<{ readonly ok: true; readonly rows: MonthlyUsageRow[] } | ClickHouseFailure> {
  const clickhouse = dependencies.clickhouse ?? defaultClickHouseDependencies;
  const now = (dependencies.now ?? (() => new Date()))();
  const asOf = new Date(Math.min(now.getTime(), period.end.getTime()));
  const params = {
    period_start: clickHouseTime(period.start),
    period_end: clickHouseTime(period.end),
    as_of: clickHouseTime(asOf),
  };
  const [vm, tokens] = await Promise.all([
    query<VmRow>(VM_MONTHLY_USAGE_SQL, params, clickhouse),
    query<TokenRow>(TOKEN_MONTHLY_USAGE_SQL, params, clickhouse),
  ]);
  if (!vm.ok) return vm;
  if (!tokens.ok) return tokens;
  return { ok: true, rows: mergeMonthlyUsage(vm.rows, tokens.rows) };
}

/** One row per team and user that had VM time or tokens, sorted by team then user. */
export function mergeMonthlyUsage(vmRows: readonly VmRow[], tokenRows: readonly TokenRow[]): MonthlyUsageRow[] {
  const rows = new Map<string, MonthlyUsageRow>();
  const empty = (teamId: string, userId: string): MonthlyUsageRow => ({
    teamId, userId, vmSeconds: 0, vcpuSeconds: 0, intervals: 0,
    inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, apiEquivalentUsd: 0,
  });
  for (const row of vmRows) {
    const teamId = String(row.team_id ?? "");
    const userId = String(row.stack_user_id ?? "");
    const key = `${teamId}\u0000${userId}`;
    rows.set(key, {
      ...(rows.get(key) ?? empty(teamId, userId)),
      vmSeconds: num(row.vm_seconds), vcpuSeconds: num(row.vcpu_seconds), intervals: num(row.intervals),
    });
  }
  for (const row of tokenRows) {
    const teamId = String(row.team_id ?? "");
    const userId = String(row.stack_user_id ?? "");
    const key = `${teamId}\u0000${userId}`;
    rows.set(key, {
      ...(rows.get(key) ?? empty(teamId, userId)),
      inputTokens: num(row.input_tokens), cachedInputTokens: num(row.cached_input_tokens),
      outputTokens: num(row.output_tokens), apiEquivalentUsd: num(row.api_equivalent_usd),
    });
  }
  return [...rows.values()].sort((a, b) => a.teamId.localeCompare(b.teamId) || a.userId.localeCompare(b.userId));
}

/** `2026-10-01 00:00:00.000`, the text form DateTime64 parameters accept. */
export function clickHouseTime(date: Date): string {
  return date.toISOString().replace("T", " ").replace("Z", "");
}

function num(value: unknown): number {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}
