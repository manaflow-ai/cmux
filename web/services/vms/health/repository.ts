import { and, desc, eq, inArray, isNotNull, lt, ne } from "drizzle-orm";
import * as Effect from "effect/Effect";
import { cloudDb } from "../../../db/client";
import { cloudVmHealthSnapshots, cloudVms } from "../../../db/schema";
import { VmDatabaseError } from "../errors";
import type { StoredVmHealthReport, VmHealthDbRow, VmHealthReport } from "./types";

/** Postgres side of the health sweep. Reads cmux rows; writes only its own snapshot table. */
export type VmHealthRepositoryMethods = {
  /** Every live row of `provider`, plus any row (destroyed included) naming one of `providerVmIds`. */
  readonly vmHealthDbRows: (input: {
    readonly provider: string;
    readonly providerVmIds: readonly string[];
  }) => Effect.Effect<VmHealthDbRow[], VmDatabaseError>;
  readonly latestVmHealthSnapshot: () => Effect.Effect<StoredVmHealthReport | null, VmDatabaseError>;
  readonly insertVmHealthSnapshot: (report: VmHealthReport) => Effect.Effect<{ readonly id: string }, VmDatabaseError>;
  readonly pruneVmHealthSnapshots: (input: { readonly before: Date }) => Effect.Effect<number, VmDatabaseError>;
};

const ID_CHUNK = 1_000;

function dbEffect<A>(operation: string, run: () => Promise<A>): Effect.Effect<A, VmDatabaseError> {
  return Effect.tryPromise({ try: run, catch: (cause) => new VmDatabaseError({ operation, cause }) });
}

const healthRowColumns = {
  id: cloudVms.id,
  providerVmId: cloudVms.providerVmId,
  userId: cloudVms.userId,
  ownerTeamId: cloudVms.ownerTeamId,
  status: cloudVms.status,
  imageId: cloudVms.imageId,
  createdAt: cloudVms.createdAt,
  updatedAt: cloudVms.updatedAt,
};

export const vmHealthRepositoryMethods: VmHealthRepositoryMethods = {
  vmHealthDbRows: (input) =>
    dbEffect("vmHealthDbRows", async () => {
      const db = cloudDb();
      const provider = input.provider as typeof cloudVms.$inferSelect.provider;
      const live = await db
        .select(healthRowColumns)
        .from(cloudVms)
        .where(and(eq(cloudVms.provider, provider), isNotNull(cloudVms.providerVmId), ne(cloudVms.status, "destroyed")));
      const rows = [...live];
      const ids = [...new Set(input.providerVmIds)];
      for (let start = 0; start < ids.length; start += ID_CHUNK) {
        const chunk = ids.slice(start, start + ID_CHUNK);
        rows.push(...await db
          .select(healthRowColumns)
          .from(cloudVms)
          .where(and(eq(cloudVms.provider, provider), eq(cloudVms.status, "destroyed"), inArray(cloudVms.providerVmId, chunk))));
      }
      return rows.flatMap((row): VmHealthDbRow[] => row.providerVmId ? [{ ...row, providerVmId: row.providerVmId }] : []);
    }),

  latestVmHealthSnapshot: () =>
    dbEffect("latestVmHealthSnapshot", async () => {
      const [row] = await cloudDb()
        .select()
        .from(cloudVmHealthSnapshots)
        .orderBy(desc(cloudVmHealthSnapshots.createdAt))
        .limit(1);
      return row ? { id: row.id, createdAt: row.createdAt, report: row.report as VmHealthReport } : null;
    }),

  insertVmHealthSnapshot: (report) =>
    dbEffect("insertVmHealthSnapshot", async () => {
      const [row] = await cloudDb()
        .insert(cloudVmHealthSnapshots)
        .values({ attentionNeeded: report.attention.needed, report, createdAt: new Date(report.generatedAt) })
        .returning({ id: cloudVmHealthSnapshots.id });
      return { id: row!.id };
    }),

  pruneVmHealthSnapshots: (input) =>
    dbEffect("pruneVmHealthSnapshots", async () => {
      const rows = await cloudDb()
        .delete(cloudVmHealthSnapshots)
        .where(lt(cloudVmHealthSnapshots.createdAt, input.before))
        .returning({ id: cloudVmHealthSnapshots.id });
      return rows.length;
    }),
};
