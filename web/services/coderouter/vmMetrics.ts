// Per-machine CodeRouter usage read from two fixed PostHog Endpoints. Mirrors
// teamMetrics.ts: same credentials, timeout, five-minute cache, fail-closed
// validation, and privacy-safe failure reporting. A machine is identified by
// the cmux `cloud_vms.id` UUID that a VM-bound route token stamps on
// `$ai_generation` as `coderouter_vm_id`. Callers must verify the team owns
// the machine before asking for its usage.
import { unstable_cache } from "next/cache";

import { coderouterTeamAnalyticsId } from "./analyticsIdentity";
import { captureCoderouterEvent } from "./analytics";
import { CODEROUTER_API_RATE_CARD_VERSION } from "./apiEquivalentPricing";
import { reportCoderouterFailure } from "./observability";

const PERIOD_DAYS = 30;
const QUERY_TIMEOUT_MS = 5_000;
const MAX_DAY_ROWS = PERIOD_DAYS;
const MAX_MACHINE_ROWS = 200;
const DEFAULT_VM_ENDPOINT_NAME = "coderouter-vm-usage-30d";
const DEFAULT_MACHINES_ENDPOINT_NAME = "coderouter-team-machines-30d";
const ENDPOINT_NAME_PATTERN = /^[a-z0-9][a-z0-9-]{0,63}$/;
const VM_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

const USAGE_COLUMNS = [
  "input_tokens",
  "cached_input_tokens",
  "output_tokens",
  "total_tokens",
  "api_equivalent_usd",
  "priced_tokens",
  "unpriced_tokens",
] as const;
const VM_COLUMNS = ["day", ...USAGE_COLUMNS] as const;
const MACHINE_COLUMNS = ["vm_id", ...USAGE_COLUMNS] as const;

export type PostHogVmMetricsConfig = {
  readonly apiHost: string;
  readonly environmentId: string;
  readonly endpointSecret: string;
  readonly vmEndpointName: string;
  readonly machinesEndpointName: string;
  readonly scopeSecret: string;
};

export type VmMetricsDependencies = {
  readonly config: () => PostHogVmMetricsConfig | null;
  readonly fetch: typeof fetch;
  readonly now: () => Date;
  readonly reportFailure?: (
    query: "vm" | "machines",
    reason: string,
    status?: number,
  ) => void;
};

export type CoderouterVmMetricsTotals = {
  readonly inputTokens: number;
  readonly cachedInputTokens: number;
  readonly outputTokens: number;
  readonly totalTokens: number;
  readonly apiEquivalentUsd: number;
  readonly pricedTokens: number;
  readonly unpricedTokens: number;
};

export type CoderouterVmMetricsDay = {
  readonly day: string;
  readonly totalTokens: number;
  readonly apiEquivalentUsd: number;
};

export type CoderouterVmMetrics =
  | { readonly kind: "unavailable" }
  | {
      readonly kind: "ready";
      readonly vmId: string;
      readonly periodDays: number;
      readonly generatedAt: string;
      readonly rateCardVersion: string;
      readonly totals: CoderouterVmMetricsTotals;
      readonly daily: readonly CoderouterVmMetricsDay[];
    };

export type CoderouterTeamMachineUsage = {
  readonly vmId: string;
  readonly totals: CoderouterVmMetricsTotals;
};

export type CoderouterTeamMachineMetrics =
  | { readonly kind: "unavailable" }
  | {
      readonly kind: "ready";
      readonly periodDays: number;
      readonly generatedAt: string;
      readonly rateCardVersion: string;
      /** Ordered by total tokens descending, at most 200 machines. */
      readonly machines: readonly CoderouterTeamMachineUsage[];
    };

export type CoderouterVmUsageSurface =
  | "dashboard"
  | "vm_usage_api"
  | "team_machines_api"
  | "vm_self_api";

const defaultDependencies: VmMetricsDependencies = {
  config: postHogVmMetricsConfig,
  fetch,
  now: () => new Date(),
  reportFailure: (query, reason, status) => {
    reportCoderouterFailure(
      "analytics_query",
      new Error("CodeRouter analytics query failed"),
      {
        query: `${query}_usage`,
        reason,
        ...(status === undefined ? {} : { status }),
      },
    );
  },
};

const cachedVmMetrics = unstable_cache(
  async (teamId: string, vmId: string) =>
    await queryCoderouterVmMetrics(teamId, vmId, defaultDependencies),
  ["coderouter-vm-metrics-v1"],
  { revalidate: 300 },
);

const cachedTeamMachineMetrics = unstable_cache(
  async (teamId: string) =>
    await queryCoderouterTeamMachineMetrics(teamId, defaultDependencies),
  ["coderouter-team-machines-v1"],
  { revalidate: 300 },
);

/**
 * Usage for one machine. `vmId` must already be verified as owned by
 * `authorizedTeamId`; this function trusts its caller.
 */
export async function loadCoderouterVmMetrics(
  authorizedTeamId: string,
  vmId: string,
  surface: CoderouterVmUsageSurface = "vm_usage_api",
): Promise<CoderouterVmMetrics> {
  const metrics = isVmId(vmId)
    ? await cachedVmMetrics(authorizedTeamId, vmId)
    : { kind: "unavailable" as const };
  captureCoderouterEvent({
    event: "coderouter_vm_usage_viewed",
    teamId: authorizedTeamId,
    properties: { surface, outcome: metrics.kind },
  });
  return metrics;
}

/** Usage per machine for a team. Rows are not yet filtered by ownership. */
export async function loadCoderouterTeamMachineMetrics(
  authorizedTeamId: string,
  surface: CoderouterVmUsageSurface = "team_machines_api",
): Promise<CoderouterTeamMachineMetrics> {
  const metrics = await cachedTeamMachineMetrics(authorizedTeamId);
  captureCoderouterEvent({
    event: "coderouter_vm_usage_viewed",
    teamId: authorizedTeamId,
    properties: { surface, outcome: metrics.kind },
  });
  return metrics;
}

async function queryCoderouterVmMetrics(
  authorizedTeamId: string,
  vmId: string,
  dependencies: VmMetricsDependencies,
): Promise<CoderouterVmMetrics> {
  if (!isVmId(vmId)) {
    dependencies.reportFailure?.("vm", "invalid_vm_id");
    return { kind: "unavailable" };
  }
  const rows = await runEndpoint("vm", dependencies, (config) => ({
    endpointName: config.vmEndpointName,
    variables: {
      team_scope: coderouterTeamAnalyticsId(
        authorizedTeamId,
        config.scopeSecret,
      ),
      vm_id: vmId,
    },
    columns: VM_COLUMNS,
    maxRows: MAX_DAY_ROWS,
  }));
  if (!rows) return { kind: "unavailable" };
  const metrics = vmMetricsFromRows(vmId, rows, dependencies.now());
  if (!metrics) {
    dependencies.reportFailure?.("vm", "invalid_metrics");
    return { kind: "unavailable" };
  }
  return metrics;
}

async function queryCoderouterTeamMachineMetrics(
  authorizedTeamId: string,
  dependencies: VmMetricsDependencies,
): Promise<CoderouterTeamMachineMetrics> {
  const rows = await runEndpoint("machines", dependencies, (config) => ({
    endpointName: config.machinesEndpointName,
    variables: {
      team_scope: coderouterTeamAnalyticsId(
        authorizedTeamId,
        config.scopeSecret,
      ),
    },
    columns: MACHINE_COLUMNS,
    maxRows: MAX_MACHINE_ROWS,
  }));
  if (!rows) return { kind: "unavailable" };
  const metrics = machineMetricsFromRows(rows, dependencies.now());
  if (!metrics) {
    dependencies.reportFailure?.("machines", "invalid_metrics");
    return { kind: "unavailable" };
  }
  return metrics;
}

type EndpointCall = {
  readonly endpointName: string;
  readonly variables: Readonly<Record<string, string>>;
  readonly columns: readonly string[];
  readonly maxRows: number;
};

async function runEndpoint(
  query: "vm" | "machines",
  dependencies: VmMetricsDependencies,
  call: (config: PostHogVmMetricsConfig) => EndpointCall,
): Promise<readonly unknown[] | null> {
  const config = dependencies.config();
  if (!config) {
    dependencies.reportFailure?.(query, "configuration_missing");
    return null;
  }
  const request = call(config);
  try {
    const response = await dependencies.fetch(
      `${config.apiHost}/api/projects/${
        encodeURIComponent(config.environmentId)
      }/endpoints/${encodeURIComponent(request.endpointName)}/run`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${config.endpointSecret}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ variables: request.variables }),
        signal: AbortSignal.timeout(QUERY_TIMEOUT_MS),
      },
    );
    if (!response.ok) {
      dependencies.reportFailure?.(query, "endpoint_status", response.status);
      return null;
    }
    let parsedBody: unknown;
    try {
      parsedBody = JSON.parse(await response.text());
    } catch {
      dependencies.reportFailure?.(query, "malformed_response");
      return null;
    }
    if (!isPlainRecord(parsedBody)) {
      dependencies.reportFailure?.(query, "malformed_response");
      return null;
    }
    const columns = parsedBody.columns;
    const results = parsedBody.results;
    if (
      parsedBody.hasMore !== false ||
      !Array.isArray(columns) ||
      columns.length !== request.columns.length ||
      !request.columns.every((column, index) => columns[index] === column) ||
      !Array.isArray(results) ||
      results.length > request.maxRows
    ) {
      dependencies.reportFailure?.(query, "malformed_response");
      return null;
    }
    return results;
  } catch {
    dependencies.reportFailure?.(query, "request_failed");
    return null;
  }
}

function vmMetricsFromRows(
  vmId: string,
  rows: readonly unknown[],
  now: Date,
): Extract<CoderouterVmMetrics, { kind: "ready" }> | null {
  const daily = new Map<string, MutableTotals>();
  for (const row of rows) {
    const record = rowRecord(row, VM_COLUMNS);
    if (!record) return null;
    const day = typeof record.day === "string" &&
        /^\d{4}-\d{2}-\d{2}$/.test(record.day)
      ? record.day
      : null;
    const totals = parseTotals(record);
    if (!day || !totals) return null;
    const bucket = daily.get(day) ?? emptyTotals();
    addTotals(bucket, totals);
    daily.set(day, bucket);
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
    vmId,
    periodDays: PERIOD_DAYS,
    generatedAt: now.toISOString(),
    rateCardVersion: CODEROUTER_API_RATE_CARD_VERSION,
    totals: { ...totals },
    daily: serializedDays,
  };
}

function machineMetricsFromRows(
  rows: readonly unknown[],
  now: Date,
): Extract<CoderouterTeamMachineMetrics, { kind: "ready" }> | null {
  const machines = new Map<string, MutableTotals>();
  for (const row of rows) {
    const record = rowRecord(row, MACHINE_COLUMNS);
    if (!record) return null;
    const vmId = typeof record.vm_id === "string" && isVmId(record.vm_id)
      ? record.vm_id
      : null;
    const totals = parseTotals(record);
    if (!vmId || !totals) return null;
    const bucket = machines.get(vmId) ?? emptyTotals();
    addTotals(bucket, totals);
    machines.set(vmId, bucket);
  }
  return {
    kind: "ready",
    periodDays: PERIOD_DAYS,
    generatedAt: now.toISOString(),
    rateCardVersion: CODEROUTER_API_RATE_CARD_VERSION,
    machines: [...machines.entries()]
      .map(([vmId, totals]) => ({ vmId, totals: { ...totals } }))
      .sort((left, right) =>
        right.totals.totalTokens - left.totals.totalTokens ||
        left.vmId.localeCompare(right.vmId)
      ),
  };
}

type MutableTotals = {
  -readonly [Key in keyof CoderouterVmMetricsTotals]:
    CoderouterVmMetricsTotals[Key];
};

function rowRecord(
  value: unknown,
  columns: readonly string[],
): Record<string, unknown> | null {
  const record = Array.isArray(value)
    ? value.length === columns.length
      ? Object.fromEntries(columns.map((column, index) => [column, value[index]]))
      : null
    : isPlainRecord(value)
    ? value
    : null;
  if (!record) return null;
  const keys = Object.keys(record).sort();
  const expected = [...columns].sort();
  return keys.length === expected.length &&
      expected.every((key, index) => keys[index] === key)
    ? record
    : null;
}

function parseTotals(
  record: Record<string, unknown>,
): CoderouterVmMetricsTotals | null {
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

function addTotals(
  target: MutableTotals,
  source: CoderouterVmMetricsTotals,
): void {
  target.inputTokens += source.inputTokens;
  target.cachedInputTokens += source.cachedInputTokens;
  target.outputTokens += source.outputTokens;
  target.totalTokens += source.totalTokens;
  target.apiEquivalentUsd += source.apiEquivalentUsd;
  target.pricedTokens += source.pricedTokens;
  target.unpricedTokens += source.unpricedTokens;
}

function emptyTotals(): MutableTotals {
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

/** Same shape check analytics.ts applies before stamping `coderouter_vm_id`. */
export function isVmId(value: string): boolean {
  return VM_ID_PATTERN.test(value);
}

function endpointName(raw: string | undefined, fallback: string): string {
  const name = raw?.trim();
  return name && ENDPOINT_NAME_PATTERN.test(name) ? name : fallback;
}

function postHogVmMetricsConfig(): PostHogVmMetricsConfig | null {
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
    // Only the name may vary (for a renamed published copy); the query text
    // itself is reviewed and published by an operator, never sent from here.
    vmEndpointName: endpointName(
      process.env.POSTHOG_CODEROUTER_VM_ENDPOINT_NAME,
      DEFAULT_VM_ENDPOINT_NAME,
    ),
    machinesEndpointName: endpointName(
      process.env.POSTHOG_CODEROUTER_MACHINES_ENDPOINT_NAME,
      DEFAULT_MACHINES_ENDPOINT_NAME,
    ),
    apiHost: (
      process.env.POSTHOG_CODEROUTER_API_HOST ??
      "https://us.posthog.com"
    ).replace(/\/$/, ""),
  };
}

export const __test = {
  queryCoderouterVmMetrics,
  queryCoderouterTeamMachineMetrics,
  vmMetricsFromRows,
  machineMetricsFromRows,
  postHogVmMetricsConfig,
};
