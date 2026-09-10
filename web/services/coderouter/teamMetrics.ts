// Customer-facing 30-day usage for a team, read from the ClickHouse ledger
// (`usage_events`). Aggregate token totals and API-equivalent dollars only;
// model, provider, member, and machine never leave this module. Reads are
// cached for five minutes and fail closed to `unavailable`.
import { unstable_cache } from "next/cache";

import { captureCoderouterEvent } from "./analytics";
import { CODEROUTER_API_RATE_CARD_VERSION } from "./apiEquivalentPricing";
import {
  defaultClickHouseDependencies,
  query,
  type ClickHouseDependencies,
} from "./clickhouse";
import {
  addTotals,
  DAY_WINDOW_SQL,
  dayWindowParams,
  emptyTotals,
  parseDay,
  parseTotals,
  PERIOD_DAYS,
  periodDays,
  queryFailure,
  rowRecord,
  USAGE_COLUMNS,
  USAGE_SUMS_SQL,
  type MutableTotals,
} from "./ledgerMetrics";
import { reportCoderouterFailure } from "./observability";

const MAX_ROWS = PERIOD_DAYS;
const EXPECTED_COLUMNS = ["day", ...USAGE_COLUMNS] as const;

// LIMIT 31 fetches one overflow sentinel; the app rejects more than 30 rows
// instead of silently trimming if the day window ever widens.
const TEAM_USAGE_SQL = `SELECT
  toString(toDate(event_time)) AS day,${USAGE_SUMS_SQL}
FROM {db}.usage_events
WHERE team_id = {team_id:String}
  AND ${DAY_WINDOW_SQL}
GROUP BY day
ORDER BY day ASC
LIMIT 31`;

type MetricsDependencies = {
  readonly clickhouse: ClickHouseDependencies;
  readonly now: () => Date;
  readonly reportFailure?: (reason: string, status?: number) => void;
};

export type CoderouterTeamMetricsTotals = {
  readonly inputTokens: number;
  readonly cachedInputTokens: number;
  readonly outputTokens: number;
  readonly totalTokens: number;
  readonly apiEquivalentUsd: number;
  readonly pricedTokens: number;
  readonly unpricedTokens: number;
};

export type CoderouterTeamMetricsDay = {
  readonly day: string;
  readonly totalTokens: number;
  readonly apiEquivalentUsd: number;
};

export type CoderouterTeamMetrics =
  | { readonly kind: "unavailable" }
  | {
      readonly kind: "ready";
      readonly periodDays: number;
      readonly generatedAt: string;
      readonly rateCardVersion: string;
      readonly totals: CoderouterTeamMetricsTotals;
      readonly daily: readonly CoderouterTeamMetricsDay[];
    };

const defaultDependencies: MetricsDependencies = {
  clickhouse: defaultClickHouseDependencies,
  now: () => new Date(),
  reportFailure: (reason, status) => {
    reportCoderouterFailure(
      "analytics_query",
      new Error("CodeRouter analytics query failed"),
      {
        reason,
        ...(status === undefined ? {} : { status }),
      },
    );
  },
};

const cachedTeamMetrics = unstable_cache(
  async (teamId: string) =>
    await queryCoderouterTeamMetrics(teamId, defaultDependencies),
  ["coderouter-team-metrics-v3"],
  { revalidate: 300 },
);

export async function loadCoderouterTeamMetrics(
  authorizedTeamId: string,
): Promise<CoderouterTeamMetrics> {
  const metrics = await cachedTeamMetrics(authorizedTeamId);
  captureMetricsOutcome(
    authorizedTeamId,
    metrics.kind,
    metrics.kind === "ready" ? "none" : "request",
  );
  return metrics;
}

async function queryCoderouterTeamMetrics(
  authorizedTeamId: string,
  dependencies: MetricsDependencies,
): Promise<CoderouterTeamMetrics> {
  const now = dependencies.now();
  const result = await query<unknown>(
    TEAM_USAGE_SQL,
    { team_id: authorizedTeamId, ...dayWindowParams(now) },
    dependencies.clickhouse,
  );
  if (!result.ok) {
    const failure = queryFailure(result);
    dependencies.reportFailure?.(failure.reason, failure.status);
    return { kind: "unavailable" };
  }
  if (result.rows.length > MAX_ROWS) {
    dependencies.reportFailure?.("malformed_response");
    return { kind: "unavailable" };
  }
  const metrics = metricsFromRows(result.rows, now);
  if (!metrics) {
    dependencies.reportFailure?.("invalid_metrics");
    return { kind: "unavailable" };
  }
  return metrics;
}

function captureMetricsOutcome(
  teamId: string,
  outcome: "ready" | "unavailable",
  failureStage:
    | "none"
    | "configuration"
    | "request"
    | "endpoint_status"
    | "response_parse"
    | "response_validation",
): void {
  captureCoderouterEvent({
    event: "coderouter_metrics_loaded",
    teamId,
    properties: { outcome, failure_stage: failureStage },
  });
}

function metricsFromRows(
  rows: readonly unknown[],
  now: Date,
): Extract<CoderouterTeamMetrics, { kind: "ready" }> | null {
  const daily = new Map<string, MutableTotals>();
  for (const row of rows) {
    const parsed = parseRow(row);
    if (!parsed) return null;
    const bucket = daily.get(parsed.day) ?? emptyTotals();
    addTotals(bucket, parsed);
    daily.set(parsed.day, bucket);
  }

  const totals = emptyTotals();
  const serializedDays = periodDays(now).map((day) => {
    const bucket = daily.get(day) ?? emptyTotals();
    addTotals(totals, bucket);
    return {
      day,
      totalTokens: bucket.totalTokens,
      apiEquivalentUsd: bucket.apiEquivalentUsd,
    };
  });
  return {
    kind: "ready",
    periodDays: PERIOD_DAYS,
    generatedAt: now.toISOString(),
    rateCardVersion: CODEROUTER_API_RATE_CARD_VERSION,
    totals: { ...totals },
    daily: serializedDays,
  };
}

type ParsedRow = CoderouterTeamMetricsTotals & { readonly day: string };

function parseRow(value: unknown): ParsedRow | null {
  const record = rowRecord(value, EXPECTED_COLUMNS);
  if (!record) return null;
  const day = parseDay(record.day);
  const totals = parseTotals(record);
  return day && totals ? { day, ...totals } : null;
}

export const __test = {
  metricsFromRows,
  queryCoderouterTeamMetrics,
  TEAM_USAGE_SQL,
};
