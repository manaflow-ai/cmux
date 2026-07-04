import { and, eq } from "drizzle-orm";
import { cloudDb } from "../../../../../db/client";
import { vaultSessions, vaultSnapshots } from "../../../../../db/schema";
import { vaultConfig, isVaultConfigured } from "../../../../../services/vault/config";
import { buildObjectKey, headObject } from "../../../../../services/vault/storage";
import { readVaultJsonObject, validateVaultBatch } from "../../../../../services/vault/validation";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../../services/vms/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  if (!isVaultConfigured()) return jsonResponse({ error: "vault_not_configured" }, 503);
  const user = await verifyRequest(request, { allowCookie: false });
  if (!user) return unauthorized();

  const body = await readVaultJsonObject(request);
  if (!body.ok) {
    return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  }
  const batch = validateVaultBatch(body.value);
  if (!batch.ok) return jsonResponse({ error: batch.error }, 400);

  const config = vaultConfig();
  if (batch.value.some((item) => item.compressedSizeBytes > config.maxUploadBytes)) {
    return jsonResponse({ error: "upload_too_large" }, 400);
  }

  const db = cloudDb();
  const results = [];
  for (const item of batch.value) {
    const objectKey = buildObjectKey(user.id, item.agent, item.agentSessionId, item.sha256);
    const object = await headObject(objectKey);
    if (!object) {
      results.push(itemResult(item, "error", "object_missing"));
      continue;
    }
    if (object.contentLength !== item.compressedSizeBytes) {
      results.push(itemResult(item, "error", "size_mismatch"));
      continue;
    }

    const now = new Date();
    const committed = await db.transaction(async (tx) => {
      const [session] = await tx
        .insert(vaultSessions)
        .values({
          userId: user.id,
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

      await tx
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

      return session;
    });

    results.push({
      agent: item.agent,
      agentSessionId: item.agentSessionId,
      relPath: item.relPath,
      status: "committed",
      sessionId: committed.id,
    });
  }
  return jsonResponse({ items: results });
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
