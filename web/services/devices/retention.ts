// Device registry retention: drop rows the phone can no longer use.
//
// Registration is the registry's only heartbeat: a Mac refreshes its
// `(device, tag)` instance row on launch, sign-in, and team switch, so an
// instance not seen for the retention window belongs to a build that is gone
// (reinstalled tag, decommissioned machine, abandoned account). Manual remotes
// (`labels.manual`, added via `cmux remotes add`) have no self-registration
// heartbeat at all, so they are exempt everywhere here and only removed by an
// explicit user DELETE.

import { sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";

export const DEVICE_RETENTION_MAX_AGE_MS = 60 * 24 * 60 * 60 * 1_000;
export const DEVICE_RETENTION_BATCH_SIZE = 500;
export const DEVICE_RETENTION_MAX_ROWS = 10_000;
export const DEVICE_RETENTION_MAX_DURATION_MS = 8_000;

export type DeviceRetentionCategory = "staleInstances" | "staleDevices";

export type DeviceRetentionResult = {
  readonly rowsProcessed: number;
  readonly batches: number;
  readonly backlog: boolean;
  readonly budgetExhausted: "rows" | "time" | null;
  readonly byCategory: Readonly<Record<DeviceRetentionCategory, number>>;
};

type RetentionBatchOperation = {
  readonly category: DeviceRetentionCategory;
  readonly run: (limit: number) => Promise<number>;
};

type CloudDbTransaction = Parameters<Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]>[0];

/**
 * Delete stale registry rows in bounded batches (mirrors the Iroh retention
 * drain): each batch is its own short transaction with `for update skip
 * locked` candidates, so the cron never holds long locks against the hot
 * register/list path and a concurrent run cannot double-delete. Two passes:
 * stale non-manual instances first, then non-manual devices left with zero
 * instances. The second pass also collects devices orphaned by tag-scoped
 * deletes from deployments that predate the cascade in DELETE /api/devices.
 */
export async function pruneStaleDeviceRegistryRows(input: {
  readonly now: Date;
  readonly maxRows?: number;
  readonly maxDurationMs?: number;
}): Promise<DeviceRetentionResult> {
  const maxRows = retentionBudget(
    input.maxRows,
    DEVICE_RETENTION_MAX_ROWS,
    100_000,
    "maxRows",
  );
  const maxDurationMs = retentionBudget(
    input.maxDurationMs,
    DEVICE_RETENTION_MAX_DURATION_MS,
    30_000,
    "maxDurationMs",
  );
  const cutoff = new Date(input.now.getTime() - DEVICE_RETENTION_MAX_AGE_MS);
  const cutoffIso = cutoff.toISOString();
  const operations: readonly RetentionBatchOperation[] = [
    {
      category: "staleInstances",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select instance.id
          from device_app_instances as instance
          join devices as device on device.id = instance.device_id
          where instance.last_seen_at < ${cutoffIso}::timestamptz
            and not (device.labels @> '{"manual": true}'::jsonb)
          order by instance.last_seen_at, instance.id
          limit ${limit}
          for update of instance skip locked
        ), changed as (
          delete from device_app_instances as instance
          using candidates
          where instance.id = candidates.id
          returning instance.id
        )
        select count(*)::int as affected from changed
      `)),
    },
    {
      category: "staleDevices",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select device.id
          from devices as device
          where device.last_seen_at < ${cutoffIso}::timestamptz
            and not (device.labels @> '{"manual": true}'::jsonb)
            and not exists (
              select 1 from device_app_instances as instance
              where instance.device_id = device.id
            )
          order by device.last_seen_at, device.id
          limit ${limit}
          for update skip locked
        ), changed as (
          delete from devices as device
          using candidates
          where device.id = candidates.id
          returning device.id
        )
        select count(*)::int as affected from changed
      `)),
    },
  ];

  const byCategory: Record<DeviceRetentionCategory, number> = {
    staleInstances: 0,
    staleDevices: 0,
  };
  const deadline = Date.now() + maxDurationMs;
  const activeOperations = [...operations];
  let rowsProcessed = 0;
  let batches = 0;
  let operationIndex = 0;

  while (activeOperations.length > 0 && rowsProcessed < maxRows && Date.now() < deadline) {
    const operation = activeOperations[operationIndex]!;
    const limit = Math.min(DEVICE_RETENTION_BATCH_SIZE, maxRows - rowsProcessed);
    const affected = await operation.run(limit);
    batches += 1;
    rowsProcessed += affected;
    byCategory[operation.category] += affected;
    if (affected < limit) {
      activeOperations.splice(operationIndex, 1);
      if (operationIndex >= activeOperations.length) operationIndex = 0;
    } else {
      operationIndex = (operationIndex + 1) % activeOperations.length;
    }
  }

  const budgetExhausted = rowsProcessed >= maxRows
    ? "rows"
    : Date.now() >= deadline
      ? "time"
      : null;
  const backlog = budgetExhausted === "time"
    ? true
    : await deviceRetentionBacklogExists(cutoff);
  return { rowsProcessed, batches, backlog, budgetExhausted, byCategory };
}

async function runRetentionBatch(
  execute: (tx: CloudDbTransaction) => Promise<unknown>,
): Promise<number> {
  return await cloudDb().transaction(async (tx) => {
    const result = await execute(tx);
    const [row] = databaseRows(result);
    const affected = Number(row?.affected ?? 0);
    if (!Number.isSafeInteger(affected) || affected < 0 || affected > DEVICE_RETENTION_BATCH_SIZE) {
      throw new Error("invalid device retention batch result");
    }
    return affected;
  });
}

async function deviceRetentionBacklogExists(cutoff: Date): Promise<boolean> {
  const result = await cloudDb().execute(sql`
    select (
      exists (
        select 1
        from device_app_instances as instance
        join devices as device on device.id = instance.device_id
        where instance.last_seen_at < ${cutoff.toISOString()}::timestamptz
          and not (device.labels @> '{"manual": true}'::jsonb)
      ) or exists (
        select 1
        from devices as device
        where device.last_seen_at < ${cutoff.toISOString()}::timestamptz
          and not (device.labels @> '{"manual": true}'::jsonb)
          and not exists (
            select 1 from device_app_instances as instance
            where instance.device_id = device.id
          )
      )
    ) as backlog
  `);
  const [row] = databaseRows(result);
  return row?.backlog === true;
}

function databaseRows(result: unknown): readonly Record<string, unknown>[] {
  if (Array.isArray(result)) return result as readonly Record<string, unknown>[];
  const rows = (result as { readonly rows?: unknown } | null)?.rows;
  return Array.isArray(rows) ? rows as readonly Record<string, unknown>[] : [];
}

function retentionBudget(
  value: number | undefined,
  fallback: number,
  maximum: number,
  name: string,
): number {
  const resolved = value ?? fallback;
  if (!Number.isSafeInteger(resolved) || resolved < 1 || resolved > maximum) {
    throw new Error(`invalid device retention ${name}`);
  }
  return resolved;
}
