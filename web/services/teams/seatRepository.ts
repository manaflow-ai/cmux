import { and, asc, eq, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { stripeSubscriptions, teamBillingOwners } from "../../db/schema";

export type SeatReservation = { readonly userId?: string; readonly email?: string; readonly expiresAt: string };
export type TeamSeatSession = {
  getOrCreateOwner(input: { readonly creatorUserId?: string; readonly adminUserIds?: readonly string[] }): Promise<string>;
  syncMemberOrder(memberIds: readonly string[]): Promise<readonly string[]>;
  listReservations(): Promise<Readonly<Record<string, SeatReservation>>>;
  reserve(key: string, reservation: SeatReservation): Promise<void>;
  releaseReservation(key: string): Promise<void>;
};
export type TeamSeatStore = {
  withTeamLock<T>(teamId: string, operation: (session: TeamSeatSession) => Promise<T>): Promise<T>;
  recordCreator(teamId: string, userId: string): Promise<void>;
};

type OwnerRow = typeof teamBillingOwners.$inferSelect;
const lockKey = (teamId: string) => `team-billing-owner:${teamId}`;

async function loadOwner(tx: any, teamId: string): Promise<OwnerRow | null> {
  const [row] = await tx.select().from(teamBillingOwners).where(eq(teamBillingOwners.stackTeamId, teamId)).limit(1);
  return row ?? null;
}

async function legacyOwner(tx: any, teamId: string): Promise<string | null> {
  const [row] = await tx.select({ userId: stripeSubscriptions.stackUserId })
    .from(stripeSubscriptions)
    .where(and(eq(stripeSubscriptions.stackTeamId, teamId), eq(stripeSubscriptions.scope, "team"), sql`${stripeSubscriptions.stackUserId} <> ${teamId}`, sql`${stripeSubscriptions.stackUserId} <> 'deleted-account'`))
    .orderBy(asc(stripeSubscriptions.createdAt), asc(stripeSubscriptions.id)).limit(1);
  return row?.userId ?? null;
}

function sessionFor(tx: any, teamId: string): TeamSeatSession {
  const requireOwner = async (admins?: readonly string[]) => {
    let row = await loadOwner(tx, teamId);
    if (!row) {
      const owner = await legacyOwner(tx, teamId) ?? [...new Set(admins ?? [])].sort()[0];
      if (!owner) throw new Error(`cannot determine billing owner for team ${teamId}`);
      const [inserted] = await tx.insert(teamBillingOwners).values({ stackTeamId: teamId, billingOwnerUserId: owner, ownerSource: (await legacyOwner(tx, teamId)) ? "stripe_subscription" : "admin_fallback", memberOrder: [owner], seatReservations: {} }).onConflictDoNothing({ target: teamBillingOwners.stackTeamId }).returning();
      row = inserted ?? await loadOwner(tx, teamId);
    }
    if (!row) throw new Error(`team billing owner insert lost for ${teamId}`);
    return row;
  };
  return {
    async getOrCreateOwner(input) {
      let row = await loadOwner(tx, teamId);
      if (!row && input.creatorUserId) {
        const [inserted] = await tx.insert(teamBillingOwners).values({ stackTeamId: teamId, billingOwnerUserId: input.creatorUserId, ownerSource: "creator", memberOrder: [input.creatorUserId], seatReservations: {} }).onConflictDoNothing({ target: teamBillingOwners.stackTeamId }).returning();
        row = inserted ?? await loadOwner(tx, teamId);
      }
      return (row ?? await requireOwner(input.adminUserIds)).billingOwnerUserId;
    },
    async syncMemberOrder(memberIds) {
      const row = await requireOwner();
      const members = new Set(memberIds);
      const prior = (row.memberOrder ?? []).filter((id: string) => members.has(id));
      const order = [...prior, ...[...members].filter((id) => !prior.includes(id)).sort()];
      await tx.update(teamBillingOwners).set({ memberOrder: order, updatedAt: sql`now()` }).where(eq(teamBillingOwners.stackTeamId, teamId));
      return order;
    },
    async listReservations() { return (await requireOwner()).seatReservations ?? {}; },
    async reserve(key, reservation) {
      const row = await requireOwner();
      await tx.update(teamBillingOwners).set({ seatReservations: { ...(row.seatReservations ?? {}), [key]: reservation }, updatedAt: sql`now()` }).where(eq(teamBillingOwners.stackTeamId, teamId));
    },
    async releaseReservation(key) {
      const row = await requireOwner();
      const reservations = { ...(row.seatReservations ?? {}) };
      delete reservations[key];
      await tx.update(teamBillingOwners).set({ seatReservations: reservations, updatedAt: sql`now()` }).where(eq(teamBillingOwners.stackTeamId, teamId));
    },
  };
}

export const databaseTeamSeatStore: TeamSeatStore = {
  async withTeamLock(teamId, operation) {
    return cloudDb().transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${lockKey(teamId)}, 0))`);
      return operation(sessionFor(tx, teamId));
    });
  },
  async recordCreator(teamId, userId) {
    await this.withTeamLock(teamId, async (session) => {
      const owner = await session.getOrCreateOwner({ creatorUserId: userId });
      if (owner !== userId) throw new Error(`team ${teamId} already has an immutable billing owner`);
    });
  },
};

export async function recordTeamCreator(teamId: string, userId: string): Promise<void> {
  return databaseTeamSeatStore.recordCreator(teamId, userId);
}
