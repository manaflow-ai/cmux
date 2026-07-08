import { and, eq, gt } from "drizzle-orm";
import type { Span } from "@opentelemetry/api";
import { cloudDb } from "../../../../../db/client";
import { vaultSessions, vaultSnapshots, vaultUploadGrants } from "../../../../../db/schema";
import { vaultConfig } from "../../../../../services/vault/config";
import { withAuthedVaultApiRoute } from "../../../../../services/vault/routeHelpers";
import {
  buildObjectKey,
  copyObject,
  deleteObject,
  headObject,
} from "../../../../../services/vault/storage";
import {
  getVaultStoredCompressedBytes,
  withVaultUserQuotaLock,
} from "../../../../../services/vault/usage";
import { readVaultJsonObject, validateVaultBatch } from "../../../../../services/vault/validation";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  return withAuthedVaultApiRoute(
    request,
    "/api/vault/sessions/commit",
    { "cmux.vault.operation": "sessions.commit" },
    "/api/vault/sessions/commit POST failed",
    { allowCookie: false },
    async ({ user, span }) => handlePost(request, user.id, span),
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
  const stagingCleanups: { grantId: string; objectKey: string; uploadObjectKey: string }[] = [];
  const copiedFinalObjectKeys: string[] = [];
  let results;
  try {
    results = await withVaultUserQuotaLock(db, userId, async (lockedDb) => {
      // Re-check the per-user quota at commit time under the same lock used by
      // presign. The current grant must still match this commit, so older
      // presigned URLs cannot outlive a later downsized reservation.
      let projectedUserBytes = await getVaultStoredCompressedBytes(lockedDb, userId);
      const lockedResults = [];
      for (const item of batch.value) {
        // Per-item so one oversized transcript cannot block the rest of the batch.
        if (item.compressedSizeBytes > config.maxUploadBytes) {
          lockedResults.push(itemResult(item, "error", "upload_too_large"));
          continue;
        }

        const objectKey = buildObjectKey(userId, item.agent, item.agentSessionId, item.sha256);
        const now = new Date();
        const existingCommit = await findCommittedSnapshot(lockedDb, userId, item, objectKey);
        if (existingCommit) {
          lockedResults.push({
            agent: item.agent,
            agentSessionId: item.agentSessionId,
            relPath: item.relPath,
            status: "committed",
            sessionId: existingCommit.sessionId,
          });
          continue;
        }

        const [grant] = await lockedDb
          .select({
            id: vaultUploadGrants.id,
            uploadObjectKey: vaultUploadGrants.uploadObjectKey,
            compressedSizeBytes: vaultUploadGrants.compressedSizeBytes,
          })
          .from(vaultUploadGrants)
          .where(and(
            eq(vaultUploadGrants.userId, userId),
            eq(vaultUploadGrants.objectKey, objectKey),
            gt(vaultUploadGrants.expiresAt, now),
          ))
          .limit(1);
        if (!grant) {
          lockedResults.push(itemResult(item, "error", "upload_grant_missing"));
          continue;
        }
        if (grant.compressedSizeBytes !== item.compressedSizeBytes) {
          lockedResults.push(itemResult(item, "error", "upload_grant_mismatch"));
          continue;
        }

        if (projectedUserBytes + item.compressedSizeBytes > config.maxUserBytes) {
          lockedResults.push(itemResult(item, "error", "quota_exceeded"));
          continue;
        }

        const legacyFinalKeyGrant = grant.uploadObjectKey === objectKey;
        const object = await headObject(grant.uploadObjectKey);
        if (!object) {
          lockedResults.push(itemResult(item, "error", "object_missing"));
          continue;
        }
        // Some S3-compatible stores omit Content-Length on HEAD; only enforce the
        // size check when the store reports one.
        if (object.contentLength != null && object.contentLength !== item.compressedSizeBytes) {
          lockedResults.push(itemResult(item, "error", "size_mismatch"));
          continue;
        }

        if (!legacyFinalKeyGrant) {
          await copyObject(grant.uploadObjectKey, objectKey);
          copiedFinalObjectKeys.push(objectKey);
        }

        const [session] = await lockedDb
          .insert(vaultSessions)
          .values({
            userId,
            agent: item.agent,
            agentSessionId: item.agentSessionId,
            relPath: item.relPath,
            cwd: item.cwd,
            latestSha256: item.sha256,
            latestObjectKey: objectKey,
            sizeBytes: item.sizeBytes,
            compressedSizeBytes: item.compressedSizeBytes,
            firstUploadedAt: now,
            lastUploadedAt: now,
            metadata: {},
          })
          .onConflictDoUpdate({
            target: [vaultSessions.userId, vaultSessions.agent, vaultSessions.agentSessionId],
            set: {
              relPath: item.relPath,
              cwd: item.cwd,
              latestSha256: item.sha256,
              latestObjectKey: objectKey,
              sizeBytes: item.sizeBytes,
              compressedSizeBytes: item.compressedSizeBytes,
              lastUploadedAt: now,
            },
          })
          .returning({ id: vaultSessions.id });

        await lockedDb
          .insert(vaultSnapshots)
          .values({
            sessionId: session.id,
            sha256: item.sha256,
            objectKey,
            sizeBytes: item.sizeBytes,
            compressedSizeBytes: item.compressedSizeBytes,
            uploadedAt: now,
          })
          .onConflictDoNothing({
            target: [vaultSnapshots.sessionId, vaultSnapshots.sha256],
          });

        if (legacyFinalKeyGrant) {
          await lockedDb.delete(vaultUploadGrants).where(eq(vaultUploadGrants.id, grant.id));
        } else {
          stagingCleanups.push({
            grantId: grant.id,
            objectKey,
            uploadObjectKey: grant.uploadObjectKey,
          });
        }

        projectedUserBytes += item.compressedSizeBytes;
        lockedResults.push({
          agent: item.agent,
          agentSessionId: item.agentSessionId,
          relPath: item.relPath,
          status: "committed",
          sessionId: session.id,
        });
      }
      return lockedResults;
    });
  } catch (error) {
    await Promise.allSettled(copiedFinalObjectKeys.map((objectKey) => deleteObject(objectKey)));
    throw error;
  }
  await cleanupCommittedStagingGrants(db, stagingCleanups);
  setSpanAttributes(span, {
    "cmux.vault.result_count": results.length,
    "cmux.vault.result.committed_count": countResultStatus(results, "committed"),
    "cmux.vault.result.error_count": countResultStatus(results, "error"),
  });
  return jsonResponse({ items: results });
}

async function cleanupCommittedStagingGrants(
  db: ReturnType<typeof cloudDb>,
  grants: readonly { grantId: string; objectKey: string; uploadObjectKey: string }[],
): Promise<void> {
  for (const grant of grants) {
    try {
      await deleteObject(grant.uploadObjectKey);
      await db.delete(vaultUploadGrants).where(and(
        eq(vaultUploadGrants.id, grant.grantId),
        eq(vaultUploadGrants.objectKey, grant.objectKey),
        eq(vaultUploadGrants.uploadObjectKey, grant.uploadObjectKey),
      ));
    } catch {
      // Keep the grant row so expired-grant GC can retry staging cleanup.
    }
  }
}

async function findCommittedSnapshot(
  db: ReturnType<typeof cloudDb>,
  userId: string,
  item: {
    readonly agent: string;
    readonly agentSessionId: string;
    readonly sha256: string;
  },
  objectKey: string,
): Promise<{ readonly sessionId: string } | null> {
  const [existing] = await db
    .select({ sessionId: vaultSessions.id })
    .from(vaultSessions)
    .innerJoin(vaultSnapshots, eq(vaultSnapshots.sessionId, vaultSessions.id))
    .where(and(
      eq(vaultSessions.userId, userId),
      eq(vaultSessions.agent, item.agent),
      eq(vaultSessions.agentSessionId, item.agentSessionId),
      eq(vaultSnapshots.sha256, item.sha256),
      eq(vaultSnapshots.objectKey, objectKey),
    ))
    .limit(1);
  return existing ?? null;
}

function itemResult(
  item: { agent: string; agentSessionId: string; relPath: string },
  status: string,
  error: string,
) {
  return {
    agent: item.agent,
    agentSessionId: item.agentSessionId,
    relPath: item.relPath,
    status,
    error,
  };
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
