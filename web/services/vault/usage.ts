import { and, eq, gt, notInArray, sql } from "drizzle-orm";
import type { cloudDb } from "../../db/client";
import { accountDeletionTombstones, vaultSessions, vaultSnapshots, vaultUploadGrants } from "../../db/schema";
import {
  accountDeletionAdvisoryLockKey,
  accountDeletionUserHash,
  isBlockingAccountDeletionStatus,
} from "../account/deletionLock";
import { logVaultQuotaError } from "./logging";

type VaultDb = ReturnType<typeof cloudDb>;
const VAULT_QUOTA_LOCK_NAMESPACE = 9;

export type VaultUserQuotaLockOptions = {
  readonly allowAccountDeletion?: boolean;
};

export class VaultWritesDisabledError extends Error {
  constructor() {
    super("Vault writes are disabled while account deletion is in progress.");
    this.name = "VaultWritesDisabledError";
  }
}

export async function withVaultUserQuotaLock<T>(
  db: VaultDb,
  userId: string,
  run: (db: VaultDb) => Promise<T>,
  options: VaultUserQuotaLockOptions = {},
): Promise<T> {
  return await db.transaction(async (tx) => {
    await tx.execute(sql`set local lock_timeout = '5s'`);
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${userId}, ${VAULT_QUOTA_LOCK_NAMESPACE}))`);
    const lockedDb = tx as unknown as VaultDb;
    if (!options.allowAccountDeletion) {
      await assertVaultWritesAllowed(lockedDb, userId);
    }
    return await run(lockedDb);
  });
}

async function assertVaultWritesAllowed(db: VaultDb, userId: string): Promise<void> {
  await db.execute(sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(userId)}, 0))`);
  const userIdHash = accountDeletionUserHash(userId);
  const [deletion] = await db
    .select({
      userIdHash: accountDeletionTombstones.userIdHash,
      status: accountDeletionTombstones.status,
    })
    .from(accountDeletionTombstones)
    .where(eq(accountDeletionTombstones.userIdHash, userIdHash))
    .limit(1);
  if (deletion?.userIdHash === userIdHash && isBlockingAccountDeletionStatus(deletion.status)) {
    throw new VaultWritesDisabledError();
  }
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
      .where(and(
        ...conditions,
        sql`not exists (
          select 1 from ${vaultSnapshots}
          where ${vaultSnapshots.objectKey} = ${vaultUploadGrants.objectKey}
        )`,
      ));
    return row?.total ?? 0;
  } catch (error) {
    logVaultQuotaError("get_pending_grant_bytes", error);
    throw error;
  }
}
