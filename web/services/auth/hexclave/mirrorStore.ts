import { and, eq, gte, inArray, isNotNull, notInArray, sql } from "drizzle-orm";
import type { cloudDb } from "../../../db/client";
import {
  hexclavePendingRevocations,
  hexclaveProjectPermissions,
  hexclaveTeamMemberships,
  hexclaveTeamPermissions,
  hexclaveTeams,
  hexclaveTombstones,
  hexclaveUsers,
  hexclaveWebhookEvents,
  type HexclaveWebhookOutcome,
} from "../../../db/schema";
import type {
  HexclaveProjectPermission,
  HexclaveServerTeam,
  HexclaveServerUser,
  HexclaveTeamPermission,
} from "./serverApi";

/** What Hexclave says about one user right now. */
export type HexclaveUserState =
  | { readonly kind: "gone" }
  | {
    readonly kind: "present";
    readonly user: HexclaveServerUser;
    readonly teams: readonly HexclaveServerTeam[];
    readonly teamPermissions: readonly HexclaveTeamPermission[];
    readonly projectPermissions: readonly HexclaveProjectPermission[];
  };

export type UserReconcileResult = {
  readonly state: HexclaveUserState;
  /** Teams the mirror listed for the user before this reconcile. */
  readonly previousTeamIds: readonly string[];
  /** Teams the mirror lists for the user after it (empty when gone). */
  readonly currentTeamIds: readonly string[];
  /**
   * Every team whose membership revocation is pending for this user after the
   * reconcile, persisted in its transaction: earlier pending rows, mirror
   * memberships this reconcile removed, and candidates the event named, minus
   * teams the user is (again) a member of.
   */
  readonly pendingRevocationTeamIds: readonly string[];
};

export type TeamReconcileResult = {
  readonly team: HexclaveServerTeam | null;
  /** Mirror members of the team before this reconcile. */
  readonly memberIds: readonly string[];
};

/**
 * The mirror's write side.
 *
 * `reconcileUser` / `reconcileTeam` call `read` while holding that entity's
 * lock and apply its answer in the same transaction, so two reconciles of one
 * entity are serialized and the one that read last writes last. Svix gives no
 * ordering, so this, not event order, is what keeps the mirror equal to the
 * source of truth.
 */
export type HexclaveMirrorStore = {
  readonly reconcileUser: (
    userId: string,
    read: () => Promise<HexclaveUserState>,
    options?: { readonly revokeCandidateTeamIds?: readonly string[] },
  ) => Promise<UserReconcileResult>;
  /** Whether the revocation is still pending (a re-add since the reconcile clears it). */
  readonly isRevocationPending: (input: { readonly teamId: string; readonly userId: string }) => Promise<boolean>;
  /** Delete a pending revocation after its revoke succeeded. */
  readonly clearPendingRevocation: (input: { readonly teamId: string; readonly userId: string }) => Promise<void>;
  readonly reconcileTeam: (
    teamId: string,
    read: () => Promise<HexclaveServerTeam | null>,
  ) => Promise<TeamReconcileResult>;
  /** Every user and team id the mirror holds, for the backfill's prune pass. */
  readonly listMirroredIds: () => Promise<{ readonly userIds: readonly string[]; readonly teamIds: readonly string[] }>;
  /**
   * Backfill writes from a bulk snapshot read before the lock. Each skips the
   * entity (returns false) when the mirror wrote it, or tombstoned it, at or
   * after `snapshotStartedAt`: that write came from a fresher read.
   */
  readonly applySnapshotTeam: (team: HexclaveServerTeam, snapshotStartedAt: Date) => Promise<boolean>;
  readonly applySnapshotUser: (
    state: Extract<HexclaveUserState, { kind: "present" }>,
    snapshotStartedAt: Date,
  ) => Promise<boolean>;
  readonly isEventProcessed: (svixId: string) => Promise<boolean>;
  readonly recordEvent: (input: {
    readonly svixId: string;
    readonly eventType: string;
    readonly outcome: HexclaveWebhookOutcome;
  }) => Promise<void>;
};

type Db = ReturnType<typeof cloudDb>;
type Tx = Parameters<Parameters<Db["transaction"]>[0]>[0];

/**
 * Lock order: a user lock, then team locks in sorted order. Team reconciles
 * take only their team lock, so no two transactions wait on each other in a
 * cycle.
 */
async function lock(tx: Tx, key: string): Promise<void> {
  await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${key}, 0))`);
}

const userLockKey = (userId: string) => `hexclave:user:${userId}`;
const teamLockKey = (teamId: string) => `hexclave:team:${teamId}`;

export function userRow(user: HexclaveServerUser, now: Date): typeof hexclaveUsers.$inferInsert {
  return {
    id: user.id,
    primaryEmail: user.primary_email,
    displayName: user.display_name,
    isAnonymous: user.is_anonymous,
    clientReadOnlyMetadata: user.client_read_only_metadata ?? null,
    signedUpAt: new Date(user.signed_up_at_millis),
    syncedAt: now,
    raw: user,
  };
}

export function teamRow(team: HexclaveServerTeam, now: Date): typeof hexclaveTeams.$inferInsert {
  return {
    id: team.id,
    displayName: team.display_name,
    clientReadOnlyMetadata: team.client_read_only_metadata ?? null,
    createdAt: new Date(team.created_at_millis),
    syncedAt: now,
    raw: team,
  };
}

const excludedUser = {
  primaryEmail: sql`excluded.primary_email`,
  displayName: sql`excluded.display_name`,
  isAnonymous: sql`excluded.is_anonymous`,
  clientReadOnlyMetadata: sql`excluded.client_read_only_metadata`,
  signedUpAt: sql`excluded.signed_up_at`,
  syncedAt: sql`excluded.synced_at`,
  raw: sql`excluded.raw`,
};

const excludedTeam = {
  displayName: sql`excluded.display_name`,
  clientReadOnlyMetadata: sql`excluded.client_read_only_metadata`,
  createdAt: sql`excluded.created_at`,
  syncedAt: sql`excluded.synced_at`,
  raw: sql`excluded.raw`,
};

async function tombstonedTeamIds(tx: Tx, teamIds: readonly string[]): Promise<Set<string>> {
  if (teamIds.length === 0) return new Set();
  const rows = await tx
    .select({ id: hexclaveTombstones.entityId })
    .from(hexclaveTombstones)
    .where(and(eq(hexclaveTombstones.entityType, "team"), inArray(hexclaveTombstones.entityId, [...teamIds])));
  return new Set(rows.map((row) => row.id));
}

async function writeGoneUser(tx: Tx, userId: string, now: Date): Promise<void> {
  await tx.insert(hexclaveTombstones).values({ entityType: "user", entityId: userId, deletedAt: now }).onConflictDoNothing();
  // Memberships and permissions go with the row (ON DELETE CASCADE).
  await tx.delete(hexclaveUsers).where(eq(hexclaveUsers.id, userId));
}

async function writeUserMemberships(tx: Tx, userId: string, teamIds: readonly string[], now: Date): Promise<void> {
  await tx.delete(hexclaveTeamMemberships).where(and(
    eq(hexclaveTeamMemberships.userId, userId),
    teamIds.length > 0 ? notInArray(hexclaveTeamMemberships.teamId, [...teamIds]) : undefined,
  ));
  if (teamIds.length === 0) return;
  await tx
    .insert(hexclaveTeamMemberships)
    .values(teamIds.map((teamId) => ({ teamId, userId, syncedAt: now })))
    .onConflictDoUpdate({
      target: [hexclaveTeamMemberships.teamId, hexclaveTeamMemberships.userId],
      set: { syncedAt: sql`excluded.synced_at` },
    });
}

async function writeUserTeamPermissions(
  tx: Tx,
  userId: string,
  permissions: readonly HexclaveTeamPermission[],
  liveTeams: ReadonlySet<string>,
  now: Date,
): Promise<void> {
  // A permission without its membership cannot exist in Hexclave; the FK makes
  // the mirror agree, so drop one that a concurrent change left behind.
  const rows = permissions
    .filter((permission) => permission.user_id === userId && liveTeams.has(permission.team_id))
    .map((permission) => ({ teamId: permission.team_id, userId, permissionId: permission.id, syncedAt: now }));
  await tx.delete(hexclaveTeamPermissions).where(eq(hexclaveTeamPermissions.userId, userId));
  if (rows.length > 0) await tx.insert(hexclaveTeamPermissions).values(rows).onConflictDoNothing();
}

async function writeUserProjectPermissions(
  tx: Tx,
  userId: string,
  permissions: readonly HexclaveProjectPermission[],
  now: Date,
): Promise<void> {
  const ids = [...new Set(permissions.filter((permission) => permission.user_id === userId).map((permission) => permission.id))];
  await tx.delete(hexclaveProjectPermissions).where(eq(hexclaveProjectPermissions.userId, userId));
  if (ids.length > 0) {
    await tx.insert(hexclaveProjectPermissions).values(ids.map((permissionId) => ({ userId, permissionId, syncedAt: now })));
  }
}

async function writePresentUser(
  tx: Tx,
  state: Extract<HexclaveUserState, { kind: "present" }>,
  now: Date,
): Promise<readonly string[]> {
  const userId = state.user.id;
  await tx.insert(hexclaveUsers).values(userRow(state.user, now)).onConflictDoUpdate({ target: hexclaveUsers.id, set: excludedUser });

  const tombstoned = await tombstonedTeamIds(tx, state.teams.map((team) => team.id));
  const liveTeams = state.teams.filter((team) => !tombstoned.has(team.id));
  if (liveTeams.length > 0) {
    // Insert-only: the team row's content is owned by the team reconcile, whose
    // read is fresher than this listing. This only satisfies the membership FK.
    await tx.insert(hexclaveTeams).values(liveTeams.map((team) => teamRow(team, now))).onConflictDoNothing();
  }
  const liveTeamIds = liveTeams.map((team) => team.id);
  await writeUserMemberships(tx, userId, liveTeamIds, now);
  await writeUserTeamPermissions(tx, userId, state.teamPermissions, new Set(liveTeamIds), now);
  await writeUserProjectPermissions(tx, userId, state.projectPermissions, now);
  return liveTeamIds;
}

/**
 * Persist the user's pending revocations in the reconcile transaction:
 * (existing ∪ previous ∪ candidates) − current. A team the user belongs to
 * again loses its pending row, so a stale revoke never runs.
 */
async function writePendingRevocations(
  tx: Tx,
  userId: string,
  input: { readonly previousTeamIds: readonly string[]; readonly currentTeamIds: readonly string[]; readonly candidates: readonly string[] },
): Promise<string[]> {
  const existing = await tx
    .select({ teamId: hexclavePendingRevocations.teamId })
    .from(hexclavePendingRevocations)
    .where(eq(hexclavePendingRevocations.userId, userId));
  const current = new Set(input.currentTeamIds);
  const pending = [...new Set([...existing.map((row) => row.teamId), ...input.previousTeamIds, ...input.candidates])]
    .filter((teamId) => !current.has(teamId))
    .sort();
  if (input.currentTeamIds.length > 0) {
    await tx.delete(hexclavePendingRevocations).where(and(
      eq(hexclavePendingRevocations.userId, userId),
      inArray(hexclavePendingRevocations.teamId, [...input.currentTeamIds]),
    ));
  }
  if (pending.length > 0) {
    await tx.insert(hexclavePendingRevocations).values(pending.map((teamId) => ({ teamId, userId }))).onConflictDoNothing();
  }
  return pending;
}

/** Fail fast instead of queueing webhooks behind a stuck reconcile; Svix retries the 5xx. */
async function boundLockWait(tx: Tx): Promise<void> {
  await tx.execute(sql`set local lock_timeout = '10s'`);
}

async function lockUserAndTeams(tx: Tx, userId: string, sourceTeamIds: readonly string[]): Promise<string[]> {
  await lock(tx, userLockKey(userId));
  const previousTeamIds = await mirrorTeamIdsForUser(tx, userId);
  for (const teamId of [...new Set([...previousTeamIds, ...sourceTeamIds])].sort()) {
    await lock(tx, teamLockKey(teamId));
  }
  return previousTeamIds;
}

/** True when the mirror wrote or tombstoned this entity at or after `since`. */
async function writtenSince(
  tx: Tx,
  entity: "user" | "team",
  id: string,
  since: Date,
): Promise<boolean> {
  const table = entity === "user" ? hexclaveUsers : hexclaveTeams;
  const rows = await tx
    .select({ id: table.id })
    .from(table)
    .where(and(eq(table.id, id), gte(table.syncedAt, since)))
    .limit(1);
  if (rows.length > 0) return true;
  const tombstones = await tx
    .select({ id: hexclaveTombstones.entityId })
    .from(hexclaveTombstones)
    .where(and(
      eq(hexclaveTombstones.entityType, entity),
      eq(hexclaveTombstones.entityId, id),
      gte(hexclaveTombstones.deletedAt, since),
    ))
    .limit(1);
  return tombstones.length > 0;
}

async function isTombstoned(tx: Tx, entity: "user" | "team", id: string): Promise<boolean> {
  const rows = await tx
    .select({ id: hexclaveTombstones.entityId })
    .from(hexclaveTombstones)
    .where(and(eq(hexclaveTombstones.entityType, entity), eq(hexclaveTombstones.entityId, id)))
    .limit(1);
  return rows.length > 0;
}

/**
 * Upsert a team unless it is tombstoned. Tombstones are permanent (ids are
 * never reused), so a later "present" answer from a lagging replica cannot
 * bring a deleted team back.
 */
async function writePresentTeam(tx: Tx, team: HexclaveServerTeam, at: Date): Promise<boolean> {
  if (await isTombstoned(tx, "team", team.id)) return false;
  await tx.insert(hexclaveTeams).values(teamRow(team, at)).onConflictDoUpdate({ target: hexclaveTeams.id, set: excludedTeam });
  return true;
}

async function mirrorTeamIdsForUser(tx: Tx, userId: string): Promise<string[]> {
  const rows = await tx
    .select({ teamId: hexclaveTeamMemberships.teamId })
    .from(hexclaveTeamMemberships)
    .where(eq(hexclaveTeamMemberships.userId, userId));
  return rows.map((row) => row.teamId);
}

export function createDrizzleHexclaveMirrorStore(db: () => Db, now: () => Date = () => new Date()): HexclaveMirrorStore {
  return {
    reconcileUser: (userId, read, options = {}) => db().transaction(async (tx) => {
      await boundLockWait(tx);
      await lock(tx, userLockKey(userId));
      const fetched = await read();
      if (fetched.kind === "present" && fetched.user.id !== userId) throw new Error("Hexclave returned a different user");
      // A tombstoned user stays gone: a "present" read after a confirmed deletion is stale.
      const state: HexclaveUserState = fetched.kind === "present" && await isTombstoned(tx, "user", userId) ? { kind: "gone" } : fetched;
      const sourceTeamIds = state.kind === "present" ? state.teams.map((team) => team.id) : [];
      // Re-entrant: the user lock is already held by this transaction.
      const previousTeamIds = await lockUserAndTeams(tx, userId, sourceTeamIds);
      const at = now();
      let currentTeamIds: readonly string[] = [];
      if (state.kind === "gone") await writeGoneUser(tx, userId, at);
      else currentTeamIds = await writePresentUser(tx, state, at);
      const pendingRevocationTeamIds = await writePendingRevocations(tx, userId, {
        previousTeamIds,
        currentTeamIds,
        candidates: options.revokeCandidateTeamIds ?? [],
      });
      return { state, previousTeamIds, currentTeamIds, pendingRevocationTeamIds };
    }),

    isRevocationPending: async ({ teamId, userId }) => {
      const rows = await db()
        .select({ teamId: hexclavePendingRevocations.teamId })
        .from(hexclavePendingRevocations)
        .where(and(eq(hexclavePendingRevocations.teamId, teamId), eq(hexclavePendingRevocations.userId, userId)))
        .limit(1);
      return rows.length > 0;
    },

    clearPendingRevocation: async ({ teamId, userId }) => {
      await db().delete(hexclavePendingRevocations).where(and(
        eq(hexclavePendingRevocations.teamId, teamId),
        eq(hexclavePendingRevocations.userId, userId),
      ));
    },

    reconcileTeam: (teamId, read) => db().transaction(async (tx) => {
      await boundLockWait(tx);
      await lock(tx, teamLockKey(teamId));
      const team = await read();
      if (team && team.id !== teamId) throw new Error("Hexclave returned a different team");
      const members = await tx
        .select({ userId: hexclaveTeamMemberships.userId })
        .from(hexclaveTeamMemberships)
        .where(eq(hexclaveTeamMemberships.teamId, teamId));
      const memberIds = members.map((row) => row.userId);
      const at = now();
      if (!team) {
        await tx.insert(hexclaveTombstones).values({ entityType: "team", entityId: teamId, deletedAt: at }).onConflictDoNothing();
        await tx.delete(hexclaveTeams).where(eq(hexclaveTeams.id, teamId));
        return { team: null, memberIds };
      }
      if (!await writePresentTeam(tx, team, at)) return { team: null, memberIds };
      return { team, memberIds };
    }),

    applySnapshotTeam: (team, snapshotStartedAt) => db().transaction(async (tx) => {
      await boundLockWait(tx);
      await lock(tx, teamLockKey(team.id));
      if (await writtenSince(tx, "team", team.id, snapshotStartedAt)) return false;
      return writePresentTeam(tx, team, now());
    }),

    applySnapshotUser: (state, snapshotStartedAt) => db().transaction(async (tx) => {
      await boundLockWait(tx);
      const previousTeamIds = await lockUserAndTeams(tx, state.user.id, state.teams.map((team) => team.id));
      if (await writtenSince(tx, "user", state.user.id, snapshotStartedAt)) return false;
      if (await isTombstoned(tx, "user", state.user.id)) return false;
      const currentTeamIds = await writePresentUser(tx, state, now());
      // The backfill does not revoke, but a removal it finds is queued for the
      // next webhook sync of this user.
      await writePendingRevocations(tx, state.user.id, { previousTeamIds, currentTeamIds, candidates: [] });
      return true;
    }),

    listMirroredIds: async () => {
      const [users, teams] = await Promise.all([
        db().select({ id: hexclaveUsers.id }).from(hexclaveUsers),
        db().select({ id: hexclaveTeams.id }).from(hexclaveTeams),
      ]);
      return { userIds: users.map((row) => row.id), teamIds: teams.map((row) => row.id) };
    },

    isEventProcessed: async (svixId) => {
      const rows = await db()
        .select({ svixId: hexclaveWebhookEvents.svixId })
        .from(hexclaveWebhookEvents)
        .where(and(eq(hexclaveWebhookEvents.svixId, svixId), isNotNull(hexclaveWebhookEvents.processedAt)))
        .limit(1);
      return rows.length > 0;
    },

    recordEvent: async ({ svixId, eventType, outcome }) => {
      const at = now();
      const processedAt = outcome === "processed" || outcome === "ignored" ? at : null;
      await db()
        .insert(hexclaveWebhookEvents)
        .values({ svixId, eventType, outcome, receivedAt: at, processedAt })
        .onConflictDoUpdate({
          target: hexclaveWebhookEvents.svixId,
          set: {
            // A processed id stays processed; a later failed duplicate cannot undo it.
            outcome: sql`case when ${hexclaveWebhookEvents.processedAt} is null then excluded.outcome else ${hexclaveWebhookEvents.outcome} end`,
            processedAt: sql`coalesce(${hexclaveWebhookEvents.processedAt}, excluded.processed_at)`,
            attempts: sql`${hexclaveWebhookEvents.attempts} + 1`,
          },
        });
    },
  };
}
