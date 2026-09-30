import { and, desc, eq, gt, inArray, isNull, lt, or, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import {
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

export type LinkClaimResult = "claimed" | "already_redeemed" | "unavailable";

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
  inviteRoles(stackTeamId: string, emails: readonly string[]): Promise<Map<string, TeamRole>>;
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
  /**
   * Drop a departing member's redemptions of the team's links. The spent uses
   * stay counted, so rejoining through a link claims a new use.
   */
  forgetLinkRedemptions(stackTeamId: string, userId: string): Promise<void>;
};

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
        },
      });
  },

  async inviteRoles(stackTeamId, emails) {
    if (emails.length === 0) return new Map();
    const rows = await cloudDb()
      .select({ email: teamInviteRoles.email, role: teamInviteRoles.role })
      .from(teamInviteRoles)
      .where(and(eq(teamInviteRoles.stackTeamId, stackTeamId), inArray(teamInviteRoles.email, [...emails])));
    return new Map(rows.map((row) => [row.email, row.role]));
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

  async forgetLinkRedemptions(stackTeamId, userId) {
    const db = cloudDb();
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
export async function withTeamAdminLock<T>(stackTeamId: string, operation: () => Promise<T>): Promise<T> {
  return cloudDb().transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`team-admin:${stackTeamId}`}, 0))`);
    return operation();
  });
}
