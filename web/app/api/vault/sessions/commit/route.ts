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
  const initialResults = await withVaultUserQuotaLock(db, userId, async (lockedDb) => {
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
        lockedResults.push(committedResult(item, existingCommit.sessionId));
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

      if (grant.uploadObjectKey !== objectKey) {
        lockedResults.push({
          status: "pending_staged_commit" as const,
          item,
          objectKey,
          grantId: grant.id,
          uploadObjectKey: grant.uploadObjectKey,
        });
        projectedUserBytes += item.compressedSizeBytes;
        continue;
      }

      const sessionId = await commitVaultSnapshotRows(lockedDb, userId, item, objectKey, now);
      await lockedDb.delete(vaultUploadGrants).where(eq(vaultUploadGrants.id, grant.id));
      projectedUserBytes += item.compressedSizeBytes;
      lockedResults.push(committedResult(item, sessionId));
    }
    return lockedResults;
  });

  const results = [];
  for (const result of initialResults) {
    if (!isPendingStagedCommit(result)) {
      results.push(result);
      continue;
    }
    await copyObject(result.uploadObjectKey, result.objectKey);
    let finalized;
    try {
      finalized = await finalizeStagedCommit(db, userId, result, config.maxUserBytes);
    } catch (error) {
      await deleteObject(result.objectKey).catch(() => undefined);
      throw error;
    }
    if (finalized.status !== "committed") {
      await deleteObject(result.objectKey).catch(() => undefined);
      results.push(finalized);
      continue;
    }
    stagingCleanups.push({
      grantId: result.grantId,
      objectKey: result.objectKey,
      uploadObjectKey: result.uploadObjectKey,
    });
    results.push(finalized);
  }
  await cleanupCommittedStagingGrants(db, stagingCleanups);
  setSpanAttributes(span, {
    "cmux.vault.result_count": results.length,
    "cmux.vault.result.committed_count": countResultStatus(results, "committed"),
    "cmux.vault.result.error_count": countResultStatus(results, "error"),
  });
  return jsonResponse({ items: results });
}

type VaultCommitItem = {
  readonly agent: string;
  readonly agentSessionId: string;
  readonly relPath: string;
  readonly cwd: string | null;
  readonly sha256: string;
  readonly sizeBytes: number;
  readonly compressedSizeBytes: number;
};

type PendingStagedCommit = {
  readonly status: "pending_staged_commit";
  readonly item: VaultCommitItem;
  readonly objectKey: string;
  readonly grantId: string;
  readonly uploadObjectKey: string;
};

function isPendingStagedCommit(result: unknown): result is PendingStagedCommit {
  return typeof result === "object" &&
    result !== null &&
    "status" in result &&
    result.status === "pending_staged_commit";
}

async function finalizeStagedCommit(
  db: ReturnType<typeof cloudDb>,
  userId: string,
  pending: PendingStagedCommit,
  maxUserBytes: number,
) {
  return await withVaultUserQuotaLock(db, userId, async (lockedDb) => {
    const existingCommit = await findCommittedSnapshot(
      lockedDb,
      userId,
      pending.item,
      pending.objectKey,
    );
    if (existingCommit) return committedResult(pending.item, existingCommit.sessionId);

    const now = new Date();
    const [grant] = await lockedDb
      .select({
        id: vaultUploadGrants.id,
        compressedSizeBytes: vaultUploadGrants.compressedSizeBytes,
      })
      .from(vaultUploadGrants)
      .where(and(
        eq(vaultUploadGrants.id, pending.grantId),
        eq(vaultUploadGrants.userId, userId),
        eq(vaultUploadGrants.objectKey, pending.objectKey),
        eq(vaultUploadGrants.uploadObjectKey, pending.uploadObjectKey),
        gt(vaultUploadGrants.expiresAt, now),
      ))
      .limit(1);
    if (!grant) return itemResult(pending.item, "error", "upload_grant_missing");
    if (grant.compressedSizeBytes !== pending.item.compressedSizeBytes) {
      return itemResult(pending.item, "error", "upload_grant_mismatch");
    }

    const storedBytes = await getVaultStoredCompressedBytes(lockedDb, userId);
    if (storedBytes + pending.item.compressedSizeBytes > maxUserBytes) {
      return itemResult(pending.item, "error", "quota_exceeded");
    }

    const sessionId = await commitVaultSnapshotRows(
      lockedDb,
      userId,
      pending.item,
      pending.objectKey,
      now,
    );
    return committedResult(pending.item, sessionId);
  });
}

async function commitVaultSnapshotRows(
  db: ReturnType<typeof cloudDb>,
  userId: string,
  item: VaultCommitItem,
  objectKey: string,
  now: Date,
): Promise<string> {
  const [session] = await db
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

  await db
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

  return session.id;
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

function committedResult(
  item: { agent: string; agentSessionId: string; relPath: string },
  sessionId: string,
) {
  return {
    agent: item.agent,
    agentSessionId: item.agentSessionId,
    relPath: item.relPath,
    status: "committed",
    sessionId,
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
