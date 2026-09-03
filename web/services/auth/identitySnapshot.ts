import { eq, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stackIdentitySnapshots } from "../../db/schema";
import type { AuthedTeam, AuthedUser } from "../vms/auth";

/**
 * How long a stored identity snapshot may answer for Stack. A snapshot is
 * additionally capped by the expiry of the access token presenting it, so this
 * is an upper bound, not the effective staleness for any single request.
 */
const DEFAULT_SNAPSHOT_TTL_MS = 60 * 60 * 1_000;

export function identitySnapshotTtlMs(
  raw = process.env.CMUX_STACK_IDENTITY_SNAPSHOT_TTL_MS,
): number {
  const trimmed = raw?.trim();
  if (!trimmed) return DEFAULT_SNAPSHOT_TTL_MS;
  const parsed = Number(trimmed);
  if (!Number.isSafeInteger(parsed) || parsed < 0) return DEFAULT_SNAPSHOT_TTL_MS;
  return parsed;
}

type SnapshotDb = Pick<ReturnType<typeof cloudDb>, "select" | "insert" | "delete">;

export type IdentitySnapshotRead = {
  readonly user: AuthedUser;
  readonly ageMs: number;
};

/**
 * The stored identity for `userId`, or null when there is none, it is older
 * than `maxAgeMs`, or the database is unreachable.
 *
 * A read failure returns null rather than throwing: the caller then asks Stack,
 * which is exactly today's behavior. The snapshot is an optimization, never a
 * source of authority the request cannot do without.
 */
export async function readIdentitySnapshot(
  userId: string,
  maxAgeMs: number,
  db?: SnapshotDb,
): Promise<IdentitySnapshotRead | null> {
  if (maxAgeMs <= 0) return null;
  let rows: Array<typeof stackIdentitySnapshots.$inferSelect>;
  try {
    rows = await (db ?? cloudDb())
      .select()
      .from(stackIdentitySnapshots)
      .where(eq(stackIdentitySnapshots.userId, userId))
      .limit(1);
  } catch {
    return null;
  }
  const row = rows[0];
  if (!row) return null;
  const ageMs = Date.now() - row.refreshedAt.getTime();
  // A clock that moved backwards must not turn a stale row into a fresh one.
  if (ageMs < 0 || ageMs > maxAgeMs) return null;
  return { user: authedUserFromSnapshotRow(row), ageMs };
}

function authedUserFromSnapshotRow(
  row: typeof stackIdentitySnapshots.$inferSelect,
): AuthedUser {
  const teams: readonly AuthedTeam[] = (row.teams ?? []).map((team) => ({
    id: team.id,
    displayName: team.displayName ?? null,
    billingPlanId: team.billingPlanId ?? null,
    billingSeats: team.billingSeats ?? null,
  }));
  return {
    id: row.userId,
    displayName: row.displayName,
    primaryEmail: row.primaryEmail,
    billingCustomerType: row.billingCustomerType,
    billingTeamId: row.billingTeamId,
    selectedTeamId: row.selectedTeamId,
    teams,
    teamIds: teams.map((team) => team.id),
    userBillingPlanId: row.userBillingPlanId,
    billingPlanId: row.billingPlanId,
    billingSeats: row.billingSeats,
  };
}

/**
 * Store the identity Stack just returned.
 *
 * Only a verification that listed the user's teams may be stored: a snapshot
 * written from a partial team list would silently deny access to a team the
 * user really belongs to. Callers pass `completeTeamList: false` for the
 * single-team lookup path.
 */
export async function writeIdentitySnapshot(
  user: AuthedUser,
  options: { readonly completeTeamList: boolean },
  db?: SnapshotDb,
): Promise<void> {
  if (!options.completeTeamList) return;
  const teams = user.teams.map((team) => ({
    id: team.id,
    displayName: team.displayName,
    billingPlanId: team.billingPlanId,
    billingSeats: team.billingSeats,
  }));
  try {
    await (db ?? cloudDb())
      .insert(stackIdentitySnapshots)
      .values({
        userId: user.id,
        displayName: user.displayName,
        primaryEmail: user.primaryEmail,
        selectedTeamId: user.selectedTeamId,
        billingCustomerType: user.billingCustomerType,
        billingTeamId: user.billingTeamId,
        userBillingPlanId: user.userBillingPlanId,
        billingPlanId: user.billingPlanId,
        billingSeats: user.billingSeats,
        teams,
        refreshedAt: new Date(),
      })
      .onConflictDoUpdate({
        target: stackIdentitySnapshots.userId,
        set: {
          displayName: sql`excluded.display_name`,
          primaryEmail: sql`excluded.primary_email`,
          selectedTeamId: sql`excluded.selected_team_id`,
          billingCustomerType: sql`excluded.billing_customer_type`,
          billingTeamId: sql`excluded.billing_team_id`,
          userBillingPlanId: sql`excluded.user_billing_plan_id`,
          billingPlanId: sql`excluded.billing_plan_id`,
          billingSeats: sql`excluded.billing_seats`,
          teams: sql`excluded.teams`,
          refreshedAt: sql`excluded.refreshed_at`,
        },
      });
  } catch {
    // A snapshot that fails to persist costs one extra Stack call later. It is
    // never worth failing the request the caller actually made.
  }
}

/**
 * Forget the stored identity for a user. Called when a session is revoked or
 * the account is deleted, so no instance can keep answering from a snapshot
 * the user just invalidated.
 */
export async function deleteIdentitySnapshot(
  userId: string,
  db?: SnapshotDb,
): Promise<void> {
  try {
    await (db ?? cloudDb())
      .delete(stackIdentitySnapshots)
      .where(eq(stackIdentitySnapshots.userId, userId));
  } catch {
    // Best effort: the snapshot expires on its own within the TTL.
  }
}
