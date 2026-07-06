import { and, eq, gt, notInArray, sql } from "drizzle-orm";
import type { cloudDb } from "../../db/client";
import { vaultSessions, vaultSnapshots, vaultUploadGrants } from "../../db/schema";
import { buildObjectKey } from "./storage";
import { logVaultQuotaError } from "./logging";

type CloudDb = ReturnType<typeof cloudDb>;
type VaultTx = Parameters<Parameters<CloudDb["transaction"]>[0]>[0];
type VaultDb = CloudDb | VaultTx;

export type VaultGrantItem = {
  agent: string;
  agentSessionId: string;
  sha256: string;
  relPath: string;
  cwd: string | null;
  compressedSizeBytes: number;
};

export type VaultReservationOutcome =
  | { kind: "granted"; objectKey: string; item: VaultGrantItem }
  | { kind: "unchanged"; item: VaultGrantItem }
  | { kind: "error"; error: "upload_too_large" | "quota_exceeded"; item: VaultGrantItem };

export type VaultReserveHooks = { afterQuotaRead?: () => Promise<void> };

/**
 * Total compressed bytes a user currently has stored across all snapshots.
 * Used by the uploads (presign) and commit routes to enforce the per-user
 * storage quota.
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

export async function reserveVaultUploadGrants(
  db: CloudDb,
  params: {
    userId: string;
    items: readonly VaultGrantItem[];
    maxUploadBytes: number;
    maxUserBytes: number;
    now: Date;
    grantTtlMs: number;
  },
  hooks: VaultReserveHooks = {},
): Promise<VaultReservationOutcome[]> {
  const batchObjectKeys = params.items.map((item) =>
    buildObjectKey(params.userId, item.agent, item.agentSessionId, item.sha256),
  );
  const expiresAt = new Date(params.now.getTime() + params.grantTtlMs);

  return await db.transaction(async (tx) => {
    let projectedUserBytes =
      (await getVaultStoredCompressedBytes(tx, params.userId)) +
      (await getVaultPendingGrantBytes(tx, params.userId, params.now, batchObjectKeys));

    await hooks.afterQuotaRead?.();

    const outcomes: VaultReservationOutcome[] = [];
    for (const item of params.items) {
      if (item.compressedSizeBytes > params.maxUploadBytes) {
        outcomes.push({ kind: "error", error: "upload_too_large", item });
        continue;
      }
      if (projectedUserBytes + item.compressedSizeBytes > params.maxUserBytes) {
        outcomes.push({ kind: "error", error: "quota_exceeded", item });
        continue;
      }

      const [existing] = await tx
        .select({
          id: vaultSessions.id,
          latestSha256: vaultSessions.latestSha256,
          relPath: vaultSessions.relPath,
          cwd: vaultSessions.cwd,
        })
        .from(vaultSessions)
        .where(
          and(
            eq(vaultSessions.userId, params.userId),
            eq(vaultSessions.agent, item.agent),
            eq(vaultSessions.agentSessionId, item.agentSessionId),
          ),
        )
        .limit(1);

      if (existing && existing.latestSha256 === item.sha256) {
        if (existing.relPath !== item.relPath || existing.cwd !== item.cwd) {
          await tx
            .update(vaultSessions)
            .set({ relPath: item.relPath, cwd: item.cwd })
            .where(eq(vaultSessions.id, existing.id));
        }
        outcomes.push({ kind: "unchanged", item });
        continue;
      }

      const objectKey = buildObjectKey(params.userId, item.agent, item.agentSessionId, item.sha256);
      await tx
        .insert(vaultUploadGrants)
        .values({
          userId: params.userId,
          objectKey,
          compressedSizeBytes: item.compressedSizeBytes,
          createdAt: params.now,
          expiresAt,
        })
        .onConflictDoUpdate({
          target: vaultUploadGrants.objectKey,
          set: {
            compressedSizeBytes: item.compressedSizeBytes,
            createdAt: params.now,
            expiresAt,
          },
        });
      projectedUserBytes += item.compressedSizeBytes;
      outcomes.push({ kind: "granted", objectKey, item });
    }

    return outcomes;
  });
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
