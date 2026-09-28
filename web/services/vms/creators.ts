import { inArray } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stackIdentitySnapshots } from "../../db/schema";

/**
 * Who made a Cloud machine, for display only.
 *
 * `/api/vm` is scoped by owner team, so on a team every member sees every
 * member's machines. Until now the list carried no author at all, which left
 * a shared account reading as a pile of generated three-word names with no
 * way to tell whose is whose. `userId` is always present; `displayName` is
 * null when nothing has ever recorded a name for that account.
 */
export type VmCreator = {
  readonly userId: string;
  readonly displayName: string | null;
};

export function creatorUserIds(
  entries: readonly { readonly createdByUserId: string | null }[],
): string[] {
  const ids = new Set<string>();
  for (const entry of entries) {
    const id = entry.createdByUserId?.trim();
    if (id) ids.add(id);
  }
  return [...ids];
}

type CreatorDb = Pick<ReturnType<typeof cloudDb>, "select">;

/**
 * Display names for the accounts that made these machines.
 *
 * This reads `stack_identity_snapshots` with no freshness bound, unlike
 * `readIdentitySnapshot`. That function's TTL is a security parameter: it
 * decides how long a removed member keeps access. Nothing here decides
 * access. The caller is already entitled to every machine in the list, and a
 * name that is a few days out of date still answers "whose machine is this",
 * whereas a ten-minute bound would leave almost every row anonymous. Only the
 * display name is read; the stored email stays on the server.
 *
 * A read failure returns an empty map. A list without authors is the behavior
 * that shipped before this, so it is never worth failing the request over.
 */
export async function readCreatorDisplayNames(
  userIds: readonly string[],
  db?: CreatorDb,
): Promise<Map<string, string>> {
  const names = new Map<string, string>();
  if (userIds.length === 0) return names;
  try {
    const rows = await (db ?? cloudDb())
      .select({
        userId: stackIdentitySnapshots.userId,
        displayName: stackIdentitySnapshots.displayName,
      })
      .from(stackIdentitySnapshots)
      .where(inArray(stackIdentitySnapshots.userId, [...userIds]));
    for (const row of rows) {
      const name = row.displayName?.trim();
      if (name) names.set(row.userId, name);
    }
  } catch {
    return new Map();
  }
  return names;
}

/**
 * The creator to publish for one entry, or null when the row predates the
 * column. Never falls back to the raw account id: an opaque id in place of a
 * name is the same unreadable list this is meant to fix.
 */
export function creatorFor(
  entry: { readonly createdByUserId: string | null },
  names: ReadonlyMap<string, string>,
): VmCreator | null {
  const userId = entry.createdByUserId?.trim();
  if (!userId) return null;
  return { userId, displayName: names.get(userId) ?? null };
}
