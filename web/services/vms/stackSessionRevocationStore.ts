import { and, asc, inArray, isNull, lte, eq } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { stackSessionRevocations } from "../../db/schema";
import type { StackSessionRevocationRow, StackSessionRevocationStore } from "./stackSessionRevocations";

type RevocationDb = Pick<ReturnType<typeof cloudDb>, "select" | "insert" | "update">;

/** The durable store behind access-grant session revocation. */
export function databaseStackSessionRevocationStore(db: () => RevocationDb = cloudDb): StackSessionRevocationStore {
  const columns = {
    stackSessionId: stackSessionRevocations.stackSessionId,
    userId: stackSessionRevocations.userId,
    attempts: stackSessionRevocations.attempts,
  };
  return {
    async enqueue({ userId, accessGrantId, stackSessionIds }) {
      if (stackSessionIds.length === 0) return;
      await db()
        .insert(stackSessionRevocations)
        .values(stackSessionIds.map((stackSessionId) => ({ stackSessionId, userId, accessGrantId })))
        .onConflictDoNothing({ target: stackSessionRevocations.stackSessionId });
    },
    async listDue(now, limit): Promise<readonly StackSessionRevocationRow[]> {
      return await db()
        .select(columns)
        .from(stackSessionRevocations)
        .where(and(isNull(stackSessionRevocations.revokedAt), lte(stackSessionRevocations.nextAttemptAt, now)))
        .orderBy(asc(stackSessionRevocations.nextAttemptAt), asc(stackSessionRevocations.stackSessionId))
        .limit(limit);
    },
    async listOpen(stackSessionIds): Promise<readonly StackSessionRevocationRow[]> {
      if (stackSessionIds.length === 0) return [];
      return await db()
        .select(columns)
        .from(stackSessionRevocations)
        .where(and(
          inArray(stackSessionRevocations.stackSessionId, [...stackSessionIds]),
          isNull(stackSessionRevocations.revokedAt),
        ));
    },
    async markRevoked(stackSessionId, at) {
      await db()
        .update(stackSessionRevocations)
        .set({ revokedAt: at, lastError: null })
        .where(eq(stackSessionRevocations.stackSessionId, stackSessionId));
    },
    async markFailed(stackSessionId, { attempts, nextAttemptAt, error }) {
      await db()
        .update(stackSessionRevocations)
        .set({ attempts, nextAttemptAt, lastError: error.slice(0, 200) })
        .where(and(
          eq(stackSessionRevocations.stackSessionId, stackSessionId),
          isNull(stackSessionRevocations.revokedAt),
        ));
    },
  };
}
