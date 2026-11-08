import { and, asc, eq, inArray, isNotNull, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { teamSeatReconciles } from "../../db/schema";

export type DirtyTeamSeatRow = {
  readonly stackTeamId: string;
  readonly dirtyAt: Date;
};

export type TeamSeatReconcileOutcome = {
  readonly memberCount: number | null;
  readonly stripeQuantity: number | null;
  readonly error: string | null;
};

/** Returned by `withTeamLock` when another worker holds the team. */
export const TEAM_SEATS_BUSY: unique symbol = Symbol("team-seats-busy");

/**
 * The durable seat reconcile queue. Marking dirty is one cheap upsert that
 * never waits on a running reconcile; the reconciler serializes per team
 * with a try-lock and clears `dirty_at` only when it still holds the value
 * it read, so a change that lands mid-run keeps the team queued. Tests pass
 * an in-memory queue with the same contract.
 */
export type TeamSeatQueue = {
  markDirty(stackTeamId: string): Promise<void>;
  /** Dirty teams, oldest first, optionally narrowed to `teamIds`. */
  listDirty(limit: number, teamIds?: readonly string[]): Promise<readonly DirtyTeamSeatRow[]>;
  /** Run `work` while holding the team's reconcile lock, or `TEAM_SEATS_BUSY`. */
  withTeamLock<T>(stackTeamId: string, work: () => Promise<T>): Promise<T | typeof TEAM_SEATS_BUSY>;
  /**
   * Record the result. With `error` null the row is clean unless `dirty_at`
   * moved past `observedDirtyAt`; with an error the row stays dirty.
   */
  recordOutcome(stackTeamId: string, observedDirtyAt: Date, outcome: TeamSeatReconcileOutcome): Promise<void>;
};

export const databaseTeamSeatQueue: TeamSeatQueue = {
  async markDirty(stackTeamId) {
    await cloudDb()
      .insert(teamSeatReconciles)
      .values({ stackTeamId, dirtyAt: sql`date_trunc('milliseconds', now())` })
      .onConflictDoUpdate({
        target: teamSeatReconciles.stackTeamId,
        set: { dirtyAt: sql`date_trunc('milliseconds', now())`, updatedAt: sql`now()` },
      });
  },

  async listDirty(limit, teamIds) {
    const scope = teamIds === undefined
      ? isNotNull(teamSeatReconciles.dirtyAt)
      : and(isNotNull(teamSeatReconciles.dirtyAt), inArray(teamSeatReconciles.stackTeamId, [...teamIds]));
    if (teamIds !== undefined && teamIds.length === 0) return [];
    const rows = await cloudDb()
      .select({ stackTeamId: teamSeatReconciles.stackTeamId, dirtyAt: teamSeatReconciles.dirtyAt })
      .from(teamSeatReconciles)
      .where(scope)
      .orderBy(asc(teamSeatReconciles.dirtyAt))
      .limit(limit);
    return rows.filter((row): row is DirtyTeamSeatRow => row.dirtyAt !== null);
  },

  async withTeamLock(stackTeamId, work) {
    return cloudDb().transaction(async (tx) => {
      const [row] = await tx
        .select({ locked: sql<boolean>`pg_try_advisory_xact_lock(hashtextextended(${`team-seats:${stackTeamId}`}, 0))` })
        .from(sql`(select 1) as lock_probe`);
      if (row?.locked !== true) return TEAM_SEATS_BUSY;
      return work();
    });
  },

  async recordOutcome(stackTeamId, observedDirtyAt, outcome) {
    const db = cloudDb();
    const now = sql`now()`;
    await db
      .update(teamSeatReconciles)
      .set({
        lastReconciledAt: now,
        lastMemberCount: outcome.memberCount,
        lastStripeQuantity: outcome.stripeQuantity,
        lastError: outcome.error,
        updatedAt: now,
      })
      .where(eq(teamSeatReconciles.stackTeamId, stackTeamId));
    if (outcome.error !== null) return;
    await db
      .update(teamSeatReconciles)
      .set({ dirtyAt: null })
      .where(and(eq(teamSeatReconciles.stackTeamId, stackTeamId), eq(teamSeatReconciles.dirtyAt, observedDirtyAt)));
  },
};
