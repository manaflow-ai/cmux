import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { sql } from "drizzle-orm";
import { Pool } from "pg";
import * as Effect from "effect/Effect";
import * as Redacted from "effect/Redacted";

import { Database, makeDatabaseRuntime } from "../db/effect";
import { HANG_REPORTS_PER_INSTALL_PER_DAY } from "../services/hangReports/ingest";
import { HangReportsRepository, HangReportsRepositoryLive, type HangReportRow } from "../services/hangReports/repository";
import { pruneExpiredHangReports } from "../services/hangReports/retention";

const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL ?? "";
const enabled = process.env.CMUX_DB_TEST === "1";
// This suite deletes every hang_reports row. Refuse anything but a local
// database so a stray DATABASE_URL can never point it at PlanetScale.
if (enabled && !isLocalDatabase(databaseURL)) {
  throw new Error("hang report DB tests run only against localhost, 127.0.0.1 or ::1");
}
const dbTest = enabled ? test : test.skip;
const runtime = enabled ? makeDatabaseRuntime({
  url: Redacted.make(databaseURL),
  maxConnections: 4,
  applicationName: "cmux-hang-reports-test",
}) : undefined;

const INSTALL = "0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20";
const DAY = "2026-10-23";

function run<A, E>(program: Effect.Effect<A, E, HangReportsRepository | Database>) {
  return runtime!.runPromise(program.pipe(Effect.provide(HangReportsRepositoryLive)));
}

function row(reportId: string, installId = INSTALL): HangReportRow {
  return {
    reportId,
    installId,
    receivedDay: DAY,
    appVersion: "0.70.0",
    appBuild: "70123",
    channel: "nightly",
    osVersion: "15.7.4",
    arch: "arm64",
    chip: "Apple M4 Pro",
    cores: 14,
    memoryGb: 48,
    counts: { windows: "1", workspaces: "2-5", panes: "2-5", tabs: "6-10" },
    payload: { schema: 2, hangs: [] },
  };
}

const insert = (value: HangReportRow) => Effect.flatMap(HangReportsRepository, (repository) =>
  repository.insertWithinDailyCap(value, HANG_REPORTS_PER_INSTALL_PER_DAY));

beforeEach(async () => {
  if (!enabled) return;
  await runtime!.runPromise(Effect.flatMap(Database, (db) => db.execute(sql`delete from hang_reports`)));
});

afterAll(async () => { await runtime?.dispose(); });

describe("hang_reports repository", () => {
  dbTest("stores once per reportId, uppercase or lowercase", async () => {
    const id = crypto.randomUUID();
    expect(await run(insert(row(id)))).toBe("inserted");
    expect(await run(insert(row(id.toUpperCase())))).toBe("duplicate");
    const rows = await run(Effect.flatMap(Database, (db) =>
      db.execute<{ total: number }>(sql`select count(*)::integer as total from hang_reports`)));
    expect(rows[0]?.total).toBe(1);
  });

  dbTest("holds the per-install daily cap under concurrent uploads", async () => {
    const outcomes = await Promise.all(Array.from({ length: 20 }, () => run(insert(row(crypto.randomUUID())))));
    expect(outcomes.filter((outcome) => outcome === "inserted")).toHaveLength(HANG_REPORTS_PER_INSTALL_PER_DAY);
    expect(outcomes.filter((outcome) => outcome === "capped")).toHaveLength(20 - HANG_REPORTS_PER_INSTALL_PER_DAY);
    expect(await run(insert(row(crypto.randomUUID(), crypto.randomUUID())))).toBe("inserted");
  });

  dbTest("deletes only rows received more than 90 days ago", async () => {
    const old = crypto.randomUUID();
    const recent = crypto.randomUUID();
    await run(insert(row(old)));
    await run(insert(row(recent)));
    await run(Effect.flatMap(Database, (db) =>
      db.execute(sql`update hang_reports set received_at = now() - interval '91 days' where report_id = ${old}`)));
    const result = await run(pruneExpiredHangReports(new Date()));
    expect(result).toEqual({ deleted: 1, complete: true });
    const rows = await run(Effect.flatMap(Database, (db) =>
      db.execute<{ report_id: string }>(sql`select report_id from hang_reports`)));
    expect(rows.map((value) => value.report_id)).toEqual([recent]);
  });
});

describe("hang_reports migration", () => {
  // Production's table was created by hand and is owned by `postgres`; the migrator's role only
  // has DML grants and may have no CREATE on the schema. Replaying the file there (its journal
  // has no row for it) must be a no-op: CREATE INDEX checks table ownership, and CREATE TABLE IF
  // NOT EXISTS checks schema CREATE, before IF NOT EXISTS, so either fails with 42501 and rolls
  // back every later migration.
  dbTest("replays as a role that does not own hang_reports", async () => {
    const pool = new Pool({ connectionString: databaseURL, max: 1 });
    const client = await pool.connect();
    try {
      await client.query("begin");
      await client.query("create role cmux_hang_reports_replay nologin");
      // USAGE only: no CREATE on the schema, no ownership of the table.
      await client.query("grant usage on schema public to cmux_hang_reports_replay");
      await client.query("set local role cmux_hang_reports_replay");
      for (const statement of migrationStatements("20261023120000_hang_reports")) await client.query(statement);
      const indexes = await client.query<{ indexname: string }>(
        "select indexname from pg_indexes where tablename = 'hang_reports' order by indexname",
      );
      expect(indexes.rows.map((value) => value.indexname)).toEqual([
        "hang_reports_install_day_idx",
        "hang_reports_pkey",
        "hang_reports_received_at_idx",
      ]);
    } finally {
      // The role and grant go with the rollback.
      await client.query("rollback");
      client.release();
      await pool.end();
    }
  });
});

function migrationStatements(name: string): string[] {
  const file = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "db", "migrations", name, "migration.sql");
  return readFileSync(file, "utf8").split("--> statement-breakpoint").map((value) => value.trim()).filter(Boolean);
}

function isLocalDatabase(url: string): boolean {
  try {
    return ["localhost", "127.0.0.1", "[::1]", "::1"].includes(new URL(url).hostname);
  } catch {
    return false;
  }
}
