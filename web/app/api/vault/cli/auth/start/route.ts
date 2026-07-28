import { createHash, randomBytes, randomInt } from "node:crypto";
import { checkRateLimit } from "@vercel/firewall";
import { and, count, eq, gt, lt } from "drizzle-orm";
import { env } from "@/app/env";
import { cloudDb } from "../../../../../../db/client";
import { vaultCliAuthRequests } from "../../../../../../db/schema";
import { withVaultApiRoute } from "../../../../../../services/vault/routeHelpers";
import { readVaultJsonObject } from "../../../../../../services/vault/validation";
import { setSpanAttributes } from "../../../../../../services/telemetry";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const USER_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const EXPIRES_IN_SECONDS = 15 * 60;
const INTERVAL_SECONDS = 3;
// Backstop ceiling on rows still awaiting approval. Only `pending` rows count,
// so completed logins never consume capacity; the primary abuse control is the
// per-IP firewall rate limit below, and this cap only bounds table growth
// under a distributed flood that the per-IP rule cannot see.
const MAX_PENDING_REQUESTS = 500;

export async function POST(request: Request): Promise<Response> {
  return withVaultApiRoute(
    request,
    "/api/vault/cli/auth/start",
    { "cmux.vault.operation": "cli_auth.start" },
    "/api/vault/cli/auth/start POST failed",
    async ({ span }) => {
      // Per-IP throttle through the platform firewall, same pattern as the other
      // public POST endpoints (waitlist, feedback). Only active on Vercel.
      if (process.env.VERCEL === "1" && env.CMUX_FEEDBACK_RATE_LIMIT_ID) {
        const { error, rateLimited } = await checkRateLimit(env.CMUX_FEEDBACK_RATE_LIMIT_ID, {
          request,
        });
        setSpanAttributes(span, {
          "cmux.vault.rate_limited": rateLimited || error === "blocked",
        });
        if (rateLimited || error === "blocked") {
          return jsonResponse({ error: "throttled" }, 429);
        }
      }

      const body = await readVaultJsonObject(request);
      if (!body.ok) {
        return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
      }

      const deviceCode = randomBytes(32).toString("hex");
      const deviceCodeHash = hashDeviceCode(deviceCode);
      const userCode = randomUserCode();
      const now = new Date();
      const expiresAt = new Date(now.getTime() + EXPIRES_IN_SECONDS * 1000);

      const db = cloudDb();
      // Opportunistic GC so this unauthenticated endpoint cannot accumulate rows
      // beyond one expiry window (see DESIGN.md for the full rate-limit plan).
      await db
        .delete(vaultCliAuthRequests)
        .where(lt(vaultCliAuthRequests.expiresAt, new Date(now.getTime() - 60 * 1000)));

      const [pending] = await db
        .select({ value: count() })
        .from(vaultCliAuthRequests)
        .where(
          and(
            eq(vaultCliAuthRequests.status, "pending"),
            gt(vaultCliAuthRequests.expiresAt, now),
          ),
        );
      const pendingCount = pending?.value ?? 0;
      setSpanAttributes(span, { "cmux.vault.pending_auth_requests": pendingCount });
      if (pendingCount >= MAX_PENDING_REQUESTS) {
        return jsonResponse({ error: "throttled" }, 429);
      }

      await db.insert(vaultCliAuthRequests).values({
        deviceCodeHash,
        userCode,
        status: "pending",
        createdAt: now,
        expiresAt,
      });

      const verification = new URL("/dashboard/vault/cli-auth", request.url);
      verification.searchParams.set("code", userCode);
      setSpanAttributes(span, {
        "cmux.vault.result_count": 1,
        "cmux.vault.cli_auth.expires_in_seconds": EXPIRES_IN_SECONDS,
      });

      return jsonResponse({
        deviceCode,
        userCode,
        verificationUrl: verification.toString(),
        expiresInSeconds: EXPIRES_IN_SECONDS,
        intervalSeconds: INTERVAL_SECONDS,
      });
    },
  );
}

function hashDeviceCode(deviceCode: string): string {
  return createHash("sha256").update(deviceCode).digest("hex");
}

function randomUserCode(): string {
  let code = "";
  for (let i = 0; i < 8; i++) {
    code += USER_CODE_ALPHABET[randomInt(USER_CODE_ALPHABET.length)];
  }
  return code;
}
