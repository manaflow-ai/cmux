import { and, desc, eq, gt, inArray, isNull, lt, or, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import {
  teamEmailInvitations,
  teamInviteLinkRedemptions,
  teamInviteLinks,
  teamInviteRoles,
} from "../../db/schema";
import type { TeamRole } from "./types";

export type StoredInviteLink = {
  readonly id: string;
  readonly stackTeamId: string;
  readonly createdAt: Date;
  readonly createdByUserId: string;
  readonly expiresAt: Date | null;
  readonly revokedAt: Date | null;
  readonly maxUses: number | null;
  readonly useCount: number;
};

/**
 * A role applies only to the Stack invitation it was sent with. Members can
 * send Stack invitations too, and those must never inherit a stored admin role.
 */
export type StoredInviteRole = {
  readonly role: TeamRole;
  readonly stackInvitationId: string | null;
};

export type LinkClaimResult = "claimed" | "already_redeemed" | "unavailable";

export type StoredEmailInvitation = {
  readonly id: string;
  readonly stackTeamId: string;
  readonly email: string;
  readonly role: TeamRole;
  readonly invitedByUserId: string;
  readonly createdAt: Date;
  readonly lastSentAt: Date;
  readonly expiresAt: Date;
  readonly revokedAt: Date | null;
  readonly acceptedAt: Date | null;
  readonly acceptedByUserId: string | null;
  readonly declinedAt: Date | null;
};

/**
 * Persistence for invite roles and invite links. The database version is the
 * default; tests pass an in-memory store with the same contract.
 */
export type TeamInviteStore = {
  upsertInviteRole(input: {
    readonly stackTeamId: string;
    readonly email: string;
    readonly role: TeamRole;
    readonly invitedByUserId: string;
  }): Promise<void>;
  /** Stored roles by email, each with the Stack invitation it was sent with. */
  inviteRoles(stackTeamId: string, emails: readonly string[]): Promise<Map<string, StoredInviteRole>>;
  /** Record which Stack invitation carries the stored role. No row, no change. */
  bindInviteRoleInvitation(stackTeamId: string, email: string, stackInvitationId: string): Promise<void>;
  deleteInviteRole(stackTeamId: string, email: string): Promise<void>;
  deleteTeamInviteState(stackTeamId: string): Promise<void>;

  createLink(input: {
    readonly stackTeamId: string;
    readonly tokenHash: string;
    readonly createdByUserId: string;
    readonly expiresAt: Date | null;
    readonly maxUses: number | null;
  }): Promise<StoredInviteLink>;
  /** Links that are neither revoked nor expired, full ones included. */
  listActiveLinks(stackTeamId: string): Promise<StoredInviteLink[]>;
  /** A link by token hash that is neither revoked nor expired. */
  findActiveLinkByTokenHash(tokenHash: string): Promise<StoredInviteLink | null>;
  /** Set `revoked_at`. False when no such link belongs to the team. */
  revokeLink(stackTeamId: string, linkId: string): Promise<boolean>;
  /**
   * Record one redemption atomically: a new redemption row and a use-count
   * increment that only succeeds while the link is live and not full.
   */
  claimLink(linkId: string, userId: string): Promise<LinkClaimResult>;
  /** Undo a claim whose Stack membership write failed. */
  releaseLinkClaim(linkId: string, userId: string): Promise<void>;

  createEmailInvitation(input: {
    readonly stackTeamId: string;
    readonly email: string;
    readonly role: TeamRole;
    readonly invitedByUserId: string;
    readonly tokenHash: string;
    readonly expiresAt: Date;
  }): Promise<StoredEmailInvitation>;
  /** Pending: not accepted, declined, revoked or expired. Newest first. */
  listPendingEmailInvitations(stackTeamId: string): Promise<StoredEmailInvitation[]>;
  /** Pending invitations addressed to any of `emails`, across teams. */
  listPendingEmailInvitationsForEmails(emails: readonly string[]): Promise<StoredEmailInvitation[]>;
  /** Any row by id, whatever its state. */
  findEmailInvitation(id: string): Promise<StoredEmailInvitation | null>;
  /** A pending row by token hash. */
  findPendingEmailInvitationByTokenHash(tokenHash: string): Promise<StoredEmailInvitation | null>;
  /** Give a pending row a fresh token and expiry for a resend. */
  refreshEmailInvitation(id: string, input: { readonly tokenHash: string; readonly expiresAt: Date }): Promise<void>;
  /** Set `revoked_at`. False when no such invitation belongs to the team. */
  revokeEmailInvitation(stackTeamId: string, id: string): Promise<boolean>;
  /** Revoke every other pending row for the same team and email. */
  revokeOtherPendingEmailInvitations(stackTeamId: string, email: string, keepId: string): Promise<void>;
  /** Delete a row whose email never went out. */
  deleteEmailInvitation(id: string): Promise<void>;
  /** Mark accepted only while pending. False when the row was no longer pending. */
  acceptEmailInvitation(id: string, userId: string): Promise<boolean>;
  /** Mark declined only while pending. */
  declineEmailInvitation(id: string): Promise<void>;
  /**
   * Drop a departing member's redemptions of the team's links. The spent uses
   * stay counted, so rejoining through a link claims a new use.
   */
  forgetLinkRedemptions(stackTeamId: string, userId: string, db?: TeamLockDb): Promise<void>;
};

/**
 * The transaction that holds a team's admin lock. Work done under the lock
 * must use it: production pools one connection, so asking the pool for a
 * second one while the lock holds the first waits forever.
 */
export type TeamLockDb = Parameters<Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]>[0];

class ClaimUnavailable extends Error {
  override readonly name = "ClaimUnavailable";
}

const linkColumns = {
  id: teamInviteLinks.id,
  stackTeamId: teamInviteLinks.stackTeamId,
  createdAt: teamInviteLinks.createdAt,
  createdByUserId: teamInviteLinks.createdByUserId,
  expiresAt: teamInviteLinks.expiresAt,
  revokedAt: teamInviteLinks.revokedAt,
  maxUses: teamInviteLinks.maxUses,
  useCount: teamInviteLinks.useCount,
};

const emailInvitationColumns = {
  id: teamEmailInvitations.id,
  stackTeamId: teamEmailInvitations.stackTeamId,
  email: teamEmailInvitations.email,
  role: teamEmailInvitations.role,
  invitedByUserId: teamEmailInvitations.invitedByUserId,
  createdAt: teamEmailInvitations.createdAt,
  lastSentAt: teamEmailInvitations.lastSentAt,
  expiresAt: teamEmailInvitations.expiresAt,
  revokedAt: teamEmailInvitations.revokedAt,
  acceptedAt: teamEmailInvitations.acceptedAt,
  acceptedByUserId: teamEmailInvitations.acceptedByUserId,
  declinedAt: teamEmailInvitations.declinedAt,
};

function pendingEmailInvitationCondition() {
  return and(
    isNull(teamEmailInvitations.revokedAt),
    isNull(teamEmailInvitations.acceptedAt),
    isNull(teamEmailInvitations.declinedAt),
    gt(teamEmailInvitations.expiresAt, sql`now()`),
  );
}

function liveLinkCondition() {
  return and(
    isNull(teamInviteLinks.revokedAt),
    or(isNull(teamInviteLinks.expiresAt), gt(teamInviteLinks.expiresAt, sql`now()`)),
  );
}

export const databaseTeamInviteStore: TeamInviteStore = {
  async upsertInviteRole(input) {
    await cloudDb()
      .insert(teamInviteRoles)
      .values({
        stackTeamId: input.stackTeamId,
        email: input.email,
        role: input.role,
        invitedByUserId: input.invitedByUserId,
      })
      .onConflictDoUpdate({
        target: [teamInviteRoles.stackTeamId, teamInviteRoles.email],
        set: {
          role: input.role,
          invitedByUserId: input.invitedByUserId,
          createdAt: sql`now()`,
          // A new send is pending; its invitation is bound once Stack lists it.
          stackInvitationId: null,
        },
      });
  },

  async inviteRoles(stackTeamId, emails) {
    if (emails.length === 0) return new Map();
    const rows = await cloudDb()
      .select({ email: teamInviteRoles.email, role: teamInviteRoles.role, stackInvitationId: teamInviteRoles.stackInvitationId })
      .from(teamInviteRoles)
      .where(and(eq(teamInviteRoles.stackTeamId, stackTeamId), inArray(teamInviteRoles.email, [...emails])));
    return new Map(rows.map((row) => [row.email, { role: row.role, stackInvitationId: row.stackInvitationId }]));
  },

  async bindInviteRoleInvitation(stackTeamId, email, stackInvitationId) {
    await cloudDb()
      .update(teamInviteRoles)
      .set({ stackInvitationId })
      .where(and(eq(teamInviteRoles.stackTeamId, stackTeamId), eq(teamInviteRoles.email, email)));
  },

  async deleteInviteRole(stackTeamId, email) {
    await cloudDb()
      .delete(teamInviteRoles)
      .where(and(eq(teamInviteRoles.stackTeamId, stackTeamId), eq(teamInviteRoles.email, email)));
  },

  async deleteTeamInviteState(stackTeamId) {
    await cloudDb().transaction(async (tx) => {
      await tx.delete(teamInviteRoles).where(eq(teamInviteRoles.stackTeamId, stackTeamId));
      await tx
        .update(teamInviteLinks)
        .set({ revokedAt: sql`now()` })
        .where(and(eq(teamInviteLinks.stackTeamId, stackTeamId), isNull(teamInviteLinks.revokedAt)));
      await tx
        .update(teamEmailInvitations)
        .set({ revokedAt: sql`now()` })
        .where(and(eq(teamEmailInvitations.stackTeamId, stackTeamId), pendingEmailInvitationCondition()));
    });
  },

  async createLink(input) {
    const [row] = await cloudDb()
      .insert(teamInviteLinks)
      .values({
        stackTeamId: input.stackTeamId,
        tokenHash: input.tokenHash,
        role: "member",
        createdByUserId: input.createdByUserId,
        expiresAt: input.expiresAt,
        maxUses: input.maxUses,
      })
      .returning(linkColumns);
    if (!row) throw new Error("team invite link insert returned no row");
    return row;
  },

  async listActiveLinks(stackTeamId) {
    return cloudDb()
      .select(linkColumns)
      .from(teamInviteLinks)
      .where(and(eq(teamInviteLinks.stackTeamId, stackTeamId), liveLinkCondition()))
      .orderBy(desc(teamInviteLinks.createdAt));
  },

  async findActiveLinkByTokenHash(tokenHash) {
    const [row] = await cloudDb()
      .select(linkColumns)
      .from(teamInviteLinks)
      .where(and(eq(teamInviteLinks.tokenHash, tokenHash), liveLinkCondition()))
      .limit(1);
    return row ?? null;
  },

  async revokeLink(stackTeamId, linkId) {
    const db = cloudDb();
    const revoked = await db
      .update(teamInviteLinks)
      .set({ revokedAt: sql`now()` })
      .where(and(
        eq(teamInviteLinks.id, linkId),
        eq(teamInviteLinks.stackTeamId, stackTeamId),
        isNull(teamInviteLinks.revokedAt),
      ))
      .returning({ id: teamInviteLinks.id });
    if (revoked.length > 0) return true;
    // Revoking twice is success; a link of another team is not found.
    const existing = await db
      .select({ id: teamInviteLinks.id })
      .from(teamInviteLinks)
      .where(and(eq(teamInviteLinks.id, linkId), eq(teamInviteLinks.stackTeamId, stackTeamId)))
      .limit(1);
    return existing.length > 0;
  },

  async claimLink(linkId, userId) {
    try {
      return await cloudDb().transaction(async (tx) => {
        const inserted = await tx
          .insert(teamInviteLinkRedemptions)
          .values({ linkId, userId })
          .onConflictDoNothing({ target: [teamInviteLinkRedemptions.linkId, teamInviteLinkRedemptions.userId] })
          .returning({ linkId: teamInviteLinkRedemptions.linkId });
        if (inserted.length === 0) return "already_redeemed" as const;
        const claimed = await tx
          .update(teamInviteLinks)
          .set({ useCount: sql`${teamInviteLinks.useCount} + 1` })
          .where(and(
            eq(teamInviteLinks.id, linkId),
            liveLinkCondition(),
            or(isNull(teamInviteLinks.maxUses), lt(teamInviteLinks.useCount, teamInviteLinks.maxUses)),
          ))
          .returning({ id: teamInviteLinks.id });
        // Throwing rolls back the redemption row inserted above.
        if (claimed.length === 0) throw new ClaimUnavailable();
        return "claimed" as const;
      });
    } catch (error) {
      if (error instanceof ClaimUnavailable) return "unavailable";
      throw error;
    }
  },

  async releaseLinkClaim(linkId, userId) {
    await cloudDb().transaction(async (tx) => {
      const deleted = await tx
        .delete(teamInviteLinkRedemptions)
        .where(and(
          eq(teamInviteLinkRedemptions.linkId, linkId),
          eq(teamInviteLinkRedemptions.userId, userId),
        ))
        .returning({ linkId: teamInviteLinkRedemptions.linkId });
      if (deleted.length === 0) return;
      await tx
        .update(teamInviteLinks)
        .set({ useCount: sql`greatest(${teamInviteLinks.useCount} - 1, 0)` })
        .where(eq(teamInviteLinks.id, linkId));
    });
  },

  async createEmailInvitation(input) {
    const [row] = await cloudDb()
      .insert(teamEmailInvitations)
      .values({
        stackTeamId: input.stackTeamId,
        email: input.email,
        role: input.role,
        invitedByUserId: input.invitedByUserId,
        tokenHash: input.tokenHash,
        expiresAt: input.expiresAt,
      })
      .returning(emailInvitationColumns);
    if (!row) throw new Error("team email invitation insert returned no row");
    return row;
  },

  async listPendingEmailInvitations(stackTeamId) {
    return cloudDb()
      .select(emailInvitationColumns)
      .from(teamEmailInvitations)
      .where(and(eq(teamEmailInvitations.stackTeamId, stackTeamId), pendingEmailInvitationCondition()))
      .orderBy(desc(teamEmailInvitations.createdAt));
  },

  async listPendingEmailInvitationsForEmails(emails) {
    if (emails.length === 0) return [];
    return cloudDb()
      .select(emailInvitationColumns)
      .from(teamEmailInvitations)
      .where(and(inArray(teamEmailInvitations.email, [...emails]), pendingEmailInvitationCondition()))
      .orderBy(desc(teamEmailInvitations.createdAt));
  },

  async findEmailInvitation(id) {
    const [row] = await cloudDb()
      .select(emailInvitationColumns)
      .from(teamEmailInvitations)
      .where(eq(teamEmailInvitations.id, id))
      .limit(1);
    return row ?? null;
  },

  async findPendingEmailInvitationByTokenHash(tokenHash) {
    const [row] = await cloudDb()
      .select(emailInvitationColumns)
      .from(teamEmailInvitations)
      .where(and(eq(teamEmailInvitations.tokenHash, tokenHash), pendingEmailInvitationCondition()))
      .limit(1);
    return row ?? null;
  },

  async refreshEmailInvitation(id, input) {
    await cloudDb()
      .update(teamEmailInvitations)
      .set({ tokenHash: input.tokenHash, expiresAt: input.expiresAt, lastSentAt: sql`now()` })
      .where(and(eq(teamEmailInvitations.id, id), pendingEmailInvitationCondition()));
  },

  async revokeEmailInvitation(stackTeamId, id) {
    const db = cloudDb();
    const revoked = await db
      .update(teamEmailInvitations)
      .set({ revokedAt: sql`now()` })
      .where(and(
        eq(teamEmailInvitations.id, id),
        eq(teamEmailInvitations.stackTeamId, stackTeamId),
        isNull(teamEmailInvitations.revokedAt),
      ))
      .returning({ id: teamEmailInvitations.id });
    if (revoked.length > 0) return true;
    const existing = await db
      .select({ id: teamEmailInvitations.id })
      .from(teamEmailInvitations)
      .where(and(eq(teamEmailInvitations.id, id), eq(teamEmailInvitations.stackTeamId, stackTeamId)))
      .limit(1);
    return existing.length > 0;
  },

  async revokeOtherPendingEmailInvitations(stackTeamId, email, keepId) {
    await cloudDb()
      .update(teamEmailInvitations)
      .set({ revokedAt: sql`now()` })
      .where(and(
        eq(teamEmailInvitations.stackTeamId, stackTeamId),
        eq(teamEmailInvitations.email, email),
        sql`${teamEmailInvitations.id} <> ${keepId}`,
        pendingEmailInvitationCondition(),
      ));
  },

  async deleteEmailInvitation(id) {
    await cloudDb().delete(teamEmailInvitations).where(eq(teamEmailInvitations.id, id));
  },

  async acceptEmailInvitation(id, userId) {
    const accepted = await cloudDb()
      .update(teamEmailInvitations)
      .set({ acceptedAt: sql`now()`, acceptedByUserId: userId })
      .where(and(eq(teamEmailInvitations.id, id), pendingEmailInvitationCondition()))
      .returning({ id: teamEmailInvitations.id });
    return accepted.length > 0;
  },

  async declineEmailInvitation(id) {
    await cloudDb()
      .update(teamEmailInvitations)
      .set({ declinedAt: sql`now()` })
      .where(and(eq(teamEmailInvitations.id, id), pendingEmailInvitationCondition()));
  },
  async forgetLinkRedemptions(stackTeamId, userId, lockDb) {
    const db = lockDb ?? cloudDb();
    await db
      .delete(teamInviteLinkRedemptions)
      .where(and(
        eq(teamInviteLinkRedemptions.userId, userId),
        inArray(
          teamInviteLinkRedemptions.linkId,
          db.select({ id: teamInviteLinks.id }).from(teamInviteLinks).where(eq(teamInviteLinks.stackTeamId, stackTeamId)),
        ),
      ));
  },
};

/**
 * Serialize admin-count changes for one team. Two admins demoting each other
 * at once would otherwise both pass the last-admin check and leave none.
 */
export async function withTeamAdminLock<T>(stackTeamId: string, operation: (db: TeamLockDb) => Promise<T>): Promise<T> {
  return cloudDb().transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`team-admin:${stackTeamId}`}, 0))`);
    return operation(tx);
  });
}
