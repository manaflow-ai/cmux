import { and, eq, inArray, isNotNull, notInArray, sql } from "drizzle-orm";
import type { cloudDb } from "../../../db/client";
import {
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
  readonly reconcileUser: (userId: string, read: () => Promise<HexclaveUserState>) => Promise<UserReconcileResult>;
  readonly reconcileTeam: (
    teamId: string,
    read: () => Promise<HexclaveServerTeam | null>,
  ) => Promise<TeamReconcileResult>;
  /** Every user and team id the mirror holds, for the backfill's prune pass. */
  readonly listMirroredIds: () => Promise<{ readonly userIds: readonly string[]; readonly teamIds: readonly string[] }>;
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
  await tx.delete(hexclaveTombstones).where(and(eq(hexclaveTombstones.entityType, "user"), eq(hexclaveTombstones.entityId, userId)));
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

async function mirrorTeamIdsForUser(tx: Tx, userId: string): Promise<string[]> {
  const rows = await tx
    .select({ teamId: hexclaveTeamMemberships.teamId })
    .from(hexclaveTeamMemberships)
    .where(eq(hexclaveTeamMemberships.userId, userId));
  return rows.map((row) => row.teamId);
}

export function createDrizzleHexclaveMirrorStore(db: () => Db, now: () => Date = () => new Date()): HexclaveMirrorStore {
  return {
    reconcileUser: (userId, read) => db().transaction(async (tx) => {
      await lock(tx, userLockKey(userId));
      const state = await read();
      if (state.kind === "present" && state.user.id !== userId) throw new Error("Hexclave returned a different user");
      const previousTeamIds = await mirrorTeamIdsForUser(tx, userId);
      const sourceTeamIds = state.kind === "present" ? state.teams.map((team) => team.id) : [];
      for (const teamId of [...new Set([...previousTeamIds, ...sourceTeamIds])].sort()) {
        await lock(tx, teamLockKey(teamId));
      }
      const at = now();
      if (state.kind === "gone") {
        await writeGoneUser(tx, userId, at);
        return { state, previousTeamIds, currentTeamIds: [] };
      }
      const currentTeamIds = await writePresentUser(tx, state, at);
      return { state, previousTeamIds, currentTeamIds };
    }),

    reconcileTeam: (teamId, read) => db().transaction(async (tx) => {
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
      await tx.delete(hexclaveTombstones).where(and(eq(hexclaveTombstones.entityType, "team"), eq(hexclaveTombstones.entityId, teamId)));
      await tx.insert(hexclaveTeams).values(teamRow(team, at)).onConflictDoUpdate({ target: hexclaveTeams.id, set: excludedTeam });
      return { team, memberIds };
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
