import { and, eq, gt } from "drizzle-orm";
import { cloudDb } from "../../../../../../db/client";
import { vaultCliAuthRequests } from "../../../../../../db/schema";
import { getStackServerApp } from "../../../../../lib/stack";
import { readVaultJsonObject } from "../../../../../../services/vault/validation";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../../../services/vms/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const SESSION_EXPIRES_IN_MS = 90 * 24 * 60 * 60 * 1000;

type StackSessionLike = {
  getTokens: () => Promise<{ accessToken?: string | null; refreshToken?: string | null }>;
};

type StackUserWithSession = {
  id: string;
  createSession: (options: { expiresInMillis: number }) => Promise<StackSessionLike>;
};

export async function POST(request: Request): Promise<Response> {
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
    .limit(1);
  if (!pending) {
    return jsonResponse({ error: "auth_request_not_pending" }, 409);
  }

  const stackUser = await getStackServerApp().getUser({
    tokenStore: request as unknown as { headers: { get(name: string): string | null } },
  }) as StackUserWithSession | null;
  if (!stackUser || stackUser.id !== verified.id) return unauthorized();

  const session = await stackUser.createSession({ expiresInMillis: SESSION_EXPIRES_IN_MS });
  const tokens = await session.getTokens();
  if (!tokens.accessToken || !tokens.refreshToken) {
    return jsonResponse({ error: "token_mint_failed" }, 500);
  }
  const accessToken = tokens.accessToken;
  const refreshToken = tokens.refreshToken;

  const [updated] = await db
    .update(vaultCliAuthRequests)
    .set({
      status: "approved",
      userId: verified.id,
      tokens: {
        accessToken,
        refreshToken,
      },
    })
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
