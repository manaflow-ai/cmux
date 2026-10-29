import { and, inArray, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { runWithCloudDbQuerySignal } from "../../db/queryScope";
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
 * until they next sign in, and someone who has left the owning team reads as
 * "Unknown" there for good.
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
 * How long the list waits for names before answering without them. The read
 * is one indexed lookup; anything slower is a stalled connection, and names
 * are not worth holding the machine list for.
 */
export const CREATOR_LOOKUP_TIMEOUT_MS = 2_000;

/**
 * Display names for the accounts that made these machines, limited to accounts
 * whose snapshot shows current membership of `teamId`, the team that owns the
 * machines.
 *
 * This reads `stack_identity_snapshots` with no freshness bound, unlike
 * `readIdentitySnapshot`. That function's TTL is a security parameter: it
 * decides how long a removed member keeps access. Nothing here decides
 * access. The caller is already entitled to every machine in the list, and a
 * name that is a few days out of date still answers "whose machine is this",
 * whereas a ten-minute bound would leave almost every row anonymous. Only the
 * display name is read; the stored email stays on the server.
 *
 * The membership filter is what keeps that trade-off small. A machine someone
 * made in a team stays in that team after they leave it (`owner_team_id` is
 * immutable by trigger), but once their snapshot no longer lists the team,
 * the team stops receiving their name, including any name they set later.
 * Their machines then read as "Unknown", the same as an account with no name.
 * A null `teamId` (a personal list, which holds only the caller's own
 * machines) reads nothing.
 *
 * A read failure returns an empty map and reports the error to `onFailure`.
 * A list without authors is the behavior that shipped before this, so it is
 * never worth failing the request over. The same holds for a slow read: the
 * lookup is bounded by `timeoutMs`, after which the query is cancelled
 * through the driver and the request continues with no names. The wait is
 * raced against the deadline as well as cancelled, because a cancel packet on
 * a stalled connection does not settle the query promptly on its own.
 */
export async function readCreatorDisplayNames(
  userIds: readonly string[],
  options: {
    readonly teamId: string | null | undefined;
    readonly db?: CreatorDb;
    readonly timeoutMs?: number;
    readonly onFailure?: (error: unknown) => void;
  },
): Promise<Map<string, string>> {
  const names = new Map<string, string>();
  const teamId = options.teamId?.trim();
  if (userIds.length === 0 || !teamId) return names;
  const signal = AbortSignal.timeout(options.timeoutMs ?? CREATOR_LOOKUP_TIMEOUT_MS);
  let onAbort: (() => void) | undefined;
  const deadline = new Promise<never>((_, reject) => {
    onAbort = () => reject(signal.reason);
    signal.addEventListener("abort", onAbort, { once: true });
  });
  const membership = JSON.stringify([{ id: teamId }]);
  try {
    const query = runWithCloudDbQuerySignal(signal, async () =>
      (options.db ?? cloudDb())
        .select({
          userId: stackIdentitySnapshots.userId,
          displayName: stackIdentitySnapshots.displayName,
        })
        .from(stackIdentitySnapshots)
        .where(and(
          inArray(stackIdentitySnapshots.userId, [...userIds]),
          sql`${stackIdentitySnapshots.teams} @> ${membership}::jsonb`,
        )),
    );
    // The losing side of the race must not surface as an unhandled rejection.
    query.catch(() => undefined);
    const rows = await Promise.race([query, deadline]);
    for (const row of rows) {
      const name = row.displayName?.trim();
      if (name) names.set(row.userId, name);
    }
  } catch (error) {
    try {
      options.onFailure?.(error);
    } catch {
      // Reporting is best effort; it must not turn the fallback into a 500.
    }
    return new Map();
  } finally {
    if (onAbort) signal.removeEventListener("abort", onAbort);
  }
  return names;
}

/**
 * The name map a response needs for machines owned by `teamId`: the caller's
 * own name from the session, and a snapshot read for everyone else. A caller
 * with a session name is left out of the read, so a team list of only their
 * machines costs no query at all (a personal list never queries).
 */
export async function readCreatorNames(input: {
  readonly userIds: readonly string[];
  readonly teamId: string | null | undefined;
  readonly caller: { readonly id: string; readonly displayName: string | null };
  readonly onFailure?: (error: unknown) => void;
  readonly db?: CreatorDb;
}): Promise<Map<string, string>> {
  // Only a usable session name replaces the read; a caller with a blank one
  // still gets whatever their snapshot holds.
  const sessionNamed = Boolean(input.caller.displayName?.trim());
  const others = input.userIds.filter((id) => !sessionNamed || id !== input.caller.id);
  return withCallerName(
    await readCreatorDisplayNames(others, {
      teamId: input.teamId,
      onFailure: input.onFailure,
      db: input.db,
    }),
    input.caller,
  );
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
