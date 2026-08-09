import { unstable_cache } from "next/cache";

import {
  CODEROUTER_API_RATE_CARD_VERSION,
  estimateApiEquivalent,
  type AggregateModelUsage,
} from "./apiEquivalentPricing";
import { coderouterTeamAnalyticsId } from "./analyticsIdentity";

const PERIOD_DAYS = 30;
const QUERY_TIMEOUT_MS = 5_000;
const EXPECTED_COLUMNS = [
  "day",
  "model",
  "request_count",
  "input_tokens",
  "cached_input_tokens",
  "output_tokens",
  "total_tokens",
] as const;

const TEAM_METRICS_QUERY = `
SELECT
  toString(toDate(timestamp)) AS day,
  toString(properties.model) AS model,
  count() AS request_count,
  sum(toUInt64(properties.input_tokens)) AS input_tokens,
  sum(toUInt64(properties.cached_input_tokens)) AS cached_input_tokens,
  sum(toUInt64(properties.output_tokens)) AS output_tokens,
  sum(toUInt64(properties.total_tokens)) AS total_tokens
FROM events
WHERE event = 'coderouter_model_request_completed'
  AND timestamp >= now() - INTERVAL 30 DAY
  AND properties.coderouter_team_scope = {team_scope}
GROUP BY day, model
ORDER BY day ASC, model ASC
LIMIT 500
`.trim();

type PostHogMetricsConfig = {
  readonly apiHost: string;
  readonly environmentId: string;
  readonly queryApiKey: string;
};

type MetricsDependencies = {
  readonly config: () => PostHogMetricsConfig | null;
  readonly fetch: typeof fetch;
  readonly now: () => Date;
};

export type CoderouterTeamMetricsTotals = {
  readonly requestCount: number;
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
  readonly requestCount: number;
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
  config: postHogMetricsConfig,
  fetch,
  now: () => new Date(),
};

const cachedTeamMetrics = unstable_cache(
  async (teamId: string) =>
    await queryCoderouterTeamMetrics(teamId, defaultDependencies),
  ["coderouter-team-metrics-v1"],
  { revalidate: 300 },
);

export async function loadCoderouterTeamMetrics(
  authorizedTeamId: string,
): Promise<CoderouterTeamMetrics> {
  return await cachedTeamMetrics(authorizedTeamId);
}

async function queryCoderouterTeamMetrics(
  authorizedTeamId: string,
  dependencies: MetricsDependencies,
): Promise<CoderouterTeamMetrics> {
  const config = dependencies.config();
  if (!config) return { kind: "unavailable" };
  try {
    const response = await dependencies.fetch(
      `${config.apiHost}/api/projects/${encodeURIComponent(config.environmentId)}/query/`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${config.queryApiKey}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          query: {
            kind: "HogQLQuery",
            query: TEAM_METRICS_QUERY,
            values: {
              team_scope: coderouterTeamAnalyticsId(authorizedTeamId),
            },
          },
        }),
        signal: AbortSignal.timeout(QUERY_TIMEOUT_MS),
      },
    );
    if (!response.ok) return { kind: "unavailable" };
    const body = await response.json() as {
      readonly columns?: unknown;
      readonly results?: unknown;
    };
    const columns = body.columns;
    const results = body.results;
    if (
      !Array.isArray(columns) ||
      columns.length !== EXPECTED_COLUMNS.length ||
      !EXPECTED_COLUMNS.every((column, index) => columns[index] === column) ||
      !Array.isArray(results) ||
      results.length > 500
    ) {
      return { kind: "unavailable" };
    }
    return metricsFromRows(results, dependencies.now());
  } catch {
    return { kind: "unavailable" };
  }
}

function metricsFromRows(
  rows: readonly unknown[],
  now: Date,
): Extract<CoderouterTeamMetrics, { kind: "ready" }> {
  const daily = new Map<string, MutableMetrics>();
  for (const row of rows) {
    const parsed = parseRow(row);
    if (!parsed) continue;
    const bucket = daily.get(parsed.day) ?? emptyMutableMetrics();
    addUsage(bucket, parsed);
    daily.set(parsed.day, bucket);
  }

  const days = periodDays(now);
  const totals = emptyMutableMetrics();
  const serializedDays = days.map((day) => {
    const bucket = daily.get(day) ?? emptyMutableMetrics();
    addTotals(totals, bucket);
    return {
      day,
      requestCount: bucket.requestCount,
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

type ParsedRow = AggregateModelUsage & {
  readonly day: string;
  readonly requestCount: number;
};

type MutableMetrics = {
  -readonly [Key in keyof CoderouterTeamMetricsTotals]:
    CoderouterTeamMetricsTotals[Key];
};

function parseRow(value: unknown): ParsedRow | null {
  if (!Array.isArray(value) || value.length !== EXPECTED_COLUMNS.length) {
    return null;
  }
  const day = typeof value[0] === "string" &&
      /^\d{4}-\d{2}-\d{2}$/.test(value[0])
    ? value[0]
    : null;
  const model = typeof value[1] === "string" ? value[1] : null;
  const numbers = value.slice(2).map(nonNegativeNumber);
  if (!day || !model || numbers.some((number) => number === null)) return null;
  return {
    day,
    model,
    requestCount: numbers[0]!,
    inputTokens: numbers[1]!,
    cachedInputTokens: numbers[2]!,
    outputTokens: numbers[3]!,
    totalTokens: numbers[4]!,
  };
}

function addUsage(target: MutableMetrics, usage: ParsedRow): void {
  const estimate = estimateApiEquivalent(usage);
  target.requestCount += usage.requestCount;
  target.inputTokens += usage.inputTokens;
  target.cachedInputTokens += usage.cachedInputTokens;
  target.outputTokens += usage.outputTokens;
  target.totalTokens += usage.totalTokens;
  target.apiEquivalentUsd += estimate.usd;
  target.pricedTokens += estimate.pricedTokens;
  target.unpricedTokens += estimate.unpricedTokens;
}

function addTotals(target: MutableMetrics, source: MutableMetrics): void {
  target.requestCount += source.requestCount;
  target.inputTokens += source.inputTokens;
  target.cachedInputTokens += source.cachedInputTokens;
  target.outputTokens += source.outputTokens;
  target.totalTokens += source.totalTokens;
  target.apiEquivalentUsd += source.apiEquivalentUsd;
  target.pricedTokens += source.pricedTokens;
  target.unpricedTokens += source.unpricedTokens;
}

function emptyMutableMetrics(): MutableMetrics {
  return {
    requestCount: 0,
    inputTokens: 0,
    cachedInputTokens: 0,
    outputTokens: 0,
    totalTokens: 0,
    apiEquivalentUsd: 0,
    pricedTokens: 0,
    unpricedTokens: 0,
  };
}

function periodDays(now: Date): readonly string[] {
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

function nonNegativeNumber(value: unknown): number | null {
  const number = typeof value === "number"
    ? value
    : typeof value === "string" && value.trim()
    ? Number(value)
    : Number.NaN;
  return Number.isFinite(number) && number >= 0 ? number : null;
}

function postHogMetricsConfig(): PostHogMetricsConfig | null {
  const queryApiKey =
    process.env.POSTHOG_CODEROUTER_QUERY_API_KEY?.trim();
  const environmentId = (
    process.env.POSTHOG_ENVIRONMENT_ID ??
    process.env.POSTHOG_PROJECT_ID
  )?.trim();
  if (!queryApiKey || !environmentId) return null;
  const apiHost = (
    process.env.POSTHOG_API_HOST ?? "https://us.posthog.com"
  ).replace(/\/$/, "");
  return { apiHost, environmentId, queryApiKey };
}

export const __test = {
  metricsFromRows,
  queryCoderouterTeamMetrics,
};
