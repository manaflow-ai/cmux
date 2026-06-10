import { eq } from "drizzle-orm";
import type { CloudDb } from "../../db/client";
import { notificationWorkspaceMutes } from "../../db/schema";

/// Read a user's muted-workspace set, failing OPEN: any error (including the
/// table not yet existing because the migration has not been applied) returns
/// an empty set so push delivery falls back to existing behavior. Mute is an
/// enhancement over "deliver"; a lookup failure must never silently drop a
/// notification.
export async function readMutedWorkspaceIds(db: CloudDb, userId: string): Promise<Set<string>> {
  try {
    const rows = await db
      .select({ workspaceId: notificationWorkspaceMutes.workspaceId })
      .from(notificationWorkspaceMutes)
      .where(eq(notificationWorkspaceMutes.userId, userId));
    return new Set(rows.map((r) => r.workspaceId));
  } catch (error) {
    console.error("notifications.push.mute_lookup_failed", error);
    return new Set();
  }
}
