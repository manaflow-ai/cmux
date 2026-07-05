import { and, eq } from "drizzle-orm";
import { cloudDb } from "../../../../db/client";
import { vaultSessions } from "../../../../db/schema";
import { vaultConfig, isVaultConfigured } from "../../../../services/vault/config";
import { buildObjectKey, presignPut } from "../../../../services/vault/storage";
import { getVaultStoredCompressedBytes } from "../../../../services/vault/usage";
import { readVaultJsonObject, validateVaultBatch } from "../../../../services/vault/validation";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../services/vms/auth";

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
  const db = cloudDb();
  // Per-user storage quota: track the projected total across this batch so a
  // single request cannot mint presigned URLs past the cap. The commit route
  // re-checks, so previously issued URLs cannot bypass the quota either.
  let projectedUserBytes = await getVaultStoredCompressedBytes(db, user.id);
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
          eq(vaultSessions.userId, user.id),
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

    const objectKey = buildObjectKey(user.id, item.agent, item.agentSessionId, item.sha256);
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
  return jsonResponse({ items: results });
}
