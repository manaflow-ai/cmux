import { desc, eq, and } from "drizzle-orm";
import { cloudDb } from "../../../../../db/client";
import { vaultSessions, vaultSnapshots } from "../../../../../db/schema";
import { isVaultConfigured } from "../../../../../services/vault/config";
import { presignGet } from "../../../../../services/vault/storage";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../../services/vms/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function GET(
  request: Request,
  context: { params: Promise<{ id: string }> },
): Promise<Response> {
  if (!isVaultConfigured()) return jsonResponse({ error: "vault_not_configured" }, 503);
  const user = await verifyRequest(request);
  if (!user) return unauthorized();

  const { id } = await context.params;
  if (!UUID_RE.test(id)) return jsonResponse({ error: "not_found" }, 404);

  const db = cloudDb();
  const [session] = await db
    .select()
    .from(vaultSessions)
    .where(and(eq(vaultSessions.userId, user.id), eq(vaultSessions.id, id)))
    .limit(1);
  if (!session) return jsonResponse({ error: "not_found" }, 404);

  const snapshots = await db
    .select({
      sha256: vaultSnapshots.sha256,
      objectKey: vaultSnapshots.objectKey,
      sizeBytes: vaultSnapshots.sizeBytes,
      compressedSizeBytes: vaultSnapshots.compressedSizeBytes,
      uploadedAt: vaultSnapshots.uploadedAt,
    })
    .from(vaultSnapshots)
    .where(eq(vaultSnapshots.sessionId, session.id))
    .orderBy(desc(vaultSnapshots.uploadedAt));

  // A transient presign failure should degrade to metadata-without-URL, not a
  // 500; the CLI reports a missing download URL with a clear error.
  let downloadUrl: string | null = null;
  try {
    downloadUrl = await presignGet(session.latestObjectKey);
  } catch (error) {
    console.error("vault: presignGet failed for session", session.id, error);
  }

  return jsonResponse({
    id: session.id,
    agent: session.agent,
    agentSessionId: session.agentSessionId,
    relPath: session.relPath,
    cwd: session.cwd,
    latestSha256: session.latestSha256,
    sizeBytes: session.sizeBytes,
    compressedSizeBytes: session.compressedSizeBytes,
    lastUploadedAt: session.lastUploadedAt.toISOString(),
    downloadUrl,
    snapshots: snapshots.map((snapshot) => ({
      ...snapshot,
      uploadedAt: snapshot.uploadedAt.toISOString(),
    })),
  });
}
