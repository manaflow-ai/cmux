import { and, asc, eq, inArray, isNull, lte, or, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { stackSessionRevocations } from "../../db/schema";
import type { StackSessionRevocationRow, StackSessionRevocationStore } from "./stackSessionRevocations";

type RevocationDb = Pick<ReturnType<typeof cloudDb>, "select" | "update" | "delete">;

const table = stackSessionRevocations;
const rowColumns = {
  stackSessionId: table.stackSessionId,
  userId: table.userId,
  attempts: table.attempts,
};

/** The durable store behind access-grant session revocation. */
export function databaseStackSessionRevocationStore(db: () => RevocationDb = cloudDb): StackSessionRevocationStore {
  return {
    async claimDue(now, limit, leaseUntil): Promise<readonly StackSessionRevocationRow[]> {
      const database = db();
      // One statement: the subquery locks the due rows it picks and skips any
      // another run holds, and the update stamps the lease, so concurrent cron
      // runs claim disjoint rows and an expired lease is claimable again.
      const due = database
        .select({ stackSessionId: table.stackSessionId })
        .from(table)
        .where(and(
          isNull(table.gaveUpAt),
          lte(table.nextAttemptAt, now),
          or(isNull(table.claimedUntil), lte(table.claimedUntil, now)),
        ))
        .orderBy(asc(table.nextAttemptAt), asc(table.stackSessionId))
        .limit(limit)
        .for("update", { skipLocked: true });
      return await database
        .update(table)
        .set({ claimedUntil: leaseUntil })
        .where(inArray(table.stackSessionId, due))
        .returning(rowColumns);
    },
    async listOpen(stackSessionIds): Promise<readonly StackSessionRevocationRow[]> {
      if (stackSessionIds.length === 0) return [];
      return await db()
        .select(rowColumns)
        .from(table)
        .where(and(inArray(table.stackSessionId, [...stackSessionIds]), isNull(table.gaveUpAt)));
    },
    async markRevoked(stackSessionId) {
      await db().delete(table).where(eq(table.stackSessionId, stackSessionId));
    },
    async recordFailure(stackSessionId, { now, error, policy }) {
      const nowParam = sql`${now.toISOString()}::timestamptz`;
      const [row] = await db()
        .update(table)
        .set({
          attempts: sql`${table.attempts} + 1`,
          lastError: error.slice(0, 200),
          claimedUntil: null,
          nextAttemptAt: sql`${nowParam} + make_interval(secs => least(${policy.baseDelayMs}::double precision * power(2, ${table.attempts}), ${policy.maxDelayMs}::double precision) / 1000.0)`,
          gaveUpAt: sql`case when ${table.attempts} + 1 >= ${policy.maxAttempts} or ${table.createdAt} <= ${nowParam} - make_interval(secs => ${policy.maxAgeMs}::double precision / 1000.0) then ${nowParam} else null end`,
        })
        .where(and(eq(table.stackSessionId, stackSessionId), isNull(table.gaveUpAt)))
        .returning({ attempts: table.attempts, gaveUpAt: table.gaveUpAt });
      return row ? { attempts: row.attempts, gaveUp: row.gaveUpAt !== null } : null;
    },
  };
}

/** Account deletion: forget the user's queued session revocations (Stack deletes the user and every session). */
export async function deleteStackSessionRevocationsForUser(
  tx: Pick<ReturnType<typeof cloudDb>, "delete">,
  userId: string,
): Promise<void> {
  await tx.delete(table).where(eq(table.userId, userId));
}
