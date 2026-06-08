// Read or mutate the authenticated user's set of workspaces muted for phone
// push. Mutations are PER-WORKSPACE (POST {workspaceId, muted}), not a full-set
// replace: with multiple iOS devices on one account, a wholesale replace from
// one device's stale local cache would silently delete mutes another device
// added. A single add/remove touches exactly one row, so devices never clobber
// each other and there is no stale-base problem. The push route reads this set
// and drops push for a muted workspace before it reaches APNs, so a muted
// workspace stays silent even while the phone is backgrounded or locked.
// Auth: Stack Bearer from the native client; rows are keyed by that user id.

import { and, eq } from "drizzle-orm";
import { cloudDb } from "../../../../db/client";
import { notificationWorkspaceMutes } from "../../../../db/schema";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../services/vms/auth";
import { withApnsApiRoute } from "../../../../services/apns/routeHandler";
import {
  MAX_MUTE_REQUEST_BYTES,
  parseMuteMutationPayload,
  readBoundedJsonObject,
} from "../../../../services/apns/routePolicy";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  return withApnsApiRoute(request, "/api/notifications/mutes", "list", async () => listMutes(request));
}

async function listMutes(request: Request): Promise<Response> {
  const user = await verifyRequest(request, { allowCookie: false });
  if (!user) return unauthorized();

  const db = cloudDb();
  const rows = await db
    .select({ workspaceId: notificationWorkspaceMutes.workspaceId })
    .from(notificationWorkspaceMutes)
    .where(eq(notificationWorkspaceMutes.userId, user.id));

  return jsonResponse({ workspaceIds: rows.map((r) => r.workspaceId) });
}

export async function POST(request: Request): Promise<Response> {
  return withApnsApiRoute(request, "/api/notifications/mutes", "mutate", async () => mutateMute(request));
}

async function mutateMute(request: Request): Promise<Response> {
  const user = await verifyRequest(request, { allowCookie: false });
  if (!user) return unauthorized();

  const body = await readBoundedJsonObject(request, MAX_MUTE_REQUEST_BYTES);
  if (!body.ok) return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);

  const parsed = parseMuteMutationPayload(body.value);
  if (!parsed.ok) return jsonResponse({ error: parsed.error }, 400);
  const { workspaceId, muted } = parsed.value;

  const db = cloudDb();
  if (muted) {
    // Idempotent add of exactly this workspace; other devices' rows untouched.
    await db
      .insert(notificationWorkspaceMutes)
      .values({ userId: user.id, workspaceId })
      .onConflictDoNothing({
        target: [notificationWorkspaceMutes.userId, notificationWorkspaceMutes.workspaceId],
      });
  } else {
    await db
      .delete(notificationWorkspaceMutes)
      .where(
        and(
          eq(notificationWorkspaceMutes.userId, user.id),
          eq(notificationWorkspaceMutes.workspaceId, workspaceId),
        ),
      );
  }

  return jsonResponse({ ok: true, workspaceId, muted });
}
