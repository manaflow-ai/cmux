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
import { recordPushSendOrThrow, PushRateLimitExceededError } from "../../../../services/apns/rateLimit";
import { withApnsApiRoute } from "../../../../services/apns/routeHandler";
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

  const pushRateLimitId =
    env.CMUX_PUSH_RATE_LIMIT_ID?.trim() || process.env.CMUX_PUSH_RATE_LIMIT_ID?.trim();
  if (process.env.VERCEL === "1" && pushRateLimitId) {
    const { error, rateLimited } = await checkRateLimit(pushRateLimitId, {
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
      console.error("notifications.push.rate_limit_not_found", pushRateLimitId);
    }
  }

  const body = await readBoundedJsonObject(request, MAX_PUSH_REQUEST_BYTES);
  if (!body.ok) {
    return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  }

  const payload = parsePushPayload(body.value);
  if (!payload.ok) return jsonResponse({ error: payload.error }, 400);

  const db = cloudDb();
  const tokens = await db
    .select({
      deviceToken: deviceTokens.deviceToken,
      bundleId: deviceTokens.bundleId,
      environment: deviceTokens.environment,
    })
    .from(deviceTokens)
    .where(and(eq(deviceTokens.userId, user.id), eq(deviceTokens.platform, "ios")))
    .limit(MAX_DEVICE_TOKENS_PER_USER);

  if (tokens.length === 0) {
    return jsonResponse(summarizeApnsSendResults([]));
  }

  const config = apnsConfig();
  if (!config) {
    return jsonResponse({ error: "push_service_not_configured" }, 503);
  }

  try {
    await recordPushSendOrThrow(db, user.id, tokens.length);
  } catch (error) {
    if (error instanceof PushRateLimitExceededError) {
      return rateLimitResponse(error);
    }
    throw error;
  }

  const results = await sendApnsNotification(config, tokens, payload.value);

  const dead = results.filter((r) => r.prune).map((r) => r.deviceToken);
  if (dead.length > 0) {
    await db
      .delete(deviceTokens)
      .where(and(eq(deviceTokens.userId, user.id), eq(deviceTokens.platform, "ios"), inArray(deviceTokens.deviceToken, dead)));
  }

  return jsonResponse(summarizeApnsSendResults(results));
}
