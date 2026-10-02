import { and, eq } from "drizzle-orm";
import { cloudDb } from "@/db/client";
import { vaultSessions } from "@/db/schema";
import { logVaultStorageError } from "@/services/vault/logging";
import { withAuthedVaultApiRoute } from "@/services/vault/routeHelpers";
import { presignGet } from "@/services/vault/storage";
import { fetchTranscriptHeadBatch } from "@/services/vault/transcript-head";
import { setSpanAttributes } from "@/services/telemetry";
import { jsonResponse } from "@/services/vms/routeHelpers";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/**
 * The first bounded batch of transcript messages, parsed server-side so the
 * session page paints messages before the browser streams `/content`.
 * `complete` is true when the batch is the whole transcript.
 */
export async function GET(
  request: Request,
  context: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVaultApiRoute(
    request,
    "/api/vault/sessions/[id]/head",
    { "cmux.vault.operation": "sessions.head" },
    "/api/vault/sessions/[id]/head GET failed",
    {},
    async ({ user, span }) => {
      const { id } = await context.params;
      if (!UUID_RE.test(id)) return jsonResponse({ error: "not_found" }, 404);

      const [session] = await cloudDb()
        .select({ latestObjectKey: vaultSessions.latestObjectKey })
        .from(vaultSessions)
        .where(and(eq(vaultSessions.id, id), eq(vaultSessions.userId, user.id)))
        .limit(1);
      if (!session) {
        setSpanAttributes(span, { "cmux.vault.session_found": false });
        return jsonResponse({ error: "not_found" }, 404);
      }
      setSpanAttributes(span, { "cmux.vault.session_found": true });

      let head: Awaited<ReturnType<typeof fetchTranscriptHeadBatch>>;
      try {
        head = await fetchTranscriptHeadBatch(await presignGet(session.latestObjectKey), {
          objectKey: session.latestObjectKey,
        });
      } catch (error) {
        logVaultStorageError("transcript_head", session.latestObjectKey, error);
        return jsonResponse({ error: "content_unavailable" }, 502);
      }
      setSpanAttributes(span, {
        "cmux.vault.head_message_count": head.messages.length,
        "cmux.vault.head_complete": head.complete,
      });
      return jsonResponse(
        { messages: head.messages, complete: head.complete },
        200,
        { "cache-control": "private, no-store" },
      );
    },
  );
}
