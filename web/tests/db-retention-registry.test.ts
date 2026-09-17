import { describe, expect, test } from "bun:test";
import { getTableColumns, getTableName, is } from "drizzle-orm";
import { CasingCache } from "drizzle-orm/casing";
import { PgTable, PgTimestamp } from "drizzle-orm/pg-core";

import * as schema from "../db/schema";
import { columnDrains, TABLE_RETENTION } from "../db/retention";
import {
  cutoffFor,
  deleteBatchStatement,
  drainTableRetention,
  type RetentionDrainDependencies,
} from "../services/retention/drain";

const schemaTables = (Object.values(schema) as unknown[]).filter((value): value is PgTable => is(value, PgTable));
const schemaByName = new Map(schemaTables.map((table) => [getTableName(table), table]));

describe("table retention registry", () => {
  test("every schema table declares a retention policy", () => {
    expect(schemaTables.length).toBeGreaterThan(0);
    const missing = [...schemaByName.keys()].filter((name) => !(name in TABLE_RETENTION)).sort();
    expect(missing).toEqual([]);
  });

  test("every registry entry names a real table", () => {
    const stale = Object.keys(TABLE_RETENTION).filter((name) => !schemaByName.has(name)).sort();
    expect(stale).toEqual([]);
  });

  test("every column drain points at a timestamp column and a positive cutoff", () => {
    const problems: string[] = [];
    for (const drain of columnDrains()) {
      const table = schemaByName.get(drain.table);
      if (!table) { problems.push(`${drain.table}: unknown table`); continue; }
      const column = Object.values(getTableColumns(table)).find((candidate) => candidate.name === drain.column);
      if (!column) problems.push(`${drain.table}.${drain.column}: unknown column`);
      else if (!is(column, PgTimestamp)) problems.push(`${drain.table}.${drain.column}: not a timestamp`);
      if (!Number.isInteger(drain.days) || drain.days <= 0) problems.push(`${drain.table}: days must be a positive integer`);
    }
    expect(problems).toEqual([]);
  });

  test("every route drain names a cron route that is scheduled", async () => {
    const vercel = (await import("../vercel.json")) as { crons: { path: string }[] };
    const scheduled = new Set(vercel.crons.map((cron) => cron.path));
    const unscheduled = Object.entries(TABLE_RETENTION)
      .filter(([, policy]) => policy.kind === "drain" && "route" in policy && !scheduled.has(policy.route))
      .map(([table]) => table);
    expect(unscheduled).toEqual([]);
    expect(scheduled.has("/api/cron/db-retention")).toBe(true);
  });
});

describe("generic retention drain", () => {
  const drain = { table: "cloud_vm_usage_events", column: "created_at", days: 365 } as const;

  test("the batch statement deletes by ctid below the cutoff with a limit", () => {
    const cutoff = new Date("2025-09-10T00:00:00.000Z");
    const query = deleteBatchStatement(drain, cutoff, 500).toQuery({
      escapeName: (name) => `"${name}"`,
      escapeParam: (index) => `$${index + 1}`,
      escapeString: (value) => `'${value}'`,
      casing: new CasingCache(),
    });
    const text = query.sql.replace(/\s+/g, " ");
    expect(text).toContain('from "cloud_vm_usage_events" where "created_at" < $1::timestamptz order by "created_at" limit $2');
    expect(text).toContain('delete from "cloud_vm_usage_events" where ctid in (select ctid from candidates)');
    expect(query.params).toEqual([cutoff.toISOString(), 500]);
  });

  test("the cutoff is the retention window before now", () => {
    const now = new Date("2026-09-10T00:00:00.000Z");
    expect(cutoffFor(drain, now).toISOString()).toBe("2025-09-10T00:00:00.000Z");
  });

  test("drains each table in batches until a short batch, within the row budget", async () => {
    const calls: { table: string; limit: number }[] = [];
    const backlog: Record<string, number> = { a: 1_200, b: 0, c: 300 };
    const dependencies: RetentionDrainDependencies = {
      now: () => 0,
      deleteBatch: async (target, _cutoff, limit) => {
        calls.push({ table: target.table, limit });
        const affected = Math.min(limit, backlog[target.table] ?? 0);
        backlog[target.table] = (backlog[target.table] ?? 0) - affected;
        return affected;
      },
    };
    const drains = ["a", "b", "c"].map((table) => ({ table, column: "created_at", days: 1 }));

    const result = await drainTableRetention({ now: new Date(), drains, batchSize: 500 }, dependencies);

    expect(result.byTable).toEqual({ a: 1_200, b: 0, c: 300 });
    expect(result.rowsDeleted).toBe(1_500);
    expect(result.batches).toBe(5);
    expect(result.budgetExhausted).toBeNull();
    expect(calls.map((call) => call.limit)).toEqual([500, 500, 500, 500, 500]);
  });

  test("stops at the row budget and reports it", async () => {
    const dependencies: RetentionDrainDependencies = {
      now: () => 0,
      deleteBatch: async (_target, _cutoff, limit) => limit,
    };
    const drains = [{ table: "a", column: "created_at", days: 1 }];

    const result = await drainTableRetention({ now: new Date(), drains, batchSize: 500, maxRows: 1_200 }, dependencies);

    expect(result.rowsDeleted).toBe(1_200);
    expect(result.batches).toBe(3);
    expect(result.budgetExhausted).toBe("rows");
  });

  test("stops at the time budget between batches", async () => {
    let clock = 0;
    const dependencies: RetentionDrainDependencies = {
      now: () => clock,
      deleteBatch: async (_target, _cutoff, limit) => {
        clock += 6_000;
        return limit;
      },
    };
    const drains = [{ table: "a", column: "created_at", days: 1 }];

    const result = await drainTableRetention({ now: new Date(), drains, maxDurationMs: 10_000 }, dependencies);

    expect(result.batches).toBe(2);
    expect(result.budgetExhausted).toBe("time");
  });
});
