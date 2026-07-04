import { and, eq, gt } from "drizzle-orm";
import { cloudDb } from "../../../../../../db/client";
import { vaultCliAuthRequests } from "../../../../../../db/schema";
import { isVaultConfigured } from "../../../../../../services/vault/config";
import { readVaultJsonObject } from "../../../../../../services/vault/validation";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../../../services/vms/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// Approval only records WHO approved. Tokens are minted later, by the poll
// route at claim time, so no credential is ever stored in the database and a
// duplicate approve cannot mint an orphaned Stack session.
export async function POST(request: Request): Promise<Response> {
  if (!isVaultConfigured()) return jsonResponse({ error: "vault_not_configured" }, 503);
  const verified = await verifyRequest(request);
  if (!verified) return unauthorized();

  const body = await readVaultJsonObject(request);
  if (!body.ok) {
    return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  }
  const userCode = typeof body.value.userCode === "string" ? body.value.userCode.trim().toUpperCase() : "";
  if (!/^[A-Z2-9]{8}$/.test(userCode)) {
    return jsonResponse({ error: "invalid_user_code" }, 400);
  }

  const db = cloudDb();
  const now = new Date();
  // Target exactly one request: user codes are random but not unique, so an
  // unfiltered UPDATE could approve several outstanding device flows at once.
  const [pending] = await db
    .select({ id: vaultCliAuthRequests.id })
    .from(vaultCliAuthRequests)
    .where(
      and(
        eq(vaultCliAuthRequests.userCode, userCode),
        eq(vaultCliAuthRequests.status, "pending"),
        gt(vaultCliAuthRequests.expiresAt, now),
      ),
    )
    .orderBy(vaultCliAuthRequests.createdAt)
    .limit(1);
  if (!pending) {
    return jsonResponse({ error: "auth_request_not_pending" }, 409);
  }

  const [updated] = await db
    .update(vaultCliAuthRequests)
    .set({ status: "approved", userId: verified.id })
    .where(
      and(
        eq(vaultCliAuthRequests.id, pending.id),
        eq(vaultCliAuthRequests.status, "pending"),
        gt(vaultCliAuthRequests.expiresAt, now),
      ),
    )
    .returning({ id: vaultCliAuthRequests.id });

  if (!updated) {
    return jsonResponse({ error: "auth_request_not_pending" }, 409);
  }
  return jsonResponse({ ok: true });
}
