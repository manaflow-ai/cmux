// The Chief Usage page's op (`cmux.chief_usage.summary`): the app runs the bundled
// `optchat-chief usage --json` over this Mac's Chief homes and returns its summary as is
// (plans/cmux-next/chief-usage-analytics-DESIGN.md, section 3). Field names follow that JSON.

export const ChiefUsageOps = {
  /** `{since, by, top}` → `UsageSummary`. */
  summary: "cmux.chief_usage.summary",
} as const;

/** The windows the page offers, as `optchat-chief usage --since` values. */
export const WINDOWS = ["24h", "7d", "30d", "90d", "1y"] as const;
export type UsageWindow = (typeof WINDOWS)[number];

/** What the breakdown table groups by (`--by`). */
export const BY_KEYS = ["chief", "agent", "model", "harness", "kind"] as const;
export type UsageBy = (typeof BY_KEYS)[number];

/** The bucket the tool picked from the window: ≤ 2 d hour, ≤ 60 d day, ≤ 1 y week, else month. */
export type UsageBucket = "hour" | "day" | "week" | "month";

/** A billable unit: a Chief turn, a compactor node or a subagent prompt. */
export type UsageKind = "turn" | "compactor" | "subagent";

/** The params the page sends with `cmux.chief_usage.summary`. */
export interface UsageQuery {
  since: UsageWindow;
  by: UsageBy;
  top: number;
}

export interface UsageTokens {
  input: number;
  output: number;
  cache_read: number;
  cache_write: number;
}

/**
 * Sums over every unit in a window (or bucket, or group). `hit` is
 * `cache_read / (cache_read + cache_write + input)`; null with no prompt tokens. Latency
 * percentiles are over `turn` units only; null when no turn ran.
 */
export interface UsageTotals extends UsageTokens {
  units: number;
  turns: number;
  usd: number;
  hit: number | null;
  ms_p50: number | null;
  ms_p95: number | null;
  ttft_p50?: number | null;
  ttft_p95?: number | null;
  start_p50?: number | null;
  start_p95?: number | null;
}

/** One bucket of the series; `t` is the bucket's start (unix ms, local time boundary). */
export interface UsagePoint extends UsageTokens {
  t: number;
  units: number;
  turns: number;
  usd: number;
  hit: number | null;
  ms_p50: number | null;
  ms_p95: number | null;
}

export interface UsageChief {
  id: string;
  label: string;
  home: string;
}

/** One breakdown row. `key` is empty for units with no value for the group (no subagent). */
export interface UsageGroup extends UsageTotals {
  key: string;
  label: string;
}

/** One of the most expensive units. `link` opens its chat; a compactor node has none. */
export interface UsageTopUnit extends UsageTokens {
  ts: number;
  chief: string;
  kind: UsageKind;
  agent: string | null;
  key: string;
  model: string | null;
  usd: number;
  ms: number | null;
  link?: string | null;
}

export interface UsageSummary {
  v: 1;
  since: number;
  until: number;
  bucket: UsageBucket;
  chiefs: UsageChief[];
  totals: UsageTotals;
  /** Every bucket of the window, oldest first, empty ones included. */
  series: UsagePoint[];
  /** Sorted by cost, most first. */
  by: UsageGroup[];
  /** Sorted by cost, most first. */
  top: UsageTopUnit[];
}
