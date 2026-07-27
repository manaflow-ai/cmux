import { and, eq } from "drizzle-orm";
import { cloudDb } from "@/db/client";
import { vaultSessions } from "@/db/schema";
import { logVaultStorageError } from "@/services/vault/logging";
import { withAuthedVaultApiRoute } from "@/services/vault/routeHelpers";
import { presignGet } from "@/services/vault/storage";
import { setSpanAttributes } from "@/services/telemetry";
import { jsonResponse } from "@/services/vms/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function GET(
  request: Request,
  context: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVaultApiRoute(
    request,
    "/api/vault/sessions/[id]/content",
    { "cmux.vault.operation": "sessions.content" },
    "/api/vault/sessions/[id]/content GET failed",
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

      let downloadUrl: string;
      try {
        downloadUrl = await presignGet(session.latestObjectKey);
      } catch (error) {
        logVaultStorageError("content_presign_get", session.latestObjectKey, error);
        return jsonResponse({ error: "content_unavailable" }, 502);
      }

      let upstream: Response;
      try {
        upstream = await fetch(downloadUrl, {
          cache: "no-store",
        });
      } catch (error) {
        logVaultStorageError("content_upstream_fetch", session.latestObjectKey, error);
        return jsonResponse({ error: "content_unavailable" }, 502);
      }
      if (!upstream.ok || !upstream.body) {
        logVaultStorageError(
          "content_upstream_fetch",
          session.latestObjectKey,
          new Error(`content upstream fetch failed with HTTP ${upstream.status}`),
        );
        return jsonResponse({ error: "content_unavailable" }, 502);
      }
      setSpanAttributes(span, {
        "cmux.vault.content_length": contentLength(upstream.headers.get("content-length")),
      });

      return new Response(upstream.body, {
        headers: {
          "cache-control": "no-store",
          "content-type": "application/zstd",
          "x-content-type-options": "nosniff",
        },
      });
    },
  );
}

function contentLength(value: string | null): number | undefined {
  if (!value || !/^\d+$/.test(value)) return undefined;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) ? parsed : undefined;
}
