import { and, asc, count, eq, inArray, lt, sql } from "drizzle-orm";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { Database } from "../../db/effect";
import { hangReports } from "../../db/schema";
import { HangReportStorageUnavailable, storageUnavailable } from "./errors";

/** One row of `hang_reports`, built from a validated report. Holds no IP or user agent. */
export type HangReportRow = {
  readonly reportId: string;
  readonly installId: string;
  readonly receivedDay: string;
  readonly appVersion: string;
  readonly appBuild: string;
  readonly channel: string;
  readonly osVersion: string;
  readonly arch: string;
  readonly chip: string;
  readonly cores: number;
  readonly memoryGb: number;
  readonly counts: Record<string, string>;
  readonly payload: Record<string, unknown>;
};

export type InsertOutcome = "inserted" | "duplicate" | "capped";

export type HangReportsRepositoryShape = {
  /**
   * Store a row unless its `reportId` is already stored (`duplicate`) or its
   * install already has `dailyCap` rows on the row's `receivedDay` (`capped`).
   * A duplicate wins over the cap so a client retrying a stored report stops.
   */
  readonly insertWithinDailyCap: (
    row: HangReportRow,
    dailyCap: number,
  ) => Effect.Effect<InsertOutcome, HangReportStorageUnavailable>;
  /** Delete at most `limit` rows received before `cutoff`, oldest first. Returns the count. */
  readonly deleteReceivedBefore: (
    cutoff: Date,
    limit: number,
  ) => Effect.Effect<number, HangReportStorageUnavailable>;
};

export class HangReportsRepository extends Context.Tag("cmux/HangReportsRepository")<
  HangReportsRepository,
  HangReportsRepositoryShape
>() {}

/**
 * Run one storage operation. A failure keeps only its tag and SQLSTATE (see
 * ``HangReportStorageUnavailable``), so query parameters never leave here.
 */
export function storage<A, E>(operation: string, run: () => Effect.Effect<A, E>): Effect.Effect<A, HangReportStorageUnavailable> {
  return Effect.suspend(run).pipe(
    Effect.mapError((cause) => cause instanceof HangReportStorageUnavailable ? cause : storageUnavailable(operation, cause)),
    Effect.withSpan(`hang_reports.database.${operation}`),
  );
}

export const makeHangReportsRepository = Effect.gen(function* () {
  const db = yield* Database;
  const repository: HangReportsRepositoryShape = {
    insertWithinDailyCap: (row, dailyCap) => storage("insert", () => db.transaction((tx) => Effect.gen(function* () {
      // Serialize writers for one install and day so the cap holds under
      // concurrent uploads from the same Mac.
      const lockKey = `hang_reports:${row.installId.toLowerCase()}:${row.receivedDay}`;
      yield* tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${lockKey}, 0))`);
      const [existing] = yield* tx
        .select({ reportId: hangReports.reportId })
        .from(hangReports)
        .where(eq(hangReports.reportId, row.reportId))
        .limit(1);
      if (existing) return "duplicate" as const;
      const [stored] = yield* tx
        .select({ total: count() })
        .from(hangReports)
        .where(and(eq(hangReports.installId, row.installId), eq(hangReports.receivedDay, row.receivedDay)));
      if ((stored?.total ?? 0) >= dailyCap) return "capped" as const;
      const inserted = yield* tx
        .insert(hangReports)
        .values(row)
        .onConflictDoNothing({ target: hangReports.reportId })
        .returning({ reportId: hangReports.reportId });
      return inserted.length > 0 ? "inserted" as const : "duplicate" as const;
    // Sanitize inside the transaction: its `sql.transaction` span records the
    // failure it sees, and a drizzle query error's message lists the params.
    }).pipe(Effect.mapError((cause) => storageUnavailable("insert", cause))))),
    deleteReceivedBefore: (cutoff, limit) => storage("deleteReceivedBefore", () => Effect.gen(function* () {
      const deleted = yield* db
        .delete(hangReports)
        .where(inArray(hangReports.reportId, db
          .select({ reportId: hangReports.reportId })
          .from(hangReports)
          .where(lt(hangReports.receivedAt, cutoff))
          .orderBy(asc(hangReports.receivedAt))
          .limit(limit)))
        .returning({ reportId: hangReports.reportId });
      return deleted.length;
    })),
  };
  return repository;
});

/** The Postgres-backed repository; requires the Effect ``Database`` service. */
export const HangReportsRepositoryLive = Layer.effect(HangReportsRepository, makeHangReportsRepository);
