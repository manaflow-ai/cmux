// Register / unregister an iOS APNs device token for push notifications.
// Auth: Stack Bearer (native client) or cookie. A row only exists after the
// user explicitly opts in on their device, so presence == "wants phone pushes".

import { and, eq } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { deviceTokens } from "../../../db/schema";
import { jsonResponse } from "../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../services/vms/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const HEX_TOKEN = /^[0-9a-fA-F]{8,200}$/;

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
  const environment = body.environment === "sandbox" ? "sandbox" : "production";
  const platform = typeof body.platform === "string" ? body.platform.trim() || "ios" : "ios";

  if (!HEX_TOKEN.test(deviceToken)) {
    return jsonResponse({ error: "invalid_device_token" }, 400);
  }
  if (!bundleId) {
    return jsonResponse({ error: "missing_bundle_id" }, 400);
  }

  const db = cloudDb();
  await db
    .insert(deviceTokens)
    .values({ userId: user.id, deviceToken, bundleId, environment, platform })
    .onConflictDoUpdate({
      target: deviceTokens.deviceToken,
      set: { userId: user.id, bundleId, environment, platform, updatedAt: new Date() },
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

  const db = cloudDb();
  await db
    .delete(deviceTokens)
    .where(and(eq(deviceTokens.deviceToken, deviceToken), eq(deviceTokens.userId, user.id)));

  return jsonResponse({ ok: true });
}
