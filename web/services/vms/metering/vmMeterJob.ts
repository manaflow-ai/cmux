// The vm-metering cron (every 5 minutes, off unless CMUX_VM_METERING_CLICKHOUSE=1):
// 1. copy every Postgres runtime interval touched in the lookback window to
//    ClickHouse (idempotent: replays rewrite the same event ids);
// 2. reconcile Postgres, ClickHouse and the provider's VM state (see
//    vmMeterReconcile.ts) and write the corrections.
// Inserts wait for ClickHouse to accept them, so a failure is visible and the
// next run's overlapping window writes the rows again.
import {
  insertRows,
  query,
  type ClickHouseDependencies,
} from "../../coderouter/clickhouse";
import { VM_RUNTIME_EVENTS_TABLE, vmRuntimeEvents, type VmMeterIntervalRow, type VmRuntimeEvent } from "./vmMeterEvents";
import { reconcileVmMeter, type VmMeterDrift, type VmMeterProviderStatus } from "./vmMeterReconcile";

export const VM_METERING_FLAG = "CMUX_VM_METERING_CLICKHOUSE";
/** Six cron periods: a run can fail five times in a row without losing a row. */
export const VM_METERING_LOOKBACK_MS = 30 * 60 * 1000;
const PROVIDER_CONCURRENCY = 8;
const MAX_CLICKHOUSE_OPEN = 10_000;

export function vmMeteringEnabled(env: Readonly<Record<string, string | undefined>>): boolean {
  return env[VM_METERING_FLAG]?.trim() === "1";
}

export type VmMeteringDependencies = {
  readonly env: Readonly<Record<string, string | undefined>>;
  readonly now: () => Date;
  readonly clickhouse: ClickHouseDependencies;
  /** Intervals started, ended or still open since `since`. */
  readonly loadIntervals: (since: Date) => Promise<readonly VmMeterIntervalRow[]>;
  /** Every Postgres interval without `ended_at`. */
  readonly loadOpenIntervals: () => Promise<readonly VmMeterIntervalRow[]>;
  readonly loadIntervalsById: (ids: readonly string[]) => Promise<readonly VmMeterIntervalRow[]>;
  /** The provider's state of one machine; a throw counts as `unknown`. */
  readonly providerStatus: (row: VmMeterIntervalRow) => Promise<VmMeterProviderStatus>;
};

export type VmMeteringResult =
  | { readonly enabled: false }
  | {
    readonly enabled: true;
    readonly synced: number;
    readonly inserted: number;
    readonly insertFailed: boolean;
    readonly drift?: VmMeterDrift;
  };

export async function runVmMetering(dependencies: VmMeteringDependencies): Promise<VmMeteringResult> {
  if (!vmMeteringEnabled(dependencies.env)) return { enabled: false };
  const now = dependencies.now();
  const rows = await dependencies.loadIntervals(new Date(now.getTime() - VM_METERING_LOOKBACK_MS));
  const synced = rows.flatMap((row) => vmRuntimeEvents(row, "postgres"));
  if (!(await write(synced, dependencies.clickhouse))) {
    return { enabled: true, synced: synced.length, inserted: 0, insertFailed: true };
  }

  const open = await query<{ interval_id?: unknown; vm_id?: unknown }>(
    `SELECT interval_id, vm_id FROM {db}.vm_runtime_intervals WHERE ended_at IS NULL LIMIT ${MAX_CLICKHOUSE_OPEN}`,
    {},
    dependencies.clickhouse,
  );
  if (!open.ok) return { enabled: true, synced: synced.length, inserted: synced.length, insertFailed: false };
  const clickhouseOpen = open.rows.flatMap((row) =>
    typeof row.interval_id === "string" && typeof row.vm_id === "string"
      ? [{ intervalId: row.interval_id, vmId: row.vm_id }]
      : []);
  const postgresOpen = await dependencies.loadOpenIntervals();
  const postgresOpenIds = new Set(postgresOpen.map((row) => row.intervalId));
  const closedIds = clickhouseOpen.map((entry) => entry.intervalId).filter((id) => !postgresOpenIds.has(id));
  const postgresClosedForClickhouseOpen = closedIds.length > 0 ? await dependencies.loadIntervalsById(closedIds) : [];
  const providerStatuses = await statuses(postgresOpen, dependencies.providerStatus);
  const { events, drift } = reconcileVmMeter({
    postgresOpen,
    clickhouseOpen,
    postgresClosedForClickhouseOpen,
    providerStatuses,
    observedAt: dependencies.now(),
  });
  const corrected = await write(events, dependencies.clickhouse);
  return {
    enabled: true,
    synced: synced.length,
    inserted: synced.length + (corrected ? events.length : 0),
    insertFailed: !corrected,
    drift,
  };
}

async function write(events: readonly VmRuntimeEvent[], clickhouse: ClickHouseDependencies): Promise<boolean> {
  if (events.length === 0) return true;
  const result = await insertRows(VM_RUNTIME_EVENTS_TABLE, events, clickhouse, { wait: true, isoTimestamps: true });
  return result.ok;
}

async function statuses(
  rows: readonly VmMeterIntervalRow[],
  read: VmMeteringDependencies["providerStatus"],
): Promise<Map<string, VmMeterProviderStatus>> {
  const result = new Map<string, VmMeterProviderStatus>();
  let next = 0;
  const worker = async () => {
    while (next < rows.length) {
      const row = rows[next++]!;
      result.set(row.vmId, await read(row).catch((): VmMeterProviderStatus => "unknown"));
    }
  };
  await Promise.all(Array.from({ length: Math.min(PROVIDER_CONCURRENCY, rows.length) }, worker));
  return result;
}

