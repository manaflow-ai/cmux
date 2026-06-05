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
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${user.id}, 2))`);

    const [existingToken] = await tx
      .select({ userId: deviceTokens.userId })
      .from(deviceTokens)
      .where(eq(deviceTokens.deviceToken, deviceToken))
      .limit(1);

    if (existingToken?.userId !== user.id) {
      const [registrationCount] = await tx
        .select({ total: count() })
        .from(deviceTokens)
        .where(and(eq(deviceTokens.userId, user.id), ne(deviceTokens.deviceToken, deviceToken)));
      if (Number(registrationCount?.total ?? 0) >= MAX_DEVICE_TOKENS_PER_USER) {
        return false;
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

    return true;
  });

  if (!registered) {
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
