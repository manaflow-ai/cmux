// Send a push to the authenticated user's registered iOS devices. Called by the
// macOS app when it shows a terminal notification AND the user enabled phone
// forwarding. No-ops (no APNs traffic) when the user has no registered devices.
// Auth: Stack Bearer from the Mac's signed-in user; routing is by that user id.

import { checkRateLimit } from "@vercel/firewall";
import { and, eq, inArray } from "drizzle-orm";
import { env } from "../../../env";
import { cloudDb } from "../../../../db/client";
import { deviceTokens } from "../../../../db/schema";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../services/vms/auth";
import { recordPushSendInTransactionOrThrow, PushRateLimitExceededError } from "../../../../services/apns/rateLimit";
import { withApnsApiRoute } from "../../../../services/apns/routeHandler";
import { AccountDeletionMutationBlockedError, withAccountDeletionUserMutationLock } from "../../../../services/account/deletion";
import {
  MAX_DEVICE_TOKENS_PER_USER,
  MAX_PUSH_REQUEST_BYTES,
  parsePushPayload,
  readBoundedJsonObject,
} from "../../../../services/apns/routePolicy";
import { sendApnsNotification, type ApnsConfig } from "../../../../services/apns/sender";
import { summarizeApnsSendResults } from "../../../../services/apns/response";

export const runtime = "nodejs"; // http2 + node:crypto, not edge
export const dynamic = "force-dynamic";

function apnsConfig(): ApnsConfig | null {
  const keyP8 = env.CMUX_APNS_KEY_P8;
  const keyId = env.CMUX_APNS_KEY_ID;
  const teamId = env.CMUX_APNS_TEAM_ID;
  if (!keyP8 || !keyId || !teamId) return null;
  return { keyP8, keyId, teamId };
}

function rateLimitResponse(error: PushRateLimitExceededError): Response {
  return new Response(
    JSON.stringify({ error: "rate_limited", retryAfterSeconds: error.retryAfterSeconds }),
    {
      status: 429,
      headers: {
        "content-type": "application/json",
        "retry-after": String(error.retryAfterSeconds),
      },
    },
  );
}

export async function POST(request: Request): Promise<Response> {
  return withApnsApiRoute(request, "/api/notifications/push", "send", async () => sendPush(request));
}

async function sendPush(request: Request): Promise<Response> {
  const user = await verifyRequest(request, { allowCookie: false });
  if (!user) return unauthorized();

  if (process.env.VERCEL === "1" && env.CMUX_PUSH_RATE_LIMIT_ID) {
    const { error, rateLimited } = await checkRateLimit(env.CMUX_PUSH_RATE_LIMIT_ID, {
      request,
      rateLimitKey: user.id,
    });
    if (rateLimited || error === "blocked") {
      return new Response(JSON.stringify({ error: "rate_limited" }), {
        status: 429,
        headers: { "content-type": "application/json" },
      });
    }
    if (error === "not-found") {
      console.error("notifications.push.rate_limit_not_found", env.CMUX_PUSH_RATE_LIMIT_ID);
    }
  }

  const body = await readBoundedJsonObject(request, MAX_PUSH_REQUEST_BYTES);
  if (!body.ok) {
    return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  }

  const payload = parsePushPayload(body.value);
  if (!payload.ok) return jsonResponse({ error: payload.error }, 400);

  const db = cloudDb();

  try {
    const result = await withAccountDeletionUserMutationLock(db, user.id, async (tx) => {
      const tokens = await tx
        .select({
          deviceToken: deviceTokens.deviceToken,
          bundleId: deviceTokens.bundleId,
          environment: deviceTokens.environment,
        })
        .from(deviceTokens)
        .where(and(eq(deviceTokens.userId, user.id), eq(deviceTokens.platform, "ios")))
        .limit(MAX_DEVICE_TOKENS_PER_USER);

      if (tokens.length === 0) {
        return { kind: "sent" as const, results: [] };
      }

      const config = apnsConfig();
      if (!config) {
        return { kind: "unconfigured" as const };
      }

      return { kind: "ready" as const, config, tokens };
    });

    if (result.kind === "unconfigured") {
      return jsonResponse({ error: "push_service_not_configured" }, 503);
    }
    if (result.kind === "ready") {
      await withAccountDeletionUserMutationLock(db, user.id, async (tx) => {
        await recordPushSendInTransactionOrThrow(tx, user.id, result.tokens.length);
      });
      const results = await sendApnsNotification(result.config, result.tokens, payload.value);
      await pruneDeadDeviceTokens(db, user.id, results.filter((r) => r.prune).map((r) => r.deviceToken));
      return jsonResponse(summarizeApnsSendResults(results));
    }
    return jsonResponse(summarizeApnsSendResults(result.results));
  } catch (error) {
    if (error instanceof PushRateLimitExceededError) {
      return rateLimitResponse(error);
    }
    if (error instanceof AccountDeletionMutationBlockedError) {
      return jsonResponse({ error: "account_deletion_in_progress" }, 409);
    }
    throw error;
  }
}

async function pruneDeadDeviceTokens(
  db: ReturnType<typeof cloudDb>,
  userId: string,
  deadTokens: readonly string[],
): Promise<void> {
  if (deadTokens.length === 0) return;
  try {
    await withAccountDeletionUserMutationLock(db, userId, async (tx) => {
      await tx
        .delete(deviceTokens)
        .where(and(eq(deviceTokens.userId, userId), eq(deviceTokens.platform, "ios"), inArray(deviceTokens.deviceToken, deadTokens)));
    });
  } catch (error) {
    if (error instanceof AccountDeletionMutationBlockedError) return;
    throw error;
  }
}
