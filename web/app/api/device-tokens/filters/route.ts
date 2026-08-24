// Store / clear the per-device push mute filters for one registered APNs
// token. Auth: Stack Bearer from the native client, exactly like token
// registration. Filters live on the `device_tokens` row and are evaluated at
// push-send time (services/apns/pushFilters.ts).

import { and, eq, sql } from "drizzle-orm";
import { env } from "../../../env";
import { cloudDb } from "../../../../db/client";
import { deviceTokens } from "../../../../db/schema";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../services/vms/auth";
import { withApnsApiRoute } from "../../../../services/apns/routeHandler";
import { enforceNativeIngressRateLimit } from "../../../../services/nativeIngressRateLimit";
import { authProviderErrorResponse } from "../../../../services/vms/authErrors";
import {
  MAX_FILTERS_REQUEST_BYTES,
  normalizeApnsBundle,
  readBoundedJsonObject,
} from "../../../../services/apns/routePolicy";
import { findPathologicalTitlePattern, parsePushFilters } from "../../../../services/apns/pushFilters";
import {
  AccountDeletionMutationBlockedError,
  assertAccountDeletionUserMutationAllowed,
} from "../../../../services/account/deletionLock";

const HEX_TOKEN = /^[0-9a-fA-F]{64,200}$/;

export async function PUT(request: Request): Promise<Response> {
  const rateLimitResponse = await enforceNativeIngressRateLimit({
    request,
    route: "device-tokens.filters",
    ruleId: env.CMUX_PUSH_RATE_LIMIT_ID,
  });
  if (rateLimitResponse) return rateLimitResponse;
  return withApnsApiRoute(
    request,
    "/api/device-tokens/filters",
    "filters",
    async () => putDeviceTokenFilters(request),
  );
}

async function putDeviceTokenFilters(request: Request): Promise<Response> {
  let user: Awaited<ReturnType<typeof verifyRequest>>;
  try {
    user = await verifyRequest(request, { allowCookie: false });
  } catch (error) {
    return authProviderErrorResponse(error, "device-tokens.filters.auth");
  }
  if (!user) return unauthorized();

  const body = await readBoundedJsonObject(request, MAX_FILTERS_REQUEST_BYTES);
  if (!body.ok) return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);

  const deviceToken = typeof body.value.deviceToken === "string" ? body.value.deviceToken.trim().toLowerCase() : "";
  const bundleId = typeof body.value.bundleId === "string" ? body.value.bundleId.trim() : "";
  const bundle = normalizeApnsBundle(bundleId);

  if (!HEX_TOKEN.test(deviceToken)) {
    return jsonResponse({ error: "invalid_device_token" }, 400);
  }
  if (!bundle) {
    return jsonResponse({ error: "invalid_bundle_id" }, 400);
  }
  const filters = parsePushFilters(body.value.filters);
  if (!filters.ok) {
    return jsonResponse({ error: filters.error }, 400);
  }
  // Refuse documents whose title regexes backtrack catastrophically, so a
  // stored pattern can never stall the push-delivery path. Checked once at
  // write time; delivery evaluates stored patterns without probing.
  if (findPathologicalTitlePattern(filters.value) != null) {
    return jsonResponse({ error: "filter_rule_pattern_too_slow" }, 400);
  }

  const db = cloudDb();

  let update: {
    outcome: "updated" | "unknown" | "busy";
    retryAfterSeconds?: number;
  };
  try {
    update = await db.transaction(async (tx) => {
      await assertAccountDeletionUserMutationAllowed(tx, user.id);
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${user.id}, 2))`);

      const [existingToken] = await tx
        .select({
          deliveryLeaseUntil: deviceTokens.deliveryLeaseUntil,
        })
        .from(deviceTokens)
        .where(and(
          eq(deviceTokens.userId, user.id),
          eq(deviceTokens.bundleId, bundle.bundleId),
          eq(deviceTokens.deviceToken, deviceToken),
        ))
        .limit(1)
        .for("update");
      if (!existingToken) {
        return { outcome: "unknown" as const };
      }

      const deliveryLeaseUntilMs =
        existingToken.deliveryLeaseUntil?.getTime() ?? 0;
      if (deliveryLeaseUntilMs > Date.now()) {
        return {
          outcome: "busy" as const,
          retryAfterSeconds: Math.max(
            1,
            Math.ceil((deliveryLeaseUntilMs - Date.now()) / 1_000),
          ),
        };
      }

      await tx
        .update(deviceTokens)
        .set({
          pushFilters: filters.value,
          updatedAt: new Date(),
        })
        .where(and(
          eq(deviceTokens.userId, user.id),
          eq(deviceTokens.bundleId, bundle.bundleId),
          eq(deviceTokens.deviceToken, deviceToken),
        ));

      return { outcome: "updated" as const };
    });
  } catch (error) {
    if (error instanceof AccountDeletionMutationBlockedError) {
      return jsonResponse({ error: "account_deletion_in_progress" }, 409);
    }
    throw error;
  }

  if (update.outcome === "unknown") {
    return jsonResponse({ error: "unknown_device_token" }, 404);
  }
  if (update.outcome === "busy") {
    return new Response(
      JSON.stringify({
        error: "push_delivery_in_progress",
        retryAfterSeconds: update.retryAfterSeconds,
      }),
      {
        status: 409,
        headers: {
          "content-type": "application/json",
          "retry-after": String(update.retryAfterSeconds),
        },
      },
    );
  }

  return jsonResponse({ ok: true });
}
