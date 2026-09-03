// Per-machine CodeRouter usage read from the ClickHouse ledger. Mirrors
// teamMetrics.ts: same client, timeout, five-minute cache, fail-closed
// validation, and privacy-safe failure reporting. A machine is identified by
// the cmux `cloud_vms.id` UUID that a VM-bound route token stamps on every
// ledger row as `vm_id`. Callers must verify the team owns the machine before
// asking for its usage.
import { unstable_cache } from "next/cache";

import { captureCoderouterEvent } from "./analytics";
import { CODEROUTER_API_RATE_CARD_VERSION } from "./apiEquivalentPricing";
import {
  defaultClickHouseDependencies,
  query,
  type ClickHouseDependencies,
  type ClickHouseParamValue,
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

const MAX_DAY_ROWS = PERIOD_DAYS;
const MAX_MACHINE_ROWS = 200;
const VM_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

const VM_COLUMNS = ["day", ...USAGE_COLUMNS] as const;
const MACHINE_COLUMNS = ["vm_id", ...USAGE_COLUMNS] as const;

const VM_USAGE_SQL = `SELECT
  toString(toDate(event_time)) AS day,${USAGE_SUMS_SQL}
FROM {db}.usage_events
WHERE team_id = {team_id:String}
  AND vm_id = {vm_id:String}
  AND ${DAY_WINDOW_SQL}
GROUP BY day
ORDER BY day ASC
LIMIT 31`;

const TEAM_MACHINES_SQL = `SELECT
  vm_id,${USAGE_SUMS_SQL}
FROM {db}.usage_events
WHERE team_id = {team_id:String}
  AND vm_id IS NOT NULL
  AND ${DAY_WINDOW_SQL}
GROUP BY vm_id
ORDER BY total_tokens DESC, vm_id ASC
LIMIT ${MAX_MACHINE_ROWS}`;

export type VmMetricsDependencies = {
  readonly clickhouse: ClickHouseDependencies;
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
  clickhouse: defaultClickHouseDependencies,
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
  ["coderouter-vm-metrics-v2"],
  { revalidate: 300 },
);

const cachedTeamMachineMetrics = unstable_cache(
  async (teamId: string) =>
    await queryCoderouterTeamMachineMetrics(teamId, defaultDependencies),
  ["coderouter-team-machines-v2"],
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
  const now = dependencies.now();
  const rows = await runQuery("vm", dependencies, VM_USAGE_SQL, {
    team_id: authorizedTeamId,
    vm_id: vmId,
    ...dayWindowParams(now),
  }, MAX_DAY_ROWS);
  if (!rows) return { kind: "unavailable" };
  const metrics = vmMetricsFromRows(vmId, rows, now);
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
  const now = dependencies.now();
  const rows = await runQuery("machines", dependencies, TEAM_MACHINES_SQL, {
    team_id: authorizedTeamId,
    ...dayWindowParams(now),
  }, MAX_MACHINE_ROWS);
  if (!rows) return { kind: "unavailable" };
  const metrics = machineMetricsFromRows(rows, now);
  if (!metrics) {
    dependencies.reportFailure?.("machines", "invalid_metrics");
    return { kind: "unavailable" };
  }
  return metrics;
}

async function runQuery(
  name: "vm" | "machines",
  dependencies: VmMetricsDependencies,
  sql: string,
  params: Readonly<Record<string, ClickHouseParamValue>>,
  maxRows: number,
): Promise<readonly unknown[] | null> {
  const result = await query<unknown>(sql, params, dependencies.clickhouse);
  if (!result.ok) {
    const failure = queryFailure(result);
    dependencies.reportFailure?.(name, failure.reason, failure.status);
    return null;
  }
  if (result.rows.length > maxRows) {
    dependencies.reportFailure?.(name, "malformed_response");
    return null;
  }
  return result.rows;
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
    const day = parseDay(record.day);
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

/** Same shape check analytics.ts applies before stamping `coderouter_vm_id`. */
export function isVmId(value: string): boolean {
  return VM_ID_PATTERN.test(value);
}

export const __test = {
  queryCoderouterVmMetrics,
  queryCoderouterTeamMachineMetrics,
  vmMetricsFromRows,
  machineMetricsFromRows,
  VM_USAGE_SQL,
  TEAM_MACHINES_SQL,
};
