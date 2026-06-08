// Read or replace the authenticated user's set of workspaces muted for phone
// push. The iOS app owns the set and replaces it wholesale on every mute/unmute
// (idempotent PUT). The push route reads this set and drops push for a muted
// workspace before it ever reaches APNs, so a muted workspace stays silent even
// while the phone is backgrounded or locked.
// Auth: Stack Bearer from the native client; the set is keyed by that user id.

import { and, eq, notInArray, sql } from "drizzle-orm";
import { cloudDb } from "../../../../db/client";
import { notificationWorkspaceMutes } from "../../../../db/schema";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../services/vms/auth";
import { withApnsApiRoute } from "../../../../services/apns/routeHandler";
import {
  MAX_MUTE_REQUEST_BYTES,
  parseMuteWorkspacesPayload,
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

export async function PUT(request: Request): Promise<Response> {
  return withApnsApiRoute(request, "/api/notifications/mutes", "replace", async () => replaceMutes(request));
}

async function replaceMutes(request: Request): Promise<Response> {
  const user = await verifyRequest(request, { allowCookie: false });
  if (!user) return unauthorized();

  const body = await readBoundedJsonObject(request, MAX_MUTE_REQUEST_BYTES);
  if (!body.ok) return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);

  const parsed = parseMuteWorkspacesPayload(body.value);
  if (!parsed.ok) return jsonResponse({ error: parsed.error }, 400);
  const workspaceIds = parsed.value;

  const db = cloudDb();
  await db.transaction(async (tx) => {
    // Serialize concurrent replaces for the same user so the set never tears.
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${user.id}, 3))`);

    // Remove rows no longer in the set (or all rows when the set is empty).
    if (workspaceIds.length === 0) {
      await tx.delete(notificationWorkspaceMutes).where(eq(notificationWorkspaceMutes.userId, user.id));
    } else {
      await tx.delete(notificationWorkspaceMutes).where(
        and(
          eq(notificationWorkspaceMutes.userId, user.id),
          notInArray(notificationWorkspaceMutes.workspaceId, [...workspaceIds]),
        ),
      );
      // Insert the desired set; ignore rows that already exist.
      await tx
        .insert(notificationWorkspaceMutes)
        .values(workspaceIds.map((workspaceId) => ({ userId: user.id, workspaceId })))
        .onConflictDoNothing({
          target: [notificationWorkspaceMutes.userId, notificationWorkspaceMutes.workspaceId],
        });
    }
  });

  return jsonResponse({ ok: true, workspaceIds });
}
