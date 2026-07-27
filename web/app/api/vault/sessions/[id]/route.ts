import { desc, eq, and } from "drizzle-orm";
import { cloudDb } from "../../../../../db/client";
import { vaultSessions, vaultSnapshots } from "../../../../../db/schema";
import { logVaultStorageError } from "../../../../../services/vault/logging";
import { withAuthedVaultApiRoute } from "../../../../../services/vault/routeHelpers";
import { presignGet } from "../../../../../services/vault/storage";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function GET(
  request: Request,
  context: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVaultApiRoute(
    request,
    "/api/vault/sessions/[id]",
    { "cmux.vault.operation": "sessions.detail" },
    "/api/vault/sessions/[id] GET failed",
    {},
    async ({ user, span }) => {
      const { id } = await context.params;
      if (!UUID_RE.test(id)) return jsonResponse({ error: "not_found" }, 404);

      const db = cloudDb();
      const [session] = await db
        .select()
        .from(vaultSessions)
        .where(and(eq(vaultSessions.userId, user.id), eq(vaultSessions.id, id)))
        .limit(1);
      if (!session) {
        setSpanAttributes(span, { "cmux.vault.session_found": false });
        return jsonResponse({ error: "not_found" }, 404);
      }
      setSpanAttributes(span, {
        "cmux.vault.session_found": true,
        "cmux.vault.agent": session.agent,
      });

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
        logVaultStorageError("session_download_presign", session.latestObjectKey, error);
      }
      setSpanAttributes(span, {
        "cmux.vault.snapshot_count": snapshots.length,
        "cmux.vault.download_url_present": Boolean(downloadUrl),
      });

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
    },
  );
}
