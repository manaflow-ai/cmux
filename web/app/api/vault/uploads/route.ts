import { randomUUID } from "node:crypto";
import { and, eq, lt } from "drizzle-orm";
import type { Span } from "@opentelemetry/api";
import { cloudDb } from "../../../../db/client";
import { vaultSessions, vaultSnapshots, vaultUploadGrants } from "../../../../db/schema";
import { vaultConfig } from "../../../../services/vault/config";
import {
  buildObjectKey,
  buildUploadObjectKey,
  deleteObject,
  presignPut,
} from "../../../../services/vault/storage";
import {
  getVaultPendingGrantBytes,
  getVaultStoredCompressedBytes,
  withVaultUserQuotaLock,
} from "../../../../services/vault/usage";
import { withAuthedVaultApiRoute } from "../../../../services/vault/routeHelpers";
import { readVaultJsonObject, validateVaultBatch } from "../../../../services/vault/validation";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../services/telemetry";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// A grant reserves quota from presign until commit. The TTL is deliberately
// generous (a slow batch of large uploads can take hours) because an unexpired
// grant only over-reserves the owner's own quota; after expiry the orphaned
// object is deleted by the opportunistic GC below.
const UPLOAD_GRANT_TTL_MS = 24 * 60 * 60 * 1000;
const GRANT_GC_BATCH = 10;

type ExistingUploadGrant = {
  readonly id: string;
  readonly uploadObjectKey: string;
  readonly compressedSizeBytes: number;
  readonly reservationToken: string;
  readonly createdAt: Date;
  readonly expiresAt: Date;
};

type VaultUploadItemBase = {
  readonly agent: string;
  readonly agentSessionId: string;
  readonly relPath: string;
};

type ReservedUploadResult =
  | (VaultUploadItemBase & {
    readonly status: "error";
    readonly error: string;
  })
  | (VaultUploadItemBase & {
    readonly status: "unchanged";
  })
  | (VaultUploadItemBase & {
    readonly status: "upload";
    readonly grantId: string;
    readonly grantReservationToken: string;
    readonly previousGrant: ExistingUploadGrant | null;
    readonly objectKey: string;
    readonly uploadObjectKey: string;
    readonly compressedSizeBytes: number;
  });

type VaultUploadResponseItem =
  | (VaultUploadItemBase & {
    readonly status: "error";
    readonly error: string;
  })
  | (VaultUploadItemBase & {
    readonly status: "unchanged";
  })
  | (VaultUploadItemBase & {
    readonly status: "upload";
    readonly objectKey: string;
    readonly putUrl: string;
  });

export async function POST(request: Request): Promise<Response> {
  return withAuthedVaultApiRoute(
    request,
    "/api/vault/uploads",
    { "cmux.vault.operation": "uploads.presign" },
    "/api/vault/uploads POST failed",
    { allowCookie: false },
    async ({ user, span }) => {
      return handlePost(request, user.id, span);
    },
  );
}

async function handlePost(request: Request, userId: string, span: Span): Promise<Response> {
  const body = await readVaultJsonObject(request);
  if (!body.ok) {
    return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  }
  const batch = validateVaultBatch(body.value);
  if (!batch.ok) return jsonResponse({ error: batch.error }, 400);
  setSpanAttributes(span, {
    "cmux.vault.item_count": batch.value.length,
    "cmux.vault.raw_bytes": sumBatchRawBytes(batch.value),
    "cmux.vault.compressed_bytes": sumBatchCompressedBytes(batch.value),
  });

  const config = vaultConfig();
  const db = cloudDb();
  const now = new Date();

  const reservedResults = await withVaultUserQuotaLock(db, userId, async (lockedDb) => {
    await gcExpiredGrants(lockedDb, userId, now);

    // Per-user storage quota covers committed snapshots plus unexpired upload
    // grants, so minting URLs and never committing still consumes quota (the
    // presigned ContentLength is signed, bounding each upload to its declared
    // size). Grants for keys in this batch are excluded from the pending sum and
    // re-added per item below, so retries are not double-counted. The commit
    // route re-checks, so previously issued URLs cannot bypass the quota either.
    const batchObjectKeys = [...new Set(batch.value.map((item) =>
      buildObjectKey(userId, item.agent, item.agentSessionId, item.sha256),
    ))];
    let projectedUserBytes =
      (await getVaultStoredCompressedBytes(lockedDb, userId)) +
      (await getVaultPendingGrantBytes(lockedDb, userId, now, batchObjectKeys));
    const lockedResults: ReservedUploadResult[] = [];
    const objectKeysCreatedInRequest = new Set<string>();
    const objectKeysSeenInRequest = new Set<string>();
    for (const item of batch.value) {
      const objectKey = buildObjectKey(userId, item.agent, item.agentSessionId, item.sha256);
      if (objectKeysSeenInRequest.has(objectKey)) {
        lockedResults.push({
          agent: item.agent,
          agentSessionId: item.agentSessionId,
          relPath: item.relPath,
          status: "error",
          error: "duplicate_object_key",
        });
        continue;
      }
      objectKeysSeenInRequest.add(objectKey);

      // Per-item so one oversized transcript cannot block the rest of the batch.
      if (item.compressedSizeBytes > config.maxUploadBytes) {
        lockedResults.push({
          agent: item.agent,
          agentSessionId: item.agentSessionId,
          relPath: item.relPath,
          status: "error",
          error: "upload_too_large",
        });
        continue;
      }
      if (projectedUserBytes + item.compressedSizeBytes > config.maxUserBytes) {
        lockedResults.push({
          agent: item.agent,
          agentSessionId: item.agentSessionId,
          relPath: item.relPath,
          status: "error",
          error: "quota_exceeded",
        });
        continue;
      }

      const [existing] = await lockedDb
        .select({
          id: vaultSessions.id,
          latestSha256: vaultSessions.latestSha256,
          relPath: vaultSessions.relPath,
          cwd: vaultSessions.cwd,
        })
        .from(vaultSessions)
        .where(
          and(
            eq(vaultSessions.userId, userId),
            eq(vaultSessions.agent, item.agent),
            eq(vaultSessions.agentSessionId, item.agentSessionId),
          ),
        )
        .limit(1);

      if (existing && existing.latestSha256 === item.sha256) {
        // Same content can still move on disk (e.g. Codex archiving a session),
        // so keep the restore metadata current even when no upload is needed.
        if (existing.relPath !== item.relPath || existing.cwd !== item.cwd) {
          await lockedDb
            .update(vaultSessions)
            .set({ relPath: item.relPath, cwd: item.cwd })
            .where(eq(vaultSessions.id, existing.id));
        }
        lockedResults.push({
          agent: item.agent,
          agentSessionId: item.agentSessionId,
          relPath: item.relPath,
          status: "unchanged",
        });
        continue;
      }

      const grantExpiresAt = new Date(now.getTime() + UPLOAD_GRANT_TTL_MS);
      const [previousGrant] = await lockedDb
        .select({
          id: vaultUploadGrants.id,
          uploadObjectKey: vaultUploadGrants.uploadObjectKey,
          compressedSizeBytes: vaultUploadGrants.compressedSizeBytes,
          reservationToken: vaultUploadGrants.reservationToken,
          createdAt: vaultUploadGrants.createdAt,
          expiresAt: vaultUploadGrants.expiresAt,
        })
        .from(vaultUploadGrants)
        .where(eq(vaultUploadGrants.objectKey, objectKey))
        .limit(1);
      const reusePreviousUploadKey = previousGrant && previousGrant.expiresAt > now;
      const grantReservationToken = randomUUID();
      const uploadObjectKey = reusePreviousUploadKey
        ? previousGrant.uploadObjectKey
        : buildUploadObjectKey(objectKey, grantReservationToken);
      const [grant] = await lockedDb
        .insert(vaultUploadGrants)
        .values({
          userId,
          objectKey,
          uploadObjectKey,
          compressedSizeBytes: item.compressedSizeBytes,
          reservationToken: grantReservationToken,
          createdAt: now,
          expiresAt: grantExpiresAt,
        })
        .onConflictDoUpdate({
          target: vaultUploadGrants.objectKey,
          set: {
            uploadObjectKey,
            compressedSizeBytes: item.compressedSizeBytes,
            reservationToken: grantReservationToken,
            createdAt: now,
            expiresAt: grantExpiresAt,
          },
        })
        .returning({ id: vaultUploadGrants.id });
      if (!grant) throw new Error("vault upload grant upsert returned no row");
      if (!previousGrant) objectKeysCreatedInRequest.add(objectKey);
      projectedUserBytes += item.compressedSizeBytes;
      lockedResults.push({
        agent: item.agent,
        agentSessionId: item.agentSessionId,
        relPath: item.relPath,
        status: "upload",
        grantId: grant.id,
        grantReservationToken,
        previousGrant: previousGrant && !objectKeysCreatedInRequest.has(objectKey)
          ? previousGrant
          : null,
        objectKey,
        uploadObjectKey,
        compressedSizeBytes: item.compressedSizeBytes,
      });
    }
    return lockedResults;
  });
  const results = await presignReservedUploads(db, reservedResults);
  setSpanAttributes(span, {
    "cmux.vault.result_count": results.length,
    "cmux.vault.result.upload_count": countResultStatus(results, "upload"),
    "cmux.vault.result.unchanged_count": countResultStatus(results, "unchanged"),
    "cmux.vault.result.error_count": countResultStatus(results, "error"),
  });
  return jsonResponse({ items: results });
}

async function presignReservedUploads(
  db: ReturnType<typeof cloudDb>,
  items: readonly ReservedUploadResult[],
): Promise<VaultUploadResponseItem[]> {
  const results: VaultUploadResponseItem[] = [];
  const successfulObjectKeys = new Set<string>();
  const failedReservations = new Map<string, Extract<ReservedUploadResult, { status: "upload" }>>();
  for (const item of items) {
    if (item.status !== "upload") {
      results.push(item);
      continue;
    }
    try {
      results.push({
        agent: item.agent,
        agentSessionId: item.agentSessionId,
        relPath: item.relPath,
        status: "upload",
        objectKey: item.objectKey,
        putUrl: await presignPut(item.uploadObjectKey, item.compressedSizeBytes),
      });
      successfulObjectKeys.add(item.objectKey);
    } catch {
      failedReservations.set(item.objectKey, item);
      results.push({
        agent: item.agent,
        agentSessionId: item.agentSessionId,
        relPath: item.relPath,
        status: "error",
        error: "upload_presign_failed",
      });
    }
  }
  for (const item of failedReservations.values()) {
    if (successfulObjectKeys.has(item.objectKey)) continue;
    if (item.previousGrant) {
      await db
        .update(vaultUploadGrants)
        .set({
          compressedSizeBytes: item.previousGrant.compressedSizeBytes,
          uploadObjectKey: item.previousGrant.uploadObjectKey,
          reservationToken: item.previousGrant.reservationToken,
          createdAt: item.previousGrant.createdAt,
          expiresAt: item.previousGrant.expiresAt,
        })
        .where(and(
          eq(vaultUploadGrants.id, item.previousGrant.id),
          eq(vaultUploadGrants.objectKey, item.objectKey),
          eq(vaultUploadGrants.reservationToken, item.grantReservationToken),
        ))
        .catch(() => undefined);
      continue;
    }
    await db
      .delete(vaultUploadGrants)
      .where(and(
        eq(vaultUploadGrants.id, item.grantId),
        eq(vaultUploadGrants.objectKey, item.objectKey),
        eq(vaultUploadGrants.reservationToken, item.grantReservationToken),
      ))
      .catch(() => undefined);
  }
  return results;
}

/**
 * Opportunistically clean up expired grants: delete the storage object when it
 * was uploaded but never committed, then drop the grant row. Runs a small
 * bounded batch per request (same pattern as the CLI auth start GC). If the
 * object deletion fails, the row is kept so a later pass retries.
 */
async function gcExpiredGrants(
  db: ReturnType<typeof cloudDb>,
  userId: string,
  now: Date,
): Promise<void> {
  const expired = await db
    .select({
      id: vaultUploadGrants.id,
      objectKey: vaultUploadGrants.objectKey,
      uploadObjectKey: vaultUploadGrants.uploadObjectKey,
      expiresAt: vaultUploadGrants.expiresAt,
    })
    .from(vaultUploadGrants)
    .where(and(
      eq(vaultUploadGrants.userId, userId),
      lt(vaultUploadGrants.expiresAt, now),
    ))
    .limit(GRANT_GC_BATCH);
  if (expired.length === 0) return;

  for (const grant of expired) {
    const legacyFinalKeyGrant = grant.uploadObjectKey === grant.objectKey;
    try {
      if (!legacyFinalKeyGrant) await deleteObject(grant.uploadObjectKey);
      const [committed] = await db
        .select({ objectKey: vaultSnapshots.objectKey })
        .from(vaultSnapshots)
        .where(eq(vaultSnapshots.objectKey, grant.objectKey))
        .limit(1);
      if (!committed) await deleteObject(grant.objectKey);
    } catch {
      continue;
    }
    await db.delete(vaultUploadGrants).where(and(
      eq(vaultUploadGrants.id, grant.id),
      eq(vaultUploadGrants.userId, userId),
      eq(vaultUploadGrants.objectKey, grant.objectKey),
      eq(vaultUploadGrants.uploadObjectKey, grant.uploadObjectKey),
      eq(vaultUploadGrants.expiresAt, grant.expiresAt),
    ));
  }
}

function sumBatchRawBytes(items: readonly { sizeBytes: number }[]): number {
  return items.reduce((total, item) => total + item.sizeBytes, 0);
}

function sumBatchCompressedBytes(items: readonly { compressedSizeBytes: number }[]): number {
  return items.reduce((total, item) => total + item.compressedSizeBytes, 0);
}

function countResultStatus(items: readonly { status: string }[], status: string): number {
  return items.filter((item) => item.status === status).length;
}
