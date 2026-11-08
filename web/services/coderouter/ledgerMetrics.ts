// Shared pieces of the customer-facing usage reads over the ClickHouse
// ledger (teamMetrics.ts, vmMetrics.ts): the summed columns, the 30-day UTC
// window, fail-closed row validation, and the failure-reason vocabulary the
// `coderouter.analytics_query` Sentry report has always used.
import type { ClickHouseFailure } from "./clickhouse";

export const PERIOD_DAYS = 30;

export const USAGE_COLUMNS = [
  "input_tokens",
  "cached_input_tokens",
  "output_tokens",
  "total_tokens",
  "api_equivalent_usd",
  "priced_tokens",
  "unpriced_tokens",
] as const;

/**
 * Summed columns every usage query selects, in USAGE_COLUMNS order. The sumIf
 * arguments are table-qualified because the `total_tokens` alias would
 * otherwise shadow the column (ClickHouse ILLEGAL_AGGREGATION).
 */
export const USAGE_SUMS_SQL = `
  sum(input_tokens) AS input_tokens,
  sum(cached_input_tokens) AS cached_input_tokens,
  sum(output_tokens) AS output_tokens,
  sum(total_tokens) AS total_tokens,
  sum(api_equivalent_usd) AS api_equivalent_usd,
  sumIf(usage_events.total_tokens, priced = 1) AS priced_tokens,
  sumIf(usage_events.total_tokens, priced = 0) AS unpriced_tokens`;

/** Inclusive UTC day window bound as `{start_day:Date}` and `{end_day:Date}`. */
export const DAY_WINDOW_SQL = `toDate(event_time) >= {start_day:Date}
  AND toDate(event_time) <= {end_day:Date}`;

export type UsageTotals = {
  readonly inputTokens: number;
  readonly cachedInputTokens: number;
  readonly outputTokens: number;
  readonly totalTokens: number;
  readonly apiEquivalentUsd: number;
  readonly pricedTokens: number;
  readonly unpricedTokens: number;
};

export type MutableTotals = { -readonly [Key in keyof UsageTotals]: UsageTotals[Key] };

export type QueryFailureReason =
  | "configuration_missing"
  | "request_failed"
  | "endpoint_status"
  | "malformed_response";

/** Maps a client failure onto the reason names the Sentry contract uses. */
export function queryFailure(
  failure: ClickHouseFailure,
): { readonly reason: QueryFailureReason; readonly status?: number } {
  switch (failure.reason) {
    case "disabled":
      return { reason: "configuration_missing" };
    case "status":
      return { reason: "endpoint_status", status: failure.status };
    case "malformed_response":
      return { reason: "malformed_response" };
    case "request_failed":
      return { reason: "request_failed" };
  }
}

/** The 30 UTC calendar days ending today, oldest first. */
export function periodDays(now: Date): readonly string[] {
  const end = new Date(Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate(),
  ));
  return Array.from({ length: PERIOD_DAYS }, (_, index) => {
    const date = new Date(end);
    date.setUTCDate(end.getUTCDate() - (PERIOD_DAYS - index - 1));
    return date.toISOString().slice(0, 10);
  });
}

export function dayWindowParams(now: Date): {
  readonly start_day: string;
  readonly end_day: string;
} {
  const days = periodDays(now);
  return { start_day: days[0]!, end_day: days[days.length - 1]! };
}

/** A row object whose keys are exactly `columns`, else `null`. */
export function rowRecord(
  value: unknown,
  columns: readonly string[],
): Record<string, unknown> | null {
  if (!isPlainRecord(value)) return null;
  const keys = Object.keys(value).sort();
  const expected = [...columns].sort();
  return keys.length === expected.length &&
      expected.every((key, index) => keys[index] === key)
    ? value
    : null;
}

export function parseTotals(record: Record<string, unknown>): UsageTotals | null {
  const inputTokens = nonNegativeNumber(record.input_tokens);
  const cachedInputTokens = nonNegativeNumber(record.cached_input_tokens);
  const outputTokens = nonNegativeNumber(record.output_tokens);
  const totalTokens = nonNegativeNumber(record.total_tokens);
  const apiEquivalentUsd = nonNegativeNumber(record.api_equivalent_usd);
  const pricedTokens = nonNegativeNumber(record.priced_tokens);
  const unpricedTokens = nonNegativeNumber(record.unpriced_tokens);
  if (
    inputTokens === null ||
    cachedInputTokens === null ||
    outputTokens === null ||
    totalTokens === null ||
    apiEquivalentUsd === null ||
    pricedTokens === null ||
    unpricedTokens === null ||
    cachedInputTokens > inputTokens ||
    pricedTokens + unpricedTokens !== totalTokens
  ) {
    return null;
  }
  return {
    inputTokens,
    cachedInputTokens,
    outputTokens,
    totalTokens,
    apiEquivalentUsd,
    pricedTokens,
    unpricedTokens,
  };
}

export function parseDay(value: unknown): string | null {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value)
    ? value
    : null;
}

export function addTotals(target: MutableTotals, source: UsageTotals): void {
  target.inputTokens += source.inputTokens;
  target.cachedInputTokens += source.cachedInputTokens;
  target.outputTokens += source.outputTokens;
  target.totalTokens += source.totalTokens;
  target.apiEquivalentUsd += source.apiEquivalentUsd;
  target.pricedTokens += source.pricedTokens;
  target.unpricedTokens += source.unpricedTokens;
}

export function emptyTotals(): MutableTotals {
  return {
    inputTokens: 0,
    cachedInputTokens: 0,
    outputTokens: 0,
    totalTokens: 0,
    apiEquivalentUsd: 0,
    pricedTokens: 0,
    unpricedTokens: 0,
  };
}

function nonNegativeNumber(value: unknown): number | null {
  // UInt64 sums arrive as numbers with quote_64bit_integers=0 and as strings
  // when a server default differs; accept both.
  const number = typeof value === "number"
    ? value
    : typeof value === "string" && value.trim()
    ? Number(value)
    : Number.NaN;
  return Number.isFinite(number) && number >= 0 ? number : null;
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
