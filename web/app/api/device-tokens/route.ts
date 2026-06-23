// Register / unregister an iOS APNs device token for push notifications.
// Auth: Stack Bearer from the native client. A row only exists after the
// user explicitly opts in on their device, so presence == "wants phone pushes".

import { and, count, eq, ne, sql } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { deviceTokens } from "../../../db/schema";
import { jsonResponse } from "../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../services/vms/auth";
import { withApnsApiRoute } from "../../../services/apns/routeHandler";
import {
  MAX_DEVICE_TOKENS_PER_USER,
  MAX_PUSH_REQUEST_BYTES,
  normalizeApnsBundle,
  readBoundedJsonObject,
} from "../../../services/apns/routePolicy";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const HEX_TOKEN = /^[0-9a-fA-F]{64,200}$/;

export async function POST(request: Request): Promise<Response> {
  return withApnsApiRoute(request, "/api/device-tokens", "register", async () => registerDeviceToken(request));
}

async function registerDeviceToken(request: Request): Promise<Response> {
  const user = await verifyRequest(request, { allowCookie: false });
  if (!user) return unauthorized();

  const body = await readBoundedJsonObject(request, MAX_PUSH_REQUEST_BYTES);
  if (!body.ok) return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);

  const deviceToken = typeof body.value.deviceToken === "string" ? body.value.deviceToken.trim().toLowerCase() : "";
  const bundleId = typeof body.value.bundleId === "string" ? body.value.bundleId.trim() : "";
  const platform = typeof body.value.platform === "string" ? body.value.platform.trim() || "ios" : "ios";
  const bundle = normalizeApnsBundle(bundleId);

  if (!HEX_TOKEN.test(deviceToken)) {
    return jsonResponse({ error: "invalid_device_token" }, 400);
  }
  if (!bundle) {
    return jsonResponse({ error: "invalid_bundle_id" }, 400);
  }
  if (platform !== "ios") {
    return jsonResponse({ error: "invalid_platform" }, 400);
  }

  const db = cloudDb();

  const registered = await db.transaction(async (tx) => {
    // Two advisory locks: one keyed on the user (serializes that user's
    // registration-cap accounting across concurrent registrations) and one
    // keyed on the token (serializes cross-user claims on the same device
    // token). The global unique index on `deviceToken` makes a conflict
    // reachable from a different user, so without the token-scoped lock two
    // users racing to claim the same token would not serialize against each
    // other. Different seeds (2 vs 3) keep the two lock namespaces disjoint.
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${user.id}, 2))`);
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${deviceToken}, 3))`);

    const [existingToken] = await tx
      .select({ userId: deviceTokens.userId })
      .from(deviceTokens)
      .where(eq(deviceTokens.deviceToken, deviceToken))
      .limit(1);

    // A device token pins its owning user. The unique index on `deviceToken`
    // is global (by design, so a re-pairing device can move to a new account),
    // which means an `onConflictDoUpdate` is reachable from a *different* user.
    // Without this guard, anyone who learns another user's APNs token could
    // reassign it to their own account and then either receive that user's
    // pushes or silently drop them. Mirrors /api/devices: a token owned by
    // someone else cannot be taken over. A genuine re-pair is initiated by the
    // old owner deleting the row first.
    if (existingToken && existingToken.userId !== user.id) {
      return { error: "device_not_owned" as const };
    }

    // Only a brand-new token consumes a per-user registration slot; a
    // same-user re-register updates the existing row in place.
    if (!existingToken) {
      const [registrationCount] = await tx
        .select({ total: count() })
        .from(deviceTokens)
        .where(and(eq(deviceTokens.userId, user.id), ne(deviceTokens.deviceToken, deviceToken)));
      if (Number(registrationCount?.total ?? 0) >= MAX_DEVICE_TOKENS_PER_USER) {
        return { error: "too_many_devices" as const };
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
        target: deviceTokens.deviceToken,
        set: {
          userId: user.id,
          bundleId: bundle.bundleId,
          environment: bundle.environment,
          platform,
          updatedAt: new Date(),
        },
      });

    return { error: null };
  });

  if (registered.error === "device_not_owned") {
    return jsonResponse({ error: "device_not_owned" }, 403);
  }
  if (registered.error === "too_many_devices") {
    return jsonResponse({ error: "too_many_devices" }, 429);
  }

  return jsonResponse({ ok: true });
}

export async function DELETE(request: Request): Promise<Response> {
  return withApnsApiRoute(request, "/api/device-tokens", "delete", async () => deleteDeviceToken(request));
}

async function deleteDeviceToken(request: Request): Promise<Response> {
  const user = await verifyRequest(request, { allowCookie: false });
  if (!user) return unauthorized();

  const body = await readBoundedJsonObject(request, MAX_PUSH_REQUEST_BYTES);
  if (!body.ok) return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  const deviceToken = typeof body.value.deviceToken === "string" ? body.value.deviceToken.trim().toLowerCase() : "";
  if (!deviceToken) return jsonResponse({ error: "missing_device_token" }, 400);
  if (!HEX_TOKEN.test(deviceToken)) return jsonResponse({ error: "invalid_device_token" }, 400);

  const db = cloudDb();
  await db
    .delete(deviceTokens)
    .where(and(eq(deviceTokens.deviceToken, deviceToken), eq(deviceTokens.userId, user.id)));

  return jsonResponse({ ok: true });
}
