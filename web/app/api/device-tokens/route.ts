// Register / unregister an iOS APNs device token for push notifications.
// Auth: Stack Bearer from the native client. A row only exists after the
// user explicitly opts in on their device, so presence == "wants phone pushes".

import { and, count, eq, ne, or, sql } from "drizzle-orm";
import { env } from "../../env";
import { cloudDb } from "../../../db/client";
import { deviceTokens } from "../../../db/schema";
import { resolveApnsProviderConfiguration } from "../../../services/apns/config";
import { jsonResponse } from "../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../services/vms/auth";
import { withApnsApiRoute } from "../../../services/apns/routeHandler";
import { enforceNativeIngressRateLimit } from "../../../services/nativeIngressRateLimit";
import { authProviderErrorResponse } from "../../../services/vms/authErrors";
import {
  MAX_DEVICE_TOKENS_PER_ACCOUNT,
  MAX_DEVICE_TOKENS_PER_USER,
  MAX_PUSH_REQUEST_BYTES,
  normalizeApnsBundle,
  readBoundedJsonObject,
} from "../../../services/apns/routePolicy";
import {
  AccountDeletionMutationBlockedError,
  assertAccountDeletionUserMutationAllowed,
} from "../../../services/account/deletionLock";


const HEX_TOKEN = /^[0-9a-fA-F]{64,200}$/;

export async function POST(request: Request): Promise<Response> {
  const rateLimitResponse = await enforceNativeIngressRateLimit({
    request,
    route: "device-tokens.post",
    ruleId: env.CMUX_PUSH_RATE_LIMIT_ID,
  });
  if (rateLimitResponse) return rateLimitResponse;
  return withApnsApiRoute(request, "/api/device-tokens", "register", async () => registerDeviceToken(request));
}

async function registerDeviceToken(request: Request): Promise<Response> {
  let user: Awaited<ReturnType<typeof verifyRequest>>;
  try {
    user = await verifyRequest(request, { allowCookie: false });
  } catch (error) {
    return authProviderErrorResponse(error, "device-tokens.post.auth");
  }
  if (!user) return unauthorized();

  const body = await readBoundedJsonObject(request, MAX_PUSH_REQUEST_BYTES);
  if (!body.ok) return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);

  const deviceToken = typeof body.value.deviceToken === "string" ? body.value.deviceToken.trim().toLowerCase() : "";
  const bundleId = typeof body.value.bundleId === "string" ? body.value.bundleId.trim() : "";
  const clientNamespace = request.headers.get("x-cmux-app-namespace") ?? "legacy";
  const platform = typeof body.value.platform === "string" ? body.value.platform.trim() || "ios" : "ios";
  const bundle = normalizeApnsBundle(bundleId);

  if (!HEX_TOKEN.test(deviceToken)) {
    return jsonResponse({ error: "invalid_device_token" }, 400);
  }
  if (!bundle) {
    return jsonResponse({ error: "invalid_bundle_id" }, 400);
  }
  if (
    !/^[A-Za-z0-9._:-]{1,255}$/.test(clientNamespace) ||
    (clientNamespace !== "legacy" && clientNamespace !== bundle.bundleId)
  ) {
    return jsonResponse({ error: "client_namespace_mismatch" }, 403);
  }
  if (platform !== "ios") {
    return jsonResponse({ error: "invalid_platform" }, 400);
  }

  const db = cloudDb();

  let registration: {
    limitReached: boolean;
    deliveryBusyRetryAfterSeconds?: number;
  };
  try {
    registration = await db.transaction(async (tx) => {
      await assertAccountDeletionUserMutationAllowed(tx, user.id);
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${user.id}, 2))`);

      const [existingToken] = await tx
        .select({
          userId: deviceTokens.userId,
          bundleId: deviceTokens.bundleId,
          deliveryLeaseUntil: deviceTokens.deliveryLeaseUntil,
        })
        .from(deviceTokens)
        .where(and(
          eq(deviceTokens.bundleId, bundle.bundleId),
          eq(deviceTokens.deviceToken, deviceToken),
        ))
        .limit(1)
        .for("update");

      const deliveryLeaseUntilMs =
        existingToken?.deliveryLeaseUntil?.getTime() ?? 0;
      if (deliveryLeaseUntilMs > Date.now()) {
        return {
          limitReached: false,
          deliveryBusyRetryAfterSeconds: Math.max(
            1,
            Math.ceil((deliveryLeaseUntilMs - Date.now()) / 1_000),
          ),
        };
      }

      if (existingToken?.userId !== user.id) {
        const [accountRegistrationCount] = await tx
          .select({ total: count() })
          .from(deviceTokens)
          .where(and(
            eq(deviceTokens.userId, user.id),
            or(
              ne(deviceTokens.bundleId, bundle.bundleId),
              ne(deviceTokens.deviceToken, deviceToken),
            ),
          ));
        if (
          Number(accountRegistrationCount?.total ?? 0)
          >= MAX_DEVICE_TOKENS_PER_ACCOUNT
        ) {
          return { limitReached: true };
        }
        const [registrationCount] = await tx
          .select({ total: count() })
          .from(deviceTokens)
          .where(and(
            eq(deviceTokens.userId, user.id),
            eq(deviceTokens.bundleId, bundle.bundleId),
            ne(deviceTokens.deviceToken, deviceToken),
          ));
        if (Number(registrationCount?.total ?? 0) >= MAX_DEVICE_TOKENS_PER_USER) {
          // Never guess that an old-looking token is dead. Only an APNs
          // terminal response proves that and the send route prunes it there.
          // Re-registering a known current token still succeeds above; a new
          // token receives a typed repair rather than silently evicting a
          // potentially live device.
          return { limitReached: true };
        }
      }

      await tx
        .insert(deviceTokens)
        .values({
          userId: user.id,
          deviceToken,
          bundleId: bundle.bundleId,
          environment: bundle.environment,
          platform,
        })
        .onConflictDoUpdate({
          target: [
            deviceTokens.bundleId,
            deviceTokens.deviceToken,
          ],
          set: {
            userId: user.id,
            bundleId: bundle.bundleId,
            environment: bundle.environment,
            platform,
            updatedAt: new Date(),
          },
        });

      return { limitReached: false };
    });
  } catch (error) {
    if (error instanceof AccountDeletionMutationBlockedError) {
      return jsonResponse({ error: "account_deletion_in_progress" }, 409);
    }
    throw error;
  }

  if (registration.limitReached) {
    return jsonResponse(
      {
        error: "too_many_devices",
        limit: MAX_DEVICE_TOKENS_PER_USER,
        action: "disable_push_on_another_device",
      },
      429,
    );
  }
  if (registration.deliveryBusyRetryAfterSeconds != null) {
    return new Response(
      JSON.stringify({
        error: "push_delivery_in_progress",
        retryAfterSeconds: registration.deliveryBusyRetryAfterSeconds,
      }),
      {
        status: 409,
        headers: {
          "content-type": "application/json",
          "retry-after": String(registration.deliveryBusyRetryAfterSeconds),
        },
      },
    );
  }
  return jsonResponse({
    ok: true,
    pushServiceConfigured: resolveApnsProviderConfiguration(
      env.CMUX_APNS_KEY_P8,
      env.CMUX_APNS_KEY_ID,
      env.CMUX_APNS_TEAM_ID,
    ) !== null,
  });
}

export async function DELETE(request: Request): Promise<Response> {
  const rateLimitResponse = await enforceNativeIngressRateLimit({
    request,
    route: "device-tokens.delete",
    ruleId: env.CMUX_PUSH_RATE_LIMIT_ID,
  });
  if (rateLimitResponse) return rateLimitResponse;
  return withApnsApiRoute(request, "/api/device-tokens", "delete", async () => deleteDeviceToken(request));
}

async function deleteDeviceToken(request: Request): Promise<Response> {
  let user: Awaited<ReturnType<typeof verifyRequest>>;
  try {
    user = await verifyRequest(request, { allowCookie: false });
  } catch (error) {
    return authProviderErrorResponse(error, "device-tokens.delete.auth");
  }
  if (!user) return unauthorized();

  const body = await readBoundedJsonObject(request, MAX_PUSH_REQUEST_BYTES);
  if (!body.ok) return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  const deviceToken = typeof body.value.deviceToken === "string" ? body.value.deviceToken.trim().toLowerCase() : "";
  const bodyBundleId =
    typeof body.value.bundleId === "string"
      ? body.value.bundleId.trim()
      : "";
  const headerNamespace = request.headers.get("x-cmux-app-namespace");
  const clientNamespace = headerNamespace ?? bodyBundleId;
  if (!deviceToken) return jsonResponse({ error: "missing_device_token" }, 400);
  if (!HEX_TOKEN.test(deviceToken)) return jsonResponse({ error: "invalid_device_token" }, 400);
  if (clientNamespace && (
    !normalizeApnsBundle(clientNamespace) ||
    (headerNamespace !== null &&
      bodyBundleId !== "" &&
      headerNamespace !== bodyBundleId)
  )) {
    return jsonResponse({ error: "invalid_client_namespace" }, 400);
  }

  const db = cloudDb();
  const deletion = await db.transaction(async (tx) => {
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${user.id}, 2))`,
    );
    const matches = await tx
      .select({
        bundleId: deviceTokens.bundleId,
        deliveryLeaseUntil: deviceTokens.deliveryLeaseUntil,
      })
      .from(deviceTokens)
      .where(clientNamespace
        ? and(
          eq(deviceTokens.deviceToken, deviceToken),
          eq(deviceTokens.userId, user.id),
          eq(deviceTokens.bundleId, clientNamespace),
        )
        : and(
          eq(deviceTokens.deviceToken, deviceToken),
          eq(deviceTokens.userId, user.id),
        ))
      .limit(clientNamespace ? 1 : 2)
      .for("update");
    if (!clientNamespace && matches.length > 1) {
      return { outcome: "ambiguous" as const };
    }
    const existingToken = matches[0];
    const deliveryLeaseUntilMs =
      existingToken?.deliveryLeaseUntil?.getTime() ?? 0;
    if (deliveryLeaseUntilMs > Date.now()) {
      return {
        outcome: "busy" as const,
        retryAfterSeconds: Math.max(
          1,
          Math.ceil((deliveryLeaseUntilMs - Date.now()) / 1_000),
        ),
      };
    }
    if (existingToken) {
      await tx
        .delete(deviceTokens)
        .where(and(
          eq(deviceTokens.deviceToken, deviceToken),
          eq(deviceTokens.userId, user.id),
          eq(deviceTokens.bundleId, existingToken.bundleId),
        ));
    }
    return { outcome: "deleted" as const };
  });
  if (deletion.outcome === "ambiguous") {
    return jsonResponse({ error: "ambiguous_legacy_device_token" }, 409);
  }
  if (deletion.outcome === "busy") {
    return new Response(
      JSON.stringify({
        error: "push_delivery_in_progress",
        retryAfterSeconds: deletion.retryAfterSeconds,
      }),
      {
        status: 409,
        headers: {
          "content-type": "application/json",
          "retry-after": String(deletion.retryAfterSeconds),
        },
      },
    );
  }

  return jsonResponse({ ok: true });
}
