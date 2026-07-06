import { and, eq, inArray, lt } from "drizzle-orm";
import type { Span } from "@opentelemetry/api";
import { cloudDb } from "../../../../db/client";
import { vaultSessions, vaultSnapshots, vaultUploadGrants } from "../../../../db/schema";
import { vaultConfig } from "../../../../services/vault/config";
import { buildObjectKey, deleteObject, presignPut } from "../../../../services/vault/storage";
import {
  getVaultPendingGrantBytes,
  getVaultStoredCompressedBytes,
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

  await gcExpiredGrants(db, now);

  // Per-user storage quota covers committed snapshots plus unexpired upload
  // grants, so minting URLs and never committing still consumes quota (the
  // presigned ContentLength is signed, bounding each upload to its declared
  // size). Grants for keys in this batch are excluded from the pending sum and
  // re-added per item below, so retries are not double-counted. The commit
  // route re-checks, so previously issued URLs cannot bypass the quota either.
  const batchObjectKeys = batch.value.map((item) =>
    buildObjectKey(userId, item.agent, item.agentSessionId, item.sha256),
  );
  let projectedUserBytes =
    (await getVaultStoredCompressedBytes(db, userId)) +
    (await getVaultPendingGrantBytes(db, userId, now, batchObjectKeys));
  const results = [];
  for (const item of batch.value) {
    // Per-item so one oversized transcript cannot block the rest of the batch.
    if (item.compressedSizeBytes > config.maxUploadBytes) {
      results.push({
        agent: item.agent,
        agentSessionId: item.agentSessionId,
        relPath: item.relPath,
        status: "error",
        error: "upload_too_large",
      });
      continue;
    }
    if (projectedUserBytes + item.compressedSizeBytes > config.maxUserBytes) {
      results.push({
        agent: item.agent,
        agentSessionId: item.agentSessionId,
        relPath: item.relPath,
        status: "error",
        error: "quota_exceeded",
      });
      continue;
    }

    const [existing] = await db
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
        await db
          .update(vaultSessions)
          .set({ relPath: item.relPath, cwd: item.cwd })
          .where(eq(vaultSessions.id, existing.id));
      }
      results.push({
        agent: item.agent,
        agentSessionId: item.agentSessionId,
        relPath: item.relPath,
        status: "unchanged",
      });
      continue;
    }

    const objectKey = buildObjectKey(userId, item.agent, item.agentSessionId, item.sha256);
    await db
      .insert(vaultUploadGrants)
      .values({
        userId,
        objectKey,
        compressedSizeBytes: item.compressedSizeBytes,
        createdAt: now,
        expiresAt: new Date(now.getTime() + UPLOAD_GRANT_TTL_MS),
      })
      .onConflictDoUpdate({
        target: vaultUploadGrants.objectKey,
        set: {
          compressedSizeBytes: item.compressedSizeBytes,
          createdAt: now,
          expiresAt: new Date(now.getTime() + UPLOAD_GRANT_TTL_MS),
        },
      });
    projectedUserBytes += item.compressedSizeBytes;
    results.push({
      agent: item.agent,
      agentSessionId: item.agentSessionId,
      relPath: item.relPath,
      status: "upload",
      objectKey,
      putUrl: await presignPut(objectKey, item.compressedSizeBytes),
    });
  }
  setSpanAttributes(span, {
    "cmux.vault.result_count": results.length,
    "cmux.vault.result.upload_count": countResultStatus(results, "upload"),
    "cmux.vault.result.unchanged_count": countResultStatus(results, "unchanged"),
    "cmux.vault.result.error_count": countResultStatus(results, "error"),
  });
  return jsonResponse({ items: results });
}

/**
 * Opportunistically clean up expired grants: delete the storage object when it
 * was uploaded but never committed, then drop the grant row. Runs a small
 * bounded batch per request (same pattern as the CLI auth start GC). If the
 * object deletion fails, the row is kept so a later pass retries.
 */
async function gcExpiredGrants(db: ReturnType<typeof cloudDb>, now: Date): Promise<void> {
  const expired = await db
    .select({
      id: vaultUploadGrants.id,
      objectKey: vaultUploadGrants.objectKey,
    })
    .from(vaultUploadGrants)
    .where(lt(vaultUploadGrants.expiresAt, now))
    .limit(GRANT_GC_BATCH);
  if (expired.length === 0) return;

  const committedRows = await db
    .select({ objectKey: vaultSnapshots.objectKey })
    .from(vaultSnapshots)
    .where(
      inArray(
        vaultSnapshots.objectKey,
        expired.map((grant) => grant.objectKey),
      ),
    );
  const committedKeys = new Set(committedRows.map((row) => row.objectKey));

  for (const grant of expired) {
    if (!committedKeys.has(grant.objectKey)) {
      try {
        await deleteObject(grant.objectKey);
      } catch (error) {
        continue;
      }
    }
    await db.delete(vaultUploadGrants).where(eq(vaultUploadGrants.id, grant.id));
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
