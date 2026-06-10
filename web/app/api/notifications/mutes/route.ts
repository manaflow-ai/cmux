// Read or mutate the authenticated user's set of workspaces muted for phone
// push. Mutations are PER-WORKSPACE (POST {workspaceId, muted}), not a full-set
// replace: with multiple iOS devices on one account, a wholesale replace from
// one device's stale local cache would silently delete mutes another device
// added. A single add/remove touches exactly one row, so devices never clobber
// each other and there is no stale-base problem. The push route reads this set
// and drops push for a muted workspace before it reaches APNs, so a muted
// workspace stays silent even while the phone is backgrounded or locked.
// Auth: Stack Bearer from the native client; rows are keyed by that user id.

import { and, count, eq, sql } from "drizzle-orm";
import { cloudDb } from "../../../../db/client";
import { notificationWorkspaceMutes } from "../../../../db/schema";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../services/vms/auth";
import { withApnsApiRoute } from "../../../../services/apns/routeHandler";
import {
  MAX_MUTED_WORKSPACES_PER_USER,
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

  // Echo the authenticated user id so the native client can bind the response to
  // the account it intended to hydrate (defends against an account switch racing
  // the request's token resolution).
  return jsonResponse({ userId: user.id, workspaceIds: rows.map((r) => r.workspaceId) });
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
    // The per-user row count is capped server-side so an authenticated caller
    // cannot grow the table (and the per-push read set) without bound: count
    // under an advisory lock, then insert only if adding a new row stays within
    // the cap. An id already muted is a no-op and always allowed.
    const result = await db.transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${user.id}, 5))`);
      const [{ value: existing } = { value: 0 }] = await tx
        .select({ value: count() })
        .from(notificationWorkspaceMutes)
        .where(eq(notificationWorkspaceMutes.userId, user.id));
      if (existing >= MAX_MUTED_WORKSPACES_PER_USER) {
        const [already] = await tx
          .select({ workspaceId: notificationWorkspaceMutes.workspaceId })
          .from(notificationWorkspaceMutes)
          .where(
            and(
              eq(notificationWorkspaceMutes.userId, user.id),
              eq(notificationWorkspaceMutes.workspaceId, workspaceId),
            ),
          )
          .limit(1);
        if (!already) return "too_many_muted_workspaces" as const;
      }
      await tx
        .insert(notificationWorkspaceMutes)
        .values({ userId: user.id, workspaceId })
        .onConflictDoNothing({
          target: [notificationWorkspaceMutes.userId, notificationWorkspaceMutes.workspaceId],
        });
      return "ok" as const;
    });
    if (result === "too_many_muted_workspaces") {
      return jsonResponse({ error: "too_many_muted_workspaces" }, 409);
    }
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

  // Echo the authenticated user id so the native client can confirm this mutation
  // was applied to the account it intended (account-switch credential binding).
  return jsonResponse({ ok: true, userId: user.id, workspaceId, muted });
}
