// Send a push to the authenticated user's registered iOS devices. Called by the
// macOS app when it shows a terminal notification AND the user enabled phone
// forwarding. No-ops (no APNs traffic) when the user has no registered devices.
// Auth: Stack Bearer (the Mac's signed-in user); routing is by that user id.

import { and, eq, inArray } from "drizzle-orm";
import { env } from "../../../env";
import { cloudDb } from "../../../../db/client";
import { deviceTokens } from "../../../../db/schema";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../services/vms/auth";
import { sendApnsNotification, type ApnsConfig } from "../../../../services/apns/sender";

export const runtime = "nodejs"; // http2 + node:crypto, not edge
export const dynamic = "force-dynamic";

function apnsConfig(): ApnsConfig | null {
  const keyP8 = env.CMUX_APNS_KEY_P8;
  const keyId = env.CMUX_APNS_KEY_ID;
  const teamId = env.CMUX_APNS_TEAM_ID;
  if (!keyP8 || !keyId || !teamId) return null;
  return { keyP8, keyId, teamId };
}

export async function POST(request: Request): Promise<Response> {
  const user = await verifyRequest(request);
  if (!user) return unauthorized();

  let body: Record<string, unknown>;
  try {
    const text = await request.text();
    const raw = text ? (JSON.parse(text) as unknown) : {};
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
      return jsonResponse({ error: "invalid_json" }, 400);
    }
    body = raw as Record<string, unknown>;
  } catch {
    return jsonResponse({ error: "invalid_json" }, 400);
  }

  const title = typeof body.title === "string" ? body.title : "";
  const subtitle = typeof body.subtitle === "string" ? body.subtitle : null;
  const text = typeof body.body === "string" ? body.body : "";
  const workspaceId = typeof body.workspaceId === "string" ? body.workspaceId : null;
  const surfaceId = typeof body.surfaceId === "string" ? body.surfaceId : null;
  const hideContent = body.hideContent === true;
  if (!title && !text) return jsonResponse({ error: "empty_notification" }, 400);

  const db = cloudDb();
  const tokens = await db
    .select({
      deviceToken: deviceTokens.deviceToken,
      bundleId: deviceTokens.bundleId,
      environment: deviceTokens.environment,
    })
    .from(deviceTokens)
    .where(eq(deviceTokens.userId, user.id));

  if (tokens.length === 0) {
    return jsonResponse({ sent: 0, devices: 0 });
  }

  const config = apnsConfig();
  if (!config) {
    return jsonResponse({ error: "apns_not_configured" }, 503);
  }

  const results = await sendApnsNotification(config, tokens, {
    title,
    subtitle,
    body: text,
    workspaceId,
    surfaceId,
    hideContent,
  });

  const dead = results.filter((r) => r.prune).map((r) => r.deviceToken);
  if (dead.length > 0) {
    await db
      .delete(deviceTokens)
      .where(and(eq(deviceTokens.userId, user.id), inArray(deviceTokens.deviceToken, dead)));
  }

  const sent = results.filter((r) => r.status >= 200 && r.status < 300).length;
  return jsonResponse({
    sent,
    devices: tokens.length,
    pruned: dead.length,
    results: results.map((r) => ({ status: r.status, reason: r.reason })),
  });
}
