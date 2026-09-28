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
 *
 * Names are not guaranteed to be there. A snapshot row is written when Stack
 * resolves an account with a complete team list, and it is deleted when that
 * account revokes a lease or is tombstoned for deletion. So a teammate who
 * just revoked a lease reads as "Unknown" on every one of their machines
 * until they next sign in.
 */
export type VmCreator = {
  readonly userId: string;
  readonly displayName: string | null;
};

/**
 * The distinct accounts to look up for these machines.
 *
 * The parameter is wider than `VmEntry`, whose `createdByUserId` is a
 * non-null string, so that mapping a partially shaped entry drops the author
 * instead of throwing inside a response builder.
 */
export function creatorUserIds(
  entries: readonly { readonly createdByUserId?: string | null }[],
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
 * What the TTL did buy, and this gives up: `cloud_vms.owner_team_id` is
 * immutable by trigger, so a machine someone made in a team stays in that team
 * after they leave it, and the team keeps seeing that account's *current* name
 * indefinitely. If they rename themselves afterwards, the team learns the new
 * name. That is a display name on an artifact they left behind in that team,
 * which is why this is written down rather than bounded.
 *
 * A read failure returns an empty map. A list without authors is the behavior
 * that shipped before this, so it is never worth failing the request over.
 * The caller records how many names came back as a span attribute, because a
 * migration lagging in one environment is otherwise indistinguishable from
 * nobody having set a name.
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
 * Adds the caller's own name to a name map.
 *
 * The request already holds it, and it is fresher than any snapshot, so a
 * personal list needs nothing from the read at all and the caller's own rows
 * stay named even when their snapshot has been dropped (a lease revoke
 * deletes it). Mutates and returns `names` so a caller can wrap the read.
 */
export function withCallerName(
  names: Map<string, string>,
  caller: { readonly id: string; readonly displayName: string | null },
): Map<string, string> {
  const name = caller.displayName?.trim();
  if (name) names.set(caller.id, name);
  return names;
}

/**
 * The creator to publish for one entry. Null only for a missing or blank id,
 * which no writer produces: `cloud_vms.user_id` is NOT NULL and every insert
 * site sets it from the authenticated caller. The parameter is wider than
 * `VmEntry` for the reason `creatorUserIds` is.
 *
 * `displayName` never falls back to the raw account id: an opaque id in place
 * of a name is the same unreadable list this is meant to fix.
 */
export function creatorFor(
  entry: { readonly createdByUserId?: string | null },
  names: ReadonlyMap<string, string>,
): VmCreator | null {
  const userId = entry.createdByUserId?.trim();
  if (!userId) return null;
  return { userId, displayName: names.get(userId) ?? null };
}
