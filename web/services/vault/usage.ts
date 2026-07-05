import { eq, sql } from "drizzle-orm";
import type { cloudDb } from "../../db/client";
import { vaultSessions, vaultSnapshots } from "../../db/schema";

type VaultDb = ReturnType<typeof cloudDb>;

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
  const [row] = await db
    .select({
      total: sql<number>`coalesce(sum(${vaultSnapshots.compressedSizeBytes}), 0)::double precision`,
    })
    .from(vaultSnapshots)
    .innerJoin(vaultSessions, eq(vaultSnapshots.sessionId, vaultSessions.id))
    .where(eq(vaultSessions.userId, userId));
  return row?.total ?? 0;
}
