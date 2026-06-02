// Register / unregister an iOS APNs device token for push notifications.
// Auth: Stack Bearer (native client) or cookie. A row only exists after the
// user explicitly opts in on their device, so presence == "wants phone pushes".

import { and, count, eq, ne } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { deviceTokens } from "../../../db/schema";
import { jsonResponse } from "../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../services/vms/auth";
import { MAX_DEVICE_TOKENS_PER_USER, normalizeApnsBundle } from "../../../services/apns/routePolicy";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const HEX_TOKEN = /^[0-9a-fA-F]{64,200}$/;

async function readJson(request: Request): Promise<Record<string, unknown> | null> {
  try {
    const text = await request.text();
    if (!text) return {};
    const raw = JSON.parse(text) as unknown;
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
    return raw as Record<string, unknown>;
  } catch {
    return null;
  }
}

export async function POST(request: Request): Promise<Response> {
  const user = await verifyRequest(request);
  if (!user) return unauthorized();

  const body = await readJson(request);
  if (!body) return jsonResponse({ error: "invalid_json" }, 400);

  const deviceToken = typeof body.deviceToken === "string" ? body.deviceToken.trim() : "";
  const bundleId = typeof body.bundleId === "string" ? body.bundleId.trim() : "";
  const platform = typeof body.platform === "string" ? body.platform.trim() || "ios" : "ios";
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
  const [existingToken] = await db
    .select({ userId: deviceTokens.userId })
    .from(deviceTokens)
    .where(eq(deviceTokens.deviceToken, deviceToken))
    .limit(1);

  if (existingToken?.userId !== user.id) {
    const [registered] = await db
      .select({ total: count() })
      .from(deviceTokens)
      .where(and(eq(deviceTokens.userId, user.id), ne(deviceTokens.deviceToken, deviceToken)));
    if (Number(registered?.total ?? 0) >= MAX_DEVICE_TOKENS_PER_USER) {
      return jsonResponse({ error: "too_many_devices" }, 429);
    }
  }

  await db
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

  return jsonResponse({ ok: true });
}

export async function DELETE(request: Request): Promise<Response> {
  const user = await verifyRequest(request);
  if (!user) return unauthorized();

  const body = await readJson(request);
  if (!body) return jsonResponse({ error: "invalid_json" }, 400);
  const deviceToken = typeof body.deviceToken === "string" ? body.deviceToken.trim() : "";
  if (!deviceToken) return jsonResponse({ error: "missing_device_token" }, 400);
  if (!HEX_TOKEN.test(deviceToken)) return jsonResponse({ error: "invalid_device_token" }, 400);

  const db = cloudDb();
  await db
    .delete(deviceTokens)
    .where(and(eq(deviceTokens.deviceToken, deviceToken), eq(deviceTokens.userId, user.id)));

  return jsonResponse({ ok: true });
}
