// Every Mac sender must name one exact iOS target. Missing targets fail closed.

import { checkRateLimit } from "@vercel/firewall";
import { and, eq, or } from "drizzle-orm";
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
  normalizeApnsBundle,
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

type NotificationDb = ReturnType<typeof cloudDb>;

export function notificationPushTargetLimit(): number {
  return MAX_DEVICE_TOKENS_PER_USER;
}

/** Selects one exact iOS bundle owned by the authenticated account. */
export async function selectNotificationPushTargets(
  db: NotificationDb,
  userId: string,
  bundleId: string,
) {
  return db
    .select({
      deviceToken: deviceTokens.deviceToken,
      bundleId: deviceTokens.bundleId,
      environment: deviceTokens.environment,
    })
    .from(deviceTokens)
    .where(and(
      eq(deviceTokens.userId, userId),
      eq(deviceTokens.platform, "ios"),
      eq(deviceTokens.bundleId, bundleId),
    ))
    .limit(notificationPushTargetLimit());
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
  const requestedNamespace = request.headers.get("x-cmux-ios-target-namespace");
  if (!requestedNamespace) {
    return jsonResponse({ error: "missing_target_namespace" }, 400);
  }
  const targetNamespace = normalizeApnsBundle(requestedNamespace);
  if (!targetNamespace) {
    return jsonResponse({ error: "invalid_target_namespace" }, 400);
  }

  const db = cloudDb();
  const tokens = await selectNotificationPushTargets(
    db,
    user.id,
    targetNamespace.bundleId,
  );

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

  const dead = results.filter((result) =>
    result.prune && result.bundleId);
  if (dead.length > 0) {
    await db
      .delete(deviceTokens)
      .where(and(
        eq(deviceTokens.userId, user.id),
        eq(deviceTokens.platform, "ios"),
        or(...dead.map((result) => and(
          eq(deviceTokens.bundleId, result.bundleId!),
          eq(deviceTokens.deviceToken, result.deviceToken),
        ))),
      ));
  }

  return jsonResponse(summarizeApnsSendResults(results));
}
