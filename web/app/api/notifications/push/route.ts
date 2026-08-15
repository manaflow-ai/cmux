// Every Mac sender must name one exact iOS target. Missing targets fail closed.

import crypto from "node:crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { env } from "../../../env";
import { cloudDb } from "../../../../db/client";
import { resolveApnsProviderConfiguration } from "../../../../services/apns/config";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../services/vms/auth";
import {
  recordApnsRouteFailure,
  recordApnsRouteOutcome,
  withApnsApiRoute,
} from "../../../../services/apns/routeHandler";
import {
  MAX_PUSH_REQUEST_BYTES,
  normalizeApnsBundle,
  parsePushPayload,
  readBoundedJsonObject,
  type PushPayload,
} from "../../../../services/apns/routePolicy";
import {
  sendApnsNotificationReliably,
  type ApnsConfig,
} from "../../../../services/apns/sender";
import type { PushSendSummary } from "../../../../services/apns/response";
import {
  makePushDeliveryService,
  PushDeliveryService,
  type PushDeliveryError,
} from "../../../../services/apns/pushDeliveryService";
import { authProviderErrorResponse } from "../../../../services/vms/authErrors";

// through that loop while staying comfortably below the 120s event TTL.
export const maxDuration = 45;

function apnsConfig(): ApnsConfig | null {
  return resolveApnsProviderConfiguration(
    env.CMUX_APNS_KEY_P8,
    env.CMUX_APNS_KEY_ID,
    env.CMUX_APNS_TEAM_ID,
  );
}

export const DEFAULT_PUSH_TTL_SECONDS = 120;
const MAX_PUSH_TTL_SECONDS = 300;

function pushPayloadFingerprint(
  payload: PushPayload,
  targetBundleId: string,
): string {
  const canonicalPayload = {
    targetBundleId,
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
    async () => sendPush(request, {
      send: sendApnsNotificationReliably,
      config: apnsConfig(),
    }),
  );
}

/** Test seam for the APNs transport; production always uses the real sender. */
export async function sendPushWithTransport(
  request: Request,
  send: typeof sendApnsNotificationReliably,
  config: ApnsConfig | null = apnsConfig(),
): Promise<Response> {
  return sendPush(request, { send, config });
}

async function sendPush(
  request: Request,
  dependencies: {
    send: typeof sendApnsNotificationReliably;
    config: ApnsConfig | null;
  },
): Promise<Response> {
  let user: Awaited<ReturnType<typeof verifyRequest>>;
  try {
    user = await verifyRequest(request, { allowCookie: false });
  } catch (error) {
    return authProviderErrorResponse(error, "notifications.push.auth");
  }
  if (!user) return unauthorized();

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
  const correlationId =
    payload.value.correlationId ?? crypto.randomUUID();
  const payloadFingerprint = pushPayloadFingerprint(
    payload.value,
    targetNamespace.bundleId,
  );
  const startedAt = new Date();
  const nowEpochSeconds = Math.floor(startedAt.getTime() / 1_000);
  if (
    payload.value.expirationEpochSeconds != null
    && payload.value.expirationEpochSeconds <= nowEpochSeconds
  ) {
    recordApnsRouteFailure(correlationId, "event_expired");
    return correlatedErrorResponse(
      { error: "push_event_expired", correlationId },
      410,
      correlationId,
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
  try {
    const service = makePushDeliveryService({
      db: cloudDb(),
      config: dependencies.config,
      send: dependencies.send,
      recordOutcome: recordApnsRouteOutcome,
    });
    const program = Effect.gen(function* () {
      const delivery = yield* PushDeliveryService;
      return yield* delivery.deliver({
        userId: user.id,
        targetBundleId: targetNamespace.bundleId,
        correlationId,
        payloadFingerprint,
        startedAt,
        expirationEpochSeconds,
        payload: deliveryPayload,
      });
    }).pipe(
      Effect.provide(Layer.succeed(PushDeliveryService, service)),
    );
    const result = await Effect.runPromise(Effect.either(program));
    if (result._tag === "Left") {
      return deliveryErrorResponse(result.left, correlationId);
    }
    return summaryResponse(
      result.right.summary,
      correlationId,
      result.right.replayed
        ? { "x-cmux-push-replayed": "true" }
        : {},
    );
  } catch {
    // At this point the request has a safe, validated correlation id. Preserve
    // it for support without returning or recording payload, token, database,
    // or provider details from the unexpected exception.
    recordApnsRouteFailure(correlationId, "unexpected");
    return correlatedErrorResponse(
      { error: "push_internal_error", correlationId },
      500,
      correlationId,
    );
  }
}

function deliveryErrorResponse(
  error: PushDeliveryError,
  correlationId: string,
): Response {
  recordApnsRouteFailure(correlationId, error._tag);
  switch (error._tag) {
    case "PushDeliveryInProgressError":
      return new Response(
        JSON.stringify({ error: "push_event_in_progress", correlationId }),
        {
          status: 409,
          headers: {
            "content-type": "application/json",
            "retry-after": String(error.retryAfterSeconds),
            "x-cmux-push-correlation-id": correlationId,
          },
        },
      );
    case "PushDeliveryCorrelationConflictError":
      return correlatedErrorResponse(
        { error: "correlation_payload_mismatch", correlationId },
        409,
        correlationId,
      );
    case "PushDeliveryRateLimitedError":
      return correlatedErrorResponse(
        {
          error: "rate_limited",
          retryAfterSeconds: error.retryAfterSeconds,
          correlationId,
        },
        429,
        correlationId,
        { "retry-after": String(error.retryAfterSeconds) },
      );
    case "PushDeliveryConfigurationError":
      return correlatedErrorResponse(
        { error: error.code, correlationId },
        503,
        correlationId,
      );
    case "PushDeliveryAccountDeletionInProgressError":
      return correlatedErrorResponse(
        { error: "account_deletion_in_progress", correlationId },
        409,
        correlationId,
      );
  }
}

function correlatedErrorResponse(
  body: Record<string, unknown>,
  status: number,
  correlationId: string,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      "x-cmux-push-correlation-id": correlationId,
      ...headers,
    },
  });
}
