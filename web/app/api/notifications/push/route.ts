// Send a push to the authenticated user's registered iOS devices. Called by the
// macOS app when it shows a terminal notification AND the user enabled phone
// forwarding. No-ops (no APNs traffic) when the user has no registered devices.
// Auth: Stack Bearer from the Mac's signed-in user; routing is by that user id.

import crypto from "node:crypto";
import { and, eq, inArray } from "drizzle-orm";
import { env } from "../../../env";
import { cloudDb } from "../../../../db/client";
import { deviceTokens } from "../../../../db/schema";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../services/vms/auth";
import {
  completePushSend,
  recordPushSendOrThrow,
  PushCorrelationConflictError,
  PushRateLimitExceededError,
} from "../../../../services/apns/rateLimit";
import {
  mergePushDeliveryOutcomes,
  unresolvedPushTargets,
} from "../../../../services/apns/deliveryState";
import {
  recordApnsRouteOutcome,
  withApnsApiRoute,
} from "../../../../services/apns/routeHandler";
import {
  MAX_DEVICE_TOKENS_PER_USER,
  MAX_PUSH_REQUEST_BYTES,
  parsePushPayload,
  readBoundedJsonObject,
  type PushPayload,
} from "../../../../services/apns/routePolicy";
import {
  sendApnsNotificationReliably,
  type ApnsConfig,
  type ApnsSendResult,
  type ApnsTarget,
} from "../../../../services/apns/sender";
import {
  summarizeApnsSendResults,
  type PushSendSummary,
} from "../../../../services/apns/response";

export const runtime = "nodejs"; // http2 + node:crypto, not edge
export const dynamic = "force-dynamic";
// The default APNs loop is bounded to ~28s. Keep the platform request alive
// through that loop while staying comfortably below the 120s event TTL.
export const maxDuration = 45;

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

export const DEFAULT_PUSH_TTL_SECONDS = 120;
const MAX_PUSH_TTL_SECONDS = 300;

function pushPayloadFingerprint(payload: PushPayload): string {
  const canonicalPayload = {
    kind: payload.kind,
    title: payload.title,
    subtitle: payload.subtitle,
    body: payload.body,
    workspaceId: payload.workspaceId,
    surfaceId: payload.surfaceId,
    retargetsToLiveSurfaceOwner: payload.retargetsToLiveSurfaceOwner,
    macDeviceId: payload.macDeviceId,
    notificationId: payload.notificationId,
    expirationEpochSeconds: payload.expirationEpochSeconds,
    dismissedIds: payload.dismissedIds,
    badgeCount: payload.badgeCount,
    hideContent: payload.hideContent,
  };
  return crypto
    .createHash("sha256")
    .update(JSON.stringify(canonicalPayload))
    .digest("hex");
}

function summaryResponse(
  summary: PushSendSummary,
  correlationId: string,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(
    JSON.stringify({ ...summary, correlationId }),
    {
      status: 200,
      headers: {
        "content-type": "application/json",
        "x-cmux-push-correlation-id": correlationId,
        ...extraHeaders,
      },
    },
  );
}

export async function POST(request: Request): Promise<Response> {
  return withApnsApiRoute(
    request,
    "/api/notifications/push",
    "send",
    async () => sendPush(request, { send: sendApnsNotificationReliably }),
  );
}

/** Test seam for the APNs transport; production always uses the real sender. */
export async function sendPushWithTransport(
  request: Request,
  send: typeof sendApnsNotificationReliably,
): Promise<Response> {
  return sendPush(request, { send });
}

async function sendPush(
  request: Request,
  dependencies: { send: typeof sendApnsNotificationReliably },
): Promise<Response> {
  const user = await verifyRequest(request, { allowCookie: false });
  if (!user) return unauthorized();

  const body = await readBoundedJsonObject(request, MAX_PUSH_REQUEST_BYTES);
  if (!body.ok) {
    return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  }

  const payload = parsePushPayload(body.value);
  if (!payload.ok) return jsonResponse({ error: payload.error }, 400);
  const correlationId =
    payload.value.correlationId ?? crypto.randomUUID();
  const payloadFingerprint = pushPayloadFingerprint(payload.value);
  const nowEpochSeconds = Math.floor(Date.now() / 1000);
  if (
    payload.value.expirationEpochSeconds != null
    && payload.value.expirationEpochSeconds <= nowEpochSeconds
  ) {
    return jsonResponse(
      { error: "push_event_expired", correlationId },
      410,
    );
  }
  const expirationEpochSeconds = Math.min(
    payload.value.expirationEpochSeconds
      ?? nowEpochSeconds + DEFAULT_PUSH_TTL_SECONDS,
    nowEpochSeconds + MAX_PUSH_TTL_SECONDS,
  );
  const deliveryPayload = {
    ...payload.value,
    correlationId,
    expirationEpochSeconds,
  };

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

  let priorOutcomes: ApnsSendResult[] = [];
  let sendTargets: ApnsTarget[] = tokens;
  try {
    const claim = await recordPushSendOrThrow(
      db,
      user.id,
      tokens.length,
      correlationId,
      new Date(nowEpochSeconds * 1000),
      new Date(expirationEpochSeconds * 1000),
      deliveryPayload.kind,
      tokens,
      payloadFingerprint,
    );
    if (claim.kind === "busy") {
      return new Response(
        JSON.stringify({ error: "push_event_in_progress", correlationId }),
        {
          status: 409,
          headers: {
            "content-type": "application/json",
            "retry-after": "1",
            "x-cmux-push-correlation-id": correlationId,
          },
        },
      );
    }
    const existing = claim.previous;
    if (existing?.summary) {
      const isExpired =
        existing.expiresAt != null && existing.expiresAt.getTime() <= Date.now();
      if (existing.summary.transientFailures === 0 || isExpired) {
        await completePushSend(
          db,
          user.id,
          correlationId,
          existing.summary,
          existing.outcomes,
        );
        recordApnsRouteOutcome(existing.summary, correlationId);
        return summaryResponse(existing.summary, correlationId, {
          "x-cmux-push-replayed": "true",
        });
      }
      priorOutcomes = [...existing.outcomes];
      const currentByToken = new Map(
        tokens.map((target) => [target.deviceToken, target]),
      );
      const originalTargets =
        existing.initialTargets.length > 0
          ? existing.initialTargets
          : tokens;
      const unresolvedOriginalTargets = unresolvedPushTargets(
        originalTargets,
        priorOutcomes,
      );
      const removedOutcomes = unresolvedOriginalTargets
        .filter((target) => !currentByToken.has(target.deviceToken))
        .map((target): ApnsSendResult => ({
          deviceToken: target.deviceToken,
          status: 404,
          reason: "target_no_longer_registered",
          prune: false,
        }));
      priorOutcomes = mergePushDeliveryOutcomes(
        priorOutcomes,
        removedOutcomes,
      );
      const stillRegisteredOriginalTargets = originalTargets.flatMap(
        (target) => {
          const current = currentByToken.get(target.deviceToken);
          return current ? [current] : [];
        },
      );
      sendTargets = unresolvedPushTargets(
        stillRegisteredOriginalTargets,
        priorOutcomes,
      );
      if (sendTargets.length === 0) {
        const reconciledSummary = summarizeApnsSendResults(priorOutcomes);
        await completePushSend(
          db,
          user.id,
          correlationId,
          reconciledSummary,
          priorOutcomes,
        );
        recordApnsRouteOutcome(reconciledSummary, correlationId);
        return summaryResponse(reconciledSummary, correlationId, {
          "x-cmux-push-replayed": "true",
        });
      }
    }
  } catch (error) {
    if (error instanceof PushCorrelationConflictError) {
      return jsonResponse(
        { error: "correlation_payload_mismatch", correlationId },
        409,
      );
    }
    if (error instanceof PushRateLimitExceededError) {
      return rateLimitResponse(error);
    }
    throw error;
  }

  if (sendTargets.length === 0) {
    const summary = summarizeApnsSendResults(priorOutcomes);
    await completePushSend(db, user.id, correlationId, summary, priorOutcomes);
    recordApnsRouteOutcome(summary, correlationId);
    return summaryResponse(summary, correlationId);
  }

  const config = apnsConfig();
  if (!config) {
    return jsonResponse({ error: "push_service_not_configured" }, 503);
  }

  const results = await dependencies.send(
    config,
    sendTargets,
    deliveryPayload,
  );

  const dead = results.filter((r) => r.prune).map((r) => r.deviceToken);
  if (dead.length > 0) {
    await db
      .delete(deviceTokens)
      .where(and(eq(deviceTokens.userId, user.id), eq(deviceTokens.platform, "ios"), inArray(deviceTokens.deviceToken, dead)));
  }

  const outcomes = mergePushDeliveryOutcomes(priorOutcomes, results);
  const summary = summarizeApnsSendResults(outcomes);
  await completePushSend(db, user.id, correlationId, summary, outcomes);
  recordApnsRouteOutcome(summary, correlationId);
  return summaryResponse(summary, correlationId);
}
