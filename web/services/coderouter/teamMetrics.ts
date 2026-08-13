import { unstable_cache } from "next/cache";

import { coderouterTeamAnalyticsId } from "./analyticsIdentity";
import { captureCoderouterEvent } from "./analytics";
import { CODEROUTER_API_RATE_CARD_VERSION } from "./apiEquivalentPricing";
import { reportCoderouterFailure } from "./observability";

const PERIOD_DAYS = 30;
const QUERY_TIMEOUT_MS = 5_000;
const MAX_ROWS = PERIOD_DAYS;
const DEFAULT_ENDPOINT_NAME = "coderouter-team-usage-30d";
const EXPECTED_COLUMNS = [
  "day",
  "input_tokens",
  "cached_input_tokens",
  "output_tokens",
  "total_tokens",
  "api_equivalent_usd",
  "priced_tokens",
  "unpriced_tokens",
] as const;

type PostHogMetricsConfig = {
  readonly apiHost: string;
  readonly environmentId: string;
  readonly endpointSecret: string;
  readonly endpointName: string;
  readonly scopeSecret: string;
};

type MetricsDependencies = {
  readonly config: () => PostHogMetricsConfig | null;
  readonly fetch: typeof fetch;
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
  config: postHogMetricsConfig,
  fetch,
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
  ["coderouter-team-metrics-v2"],
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
  const config = dependencies.config();
  if (!config) {
    dependencies.reportFailure?.("configuration_missing");
    return { kind: "unavailable" };
  }
  try {
    const response = await dependencies.fetch(
      `${config.apiHost}/api/projects/${
        encodeURIComponent(config.environmentId)
      }/endpoints/${encodeURIComponent(config.endpointName)}/run`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${config.endpointSecret}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          variables: {
            team_scope: coderouterTeamAnalyticsId(
              authorizedTeamId,
              config.scopeSecret,
            ),
          },
        }),
        signal: AbortSignal.timeout(QUERY_TIMEOUT_MS),
      },
    );
    if (!response.ok) {
      dependencies.reportFailure?.("endpoint_status", response.status);
      return { kind: "unavailable" };
    }
    const responseText = await response.text();
    let parsedBody: unknown;
    try {
      parsedBody = JSON.parse(responseText);
    } catch {
      dependencies.reportFailure?.("malformed_response");
      return { kind: "unavailable" };
    }
    if (!isPlainRecord(parsedBody)) {
      dependencies.reportFailure?.("malformed_response");
      return { kind: "unavailable" };
    }
    const body = parsedBody;
    const columns = body.columns;
    const results = body.results;
    if (
      body.hasMore !== false ||
      !Array.isArray(columns) ||
      columns.length !== EXPECTED_COLUMNS.length ||
      !EXPECTED_COLUMNS.every(
        (column, index) => columns[index] === column,
      ) ||
      !Array.isArray(results) ||
      results.length > MAX_ROWS
    ) {
      dependencies.reportFailure?.("malformed_response");
      return { kind: "unavailable" };
    }
    const metrics = metricsFromRows(results, dependencies.now());
    if (!metrics) {
      dependencies.reportFailure?.("invalid_metrics");
      return { kind: "unavailable" };
    }
    return metrics;
  } catch {
    dependencies.reportFailure?.("request_failed");
    return { kind: "unavailable" };
  }
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
  const daily = new Map<string, MutableMetrics>();
  for (const row of rows) {
    const parsed = parseRow(row);
    if (!parsed) return null;
    const bucket = daily.get(parsed.day) ?? emptyMutableMetrics();
    addTotals(bucket, parsed);
    daily.set(parsed.day, bucket);
  }

  const days = periodDays(now);
  const totals = emptyMutableMetrics();
  const serializedDays = days.map((day) => {
    const bucket = daily.get(day) ?? emptyMutableMetrics();
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
type MutableMetrics = {
  -readonly [Key in keyof CoderouterTeamMetricsTotals]:
    CoderouterTeamMetricsTotals[Key];
};

function parseRow(value: unknown): ParsedRow | null {
  const record = Array.isArray(value)
    ? value.length === EXPECTED_COLUMNS.length
      ? Object.fromEntries(
        EXPECTED_COLUMNS.map((column, index) => [column, value[index]]),
      )
      : null
    : isPlainRecord(value)
    ? value
    : null;
  if (!record) return null;
  const keys = Object.keys(record).sort();
  if (
    keys.length !== EXPECTED_COLUMNS.length ||
    ![...EXPECTED_COLUMNS].sort().every((key, index) => keys[index] === key)
  ) {
    return null;
  }
  const day = typeof record.day === "string" &&
      /^\d{4}-\d{2}-\d{2}$/.test(record.day)
    ? record.day
    : null;
  const inputTokens = nonNegativeNumber(record.input_tokens);
  const cachedInputTokens = nonNegativeNumber(record.cached_input_tokens);
  const outputTokens = nonNegativeNumber(record.output_tokens);
  const totalTokens = nonNegativeNumber(record.total_tokens);
  const apiEquivalentUsd = nonNegativeNumber(record.api_equivalent_usd);
  const pricedTokens = nonNegativeNumber(record.priced_tokens);
  const unpricedTokens = nonNegativeNumber(record.unpriced_tokens);
  if (
    !day ||
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
    day,
    inputTokens,
    cachedInputTokens,
    outputTokens,
    totalTokens,
    apiEquivalentUsd,
    pricedTokens,
    unpricedTokens,
  };
}

function addTotals(
  target: MutableMetrics,
  source: CoderouterTeamMetricsTotals,
): void {
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

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function postHogMetricsConfig(): PostHogMetricsConfig | null {
  const endpointSecret =
    process.env.POSTHOG_CODEROUTER_ENDPOINT_SECRET?.trim();
  const environmentId =
    process.env.POSTHOG_CODEROUTER_ENVIRONMENT_ID?.trim();
  const scopeSecret =
    process.env.CODEROUTER_ANALYTICS_SCOPE_SECRET?.trim();
  if (
    !endpointSecret ||
    !environmentId ||
    !scopeSecret ||
    scopeSecret.length < 32
  ) {
    return null;
  }
  return {
    endpointSecret,
    environmentId,
    scopeSecret,
    // This is deliberately not environment-configurable. Only the reviewed,
    // customer-scoped query may receive a team pseudonym.
    endpointName: DEFAULT_ENDPOINT_NAME,
    apiHost: (
      process.env.POSTHOG_CODEROUTER_API_HOST ??
      "https://us.posthog.com"
    ).replace(/\/$/, ""),
  };
}

export const __test = {
  metricsFromRows,
  queryCoderouterTeamMetrics,
};
