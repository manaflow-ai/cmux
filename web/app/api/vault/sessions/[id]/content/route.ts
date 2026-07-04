import { and, eq } from "drizzle-orm";
import { cloudDb } from "@/db/client";
import { vaultSessions } from "@/db/schema";
import { isVaultConfigured } from "@/services/vault/config";
import { presignGet } from "@/services/vault/storage";
import { unauthorized, verifyRequest } from "@/services/vms/auth";
import { jsonResponse } from "@/services/vms/routeHelpers";

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

  const [session] = await cloudDb()
    .select({ latestObjectKey: vaultSessions.latestObjectKey })
    .from(vaultSessions)
    .where(and(eq(vaultSessions.id, id), eq(vaultSessions.userId, user.id)))
    .limit(1);
  if (!session) return jsonResponse({ error: "not_found" }, 404);

  const upstream = await fetch(await presignGet(session.latestObjectKey), {
    cache: "no-store",
  });
  if (!upstream.ok || !upstream.body) {
    return jsonResponse({ error: "content_unavailable" }, 502);
  }

  return new Response(upstream.body, {
    headers: {
      "cache-control": "no-store",
      "content-type": "application/zstd",
      "x-content-type-options": "nosniff",
    },
  });
}
