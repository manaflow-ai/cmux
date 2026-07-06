import { and, eq, gt, notInArray, sql } from "drizzle-orm";
import type { cloudDb } from "../../db/client";
import { vaultSessions, vaultSnapshots, vaultUploadGrants } from "../../db/schema";
import { logVaultQuotaError } from "./logging";

type VaultDb = ReturnType<typeof cloudDb>;

export async function withVaultUserQuotaLock<T>(
  db: VaultDb,
  userId: string,
  run: (db: VaultDb) => Promise<T>,
): Promise<T> {
  return await db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${userId}, 2))`);
    return await run(tx as unknown as VaultDb);
  });
}

/**
 * Total compressed bytes a user currently has stored across all snapshots.
 * Used by the uploads (presign) and commit routes to enforce the per-user
 * storage quota. Concurrent batches can each read the same total before the
 * other commits, so enforcement overshoots by at most one in-flight batch
 * (25 items x maxUploadBytes); that bound is acceptable for a cost cap.
 */
export async function getVaultStoredCompressedBytes(
  db: VaultDb,
  userId: string,
): Promise<number> {
  try {
    const [row] = await db
      .select({
        total: sql<number>`coalesce(sum(${vaultSnapshots.compressedSizeBytes}), 0)::double precision`,
      })
      .from(vaultSnapshots)
      .innerJoin(vaultSessions, eq(vaultSnapshots.sessionId, vaultSessions.id))
      .where(eq(vaultSessions.userId, userId));
    return row?.total ?? 0;
  } catch (error) {
    logVaultQuotaError("get_stored_compressed_bytes", error);
    throw error;
  }
}

/**
 * Compressed bytes reserved by unexpired upload grants (presigned PUT URLs
 * minted but not yet committed). Counting these against the quota closes the
 * bypass where a client uploads objects and never commits them: every minted
 * URL reserves capacity until it is committed or its grant expires and the
 * orphaned object is garbage-collected.
 *
 * `excludeObjectKeys` removes grants for the batch currently being
 * re-requested so a retry after a failed commit is not double-counted.
 */
export async function getVaultPendingGrantBytes(
  db: VaultDb,
  userId: string,
  now: Date,
  excludeObjectKeys: readonly string[] = [],
): Promise<number> {
  const conditions = [
    eq(vaultUploadGrants.userId, userId),
    gt(vaultUploadGrants.expiresAt, now),
  ];
  if (excludeObjectKeys.length > 0) {
    conditions.push(notInArray(vaultUploadGrants.objectKey, [...excludeObjectKeys]));
  }
  try {
    const [row] = await db
      .select({
        total: sql<number>`coalesce(sum(${vaultUploadGrants.compressedSizeBytes}), 0)::double precision`,
      })
      .from(vaultUploadGrants)
      .where(and(...conditions));
    return row?.total ?? 0;
  } catch (error) {
    logVaultQuotaError("get_pending_grant_bytes", error);
    throw error;
  }
}
