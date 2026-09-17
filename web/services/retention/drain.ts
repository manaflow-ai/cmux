// Generic retention drain for the `column` entries of db/retention.ts.
//
// Each batch is one statement that deletes at most `batchSize` rows older than
// the table's cutoff, addressed by ctid so tables with composite or natural
// keys need no special case. Batches stay small and the run is bounded by a
// row and time budget, so a large backlog is worked off across cron runs
// without holding long locks. Identifiers come only from the registry, which
// the schema test checks against real tables and timestamp columns.
import { sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { columnDrains, type ColumnDrain } from "../../db/retention";

export const RETENTION_BATCH_SIZE = 500;
export const RETENTION_MAX_ROWS = 50_000;
export const RETENTION_MAX_DURATION_MS = 20_000;

export type RetentionDrainResult = {
  readonly rowsDeleted: number;
  readonly batches: number;
  readonly byTable: Readonly<Record<string, number>>;
  readonly budgetExhausted: "rows" | "time" | null;
};

export type RetentionDrainDependencies = {
  readonly deleteBatch: (drain: ColumnDrain, cutoff: Date, limit: number) => Promise<number>;
  readonly now: () => number;
};

export function cutoffFor(drain: ColumnDrain, now: Date): Date {
  return new Date(now.getTime() - drain.days * 24 * 60 * 60 * 1_000);
}

/** The exact statement one batch runs. Exported so the test can pin its shape. */
export function deleteBatchStatement(drain: ColumnDrain, cutoff: Date, limit: number) {
  const table = sql.identifier(drain.table);
  const column = sql.identifier(drain.column);
  return sql`
    with candidates as materialized (
      select ctid
      from ${table}
      where ${column} < ${cutoff.toISOString()}::timestamptz
      order by ${column}
      limit ${limit}
    ), deleted as (
      delete from ${table}
      where ctid in (select ctid from candidates)
      returning 1
    )
    select count(*)::int as affected from deleted
  `;
}

async function deleteBatchInDatabase(drain: ColumnDrain, cutoff: Date, limit: number): Promise<number> {
  const result = await cloudDb().execute(deleteBatchStatement(drain, cutoff, limit));
  const rows = Array.isArray(result)
    ? result as readonly Record<string, unknown>[]
    : ((result as { readonly rows?: unknown } | null)?.rows as readonly Record<string, unknown>[] | undefined) ?? [];
  const affected = Number(rows[0]?.affected ?? 0);
  if (!Number.isSafeInteger(affected) || affected < 0 || affected > limit) {
    throw new Error(`invalid retention batch result for ${drain.table}`);
  }
  return affected;
}

export const defaultRetentionDrainDependencies: RetentionDrainDependencies = {
  deleteBatch: deleteBatchInDatabase,
  now: () => Date.now(),
};

export async function drainTableRetention(
  input: {
    readonly now: Date;
    readonly drains?: readonly ColumnDrain[];
    readonly maxRows?: number;
    readonly maxDurationMs?: number;
    readonly batchSize?: number;
  },
  dependencies: RetentionDrainDependencies = defaultRetentionDrainDependencies,
): Promise<RetentionDrainResult> {
  const drains = input.drains ?? columnDrains();
  const maxRows = input.maxRows ?? RETENTION_MAX_ROWS;
  const maxDurationMs = input.maxDurationMs ?? RETENTION_MAX_DURATION_MS;
  const batchSize = input.batchSize ?? RETENTION_BATCH_SIZE;
  const startedAt = dependencies.now();
  const byTable: Record<string, number> = {};
  let rowsDeleted = 0;
  let batches = 0;
  let budgetExhausted: RetentionDrainResult["budgetExhausted"] = null;

  outer: for (const drain of drains) {
    const cutoff = cutoffFor(drain, input.now);
    byTable[drain.table] = 0;
    for (;;) {
      if (rowsDeleted >= maxRows) { budgetExhausted = "rows"; break outer; }
      if (dependencies.now() - startedAt >= maxDurationMs) { budgetExhausted = "time"; break outer; }
      const limit = Math.min(batchSize, maxRows - rowsDeleted);
      const affected = await dependencies.deleteBatch(drain, cutoff, limit);
      batches += 1;
      rowsDeleted += affected;
      byTable[drain.table] += affected;
      if (affected < limit) break;
    }
  }
  return { rowsDeleted, batches, byTable, budgetExhausted };
}
