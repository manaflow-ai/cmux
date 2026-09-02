// Operator Pro grants.
//
// A grant writes `clientReadOnlyMetadata.cmuxVmPlan`, the manual override that
// `resolveProPlanStatus` and Cloud VM entitlements already honor and that
// Stripe reconciliation never touches. Removing the grant deletes the key so
// the account falls back to its real Stripe state. Who granted what is kept in
// `serverMetadata.cmuxAdminPlanGrant`, which end users cannot read.

import { and, desc, eq, isNull } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { adminPlanGrants } from "../../db/schema";
import { getStackServerApp } from "../../app/lib/stack";
import { canonicalizeEmailForMatching } from "../billing/emailMatching";
import {
  AccountDeletionMutationBlockedError,
  AccountDeletionUserMutationInProgressError,
  type AccountDeletionUserMutationLease,
} from "../account/deletionLock";
import {
  AccountMetadataUserUnavailableError,
  type AccountMetadataUserLoader,
  withFreshAccountMetadataUser,
} from "../account/metadataMutation";
import {
  FOUNDERS_PLAN_ID,
  PRO_PLAN_ID,
  TEAM_PLAN_ID,
  isPaidPlanId,
  manualVmPlanOverride,
  metadataPlanId,
  resolveProPlanStatus,
  stripeBillingStatusForTeam,
  stripeBillingStatusForUser,
  type ProMetadataJson,
  type StripeBillingStatus,
} from "../billing/pro";

export const ADMIN_GRANTABLE_PLAN_IDS = [PRO_PLAN_ID, FOUNDERS_PLAN_ID] as const;
export type AdminGrantablePlanId = (typeof ADMIN_GRANTABLE_PLAN_IDS)[number];

export const ADMIN_USER_SEARCH_LIMIT = 25;
export const ADMIN_USER_SEARCH_MIN_QUERY_LENGTH = 2;

export type AdminStackUser = {
  readonly id: string;
  readonly primaryEmail: string | null;
  readonly primaryEmailVerified: boolean;
  readonly displayName: string | null;
  readonly isAnonymous: boolean;
  readonly signedUpAt: Date;
  readonly clientReadOnlyMetadata: unknown;
  readonly serverMetadata?: unknown;
  update(options: {
    clientReadOnlyMetadata?: ProMetadataJson;
    serverMetadata?: ProMetadataJson;
  }): Promise<unknown>;
};

export type AdminStackTeam = {
  readonly id: string;
  readonly displayName: string;
  readonly createdAt?: Date;
  readonly clientReadOnlyMetadata: unknown;
  readonly serverMetadata?: unknown;
  listUsers(): Promise<readonly { readonly id: string }[]>;
  update(options: {
    clientReadOnlyMetadata?: ProMetadataJson;
    serverMetadata?: ProMetadataJson;
  }): Promise<unknown>;
};

export type AdminStackApp = {
  getUser(userId: string): Promise<AdminStackUser | null>;
  listUsers(options: {
    query?: string;
    limit?: number;
    includeAnonymous?: boolean;
    includeRestricted?: boolean;
  }): Promise<readonly AdminStackUser[]>;
  getTeam(teamId: string): Promise<AdminStackTeam | null>;
  listTeams(options: { query?: string; limit?: number }): Promise<readonly AdminStackTeam[]>;
};

export type AdminTeamRow = {
  readonly id: string;
  readonly displayName: string;
  readonly createdAt: string | null;
  readonly memberCount: number;
  /** Effective Team access: Stripe team subscription or a paid manual grant. */
  readonly isTeam: boolean;
  readonly manualPlanId: string | null;
  readonly metadataPlanId: string | null;
  readonly stripe: {
    readonly subscriptionStatus: string | null;
    readonly cancelAtPeriodEnd: boolean;
    readonly hasActiveSubscription: boolean;
  };
  readonly lastGrant: AdminPlanGrantRecord | null;
};

export type AdminPendingGrantRow = {
  readonly id: string;
  readonly email: string;
  readonly plan: string;
  readonly grantedByEmail: string | null;
  readonly createdAt: string;
};

export type AdminPlanGrantRecord = {
  readonly plan: string | null;
  readonly byUserId: string;
  readonly byEmail: string | null;
  readonly at: string;
};

export type AdminUserRow = {
  readonly id: string;
  readonly email: string | null;
  readonly emailVerified: boolean;
  readonly displayName: string | null;
  readonly signedUpAt: string;
  /** Effective Pro access: Stripe subscription or a paid manual grant. */
  readonly isPro: boolean;
  /** Current `cmuxVmPlan` override, when set. */
  readonly manualPlanId: string | null;
  /** `cmuxPlan` mirror written from Stripe state. */
  readonly metadataPlanId: string | null;
  readonly stripe: {
    readonly subscriptionStatus: string | null;
    readonly cancelAtPeriodEnd: boolean;
    readonly hasActiveSubscription: boolean;
  };
  readonly lastGrant: AdminPlanGrantRecord | null;
};

export class AdminUserNotFoundError extends Error {
  constructor(readonly userId: string) {
    super("Stack user not found");
    this.name = "AdminUserNotFoundError";
  }
}

export class AdminGrantConflictError extends Error {
  constructor(readonly userId: string) {
    super("Another account mutation is in progress");
    this.name = "AdminGrantConflictError";
  }
}

export function isAdminGrantablePlanId(value: unknown): value is AdminGrantablePlanId {
  return typeof value === "string" &&
    (ADMIN_GRANTABLE_PLAN_IDS as readonly string[]).includes(value);
}

export async function searchAdminUsers(
  query: string,
  options: {
    readonly app?: AdminStackApp;
    readonly stripeBillingStatus?: (userId: string) => Promise<StripeBillingStatus>;
  } = {},
): Promise<AdminUserRow[]> {
  const trimmed = query.trim();
  if (trimmed.length < ADMIN_USER_SEARCH_MIN_QUERY_LENGTH) return [];
  const app = options.app ?? defaultAdminStackApp();
  const users = await app.listUsers({
    query: trimmed,
    limit: ADMIN_USER_SEARCH_LIMIT,
    includeAnonymous: false,
    includeRestricted: true,
  });
  const billing = options.stripeBillingStatus ?? stripeBillingStatusForUser;
  return await Promise.all(
    users
      .filter((user) => !user.isAnonymous)
      .map(async (user) => adminUserRow(user, await billing(user.id))),
  );
}

export async function loadAdminUser(
  userId: string,
  options: {
    readonly app?: AdminStackApp;
    readonly stripeBillingStatus?: (userId: string) => Promise<StripeBillingStatus>;
  } = {},
): Promise<AdminUserRow | null> {
  const app = options.app ?? defaultAdminStackApp();
  const user = await app.getUser(userId);
  if (!user || user.isAnonymous) return null;
  const billing = options.stripeBillingStatus ?? stripeBillingStatusForUser;
  return adminUserRow(user, await billing(user.id));
}

export function adminUserRow(
  user: AdminStackUser,
  stripe: StripeBillingStatus,
): AdminUserRow {
  const manualPlanId = manualVmPlanOverride(user.clientReadOnlyMetadata);
  return {
    id: user.id,
    email: user.primaryEmail ?? null,
    emailVerified: user.primaryEmailVerified === true,
    displayName: user.displayName ?? null,
    signedUpAt: user.signedUpAt.toISOString(),
    isPro: stripe.hasActiveSubscription || isPaidPlanId(manualPlanId),
    manualPlanId,
    metadataPlanId: metadataPlanId(user.clientReadOnlyMetadata),
    stripe: {
      subscriptionStatus: stripe.subscriptionStatus,
      cancelAtPeriodEnd: stripe.cancelAtPeriodEnd,
      hasActiveSubscription: stripe.hasActiveSubscription,
    },
    lastGrant: grantRecordFromServerMetadata(user.serverMetadata),
  };
}

export type SetManualPlanGrantInput = {
  readonly targetUserId: string;
  /** A grantable plan id, or null to remove the manual grant. */
  readonly plan: AdminGrantablePlanId | null;
  readonly admin: { readonly id: string; readonly primaryEmail?: string | null };
  readonly now?: () => Date;
  readonly app?: AdminStackApp;
  readonly withFreshUser?: FreshAdminUserMutation;
  readonly stripeBillingStatus?: (userId: string) => Promise<StripeBillingStatus>;
};

/** Reloads the user under the account-mutation lease and runs one write. */
export type FreshAdminUserMutation = <Result>(
  userId: string,
  operation: (
    user: AdminStackUser,
    lease: AccountDeletionUserMutationLease,
  ) => Promise<Result>,
) => Promise<Result>;

/**
 * Writes or clears the manual Pro grant under the account-mutation lease so
 * a concurrent billing or TestFlight metadata write cannot be clobbered, then
 * re-reads the user so `cmuxPlan` is reconciled against Stripe when the grant
 * was removed.
 */
export async function setManualPlanGrant(
  input: SetManualPlanGrantInput,
): Promise<AdminUserRow> {
  const app = input.app ?? defaultAdminStackApp();
  const withFreshUser = input.withFreshUser ?? defaultWithFreshUser(app);
  const now = input.now ?? (() => new Date());

  let mutated: AdminStackUser;
  try {
    mutated = await withFreshUser(input.targetUserId, async (user, lease) => {
      if (user.isAnonymous) throw new AdminUserNotFoundError(input.targetUserId);
      await lease.refresh();
      const client = metadataRecord(user.clientReadOnlyMetadata);
      if (input.plan === null) {
        delete client.cmuxVmPlan;
      } else {
        client.cmuxVmPlan = input.plan;
      }
      const server = metadataRecord(user.serverMetadata);
      const grant: AdminPlanGrantRecord = {
        plan: input.plan,
        byUserId: input.admin.id,
        byEmail: input.admin.primaryEmail ?? null,
        at: now().toISOString(),
      };
      server.cmuxAdminPlanGrant = grant;
      await user.update({
        clientReadOnlyMetadata: client as ProMetadataJson,
        serverMetadata: server as ProMetadataJson,
      });
      return user;
    });
  } catch (error) {
    if (error instanceof AccountMetadataUserUnavailableError) {
      throw new AdminUserNotFoundError(input.targetUserId);
    }
    if (
      error instanceof AccountDeletionMutationBlockedError ||
      error instanceof AccountDeletionUserMutationInProgressError
    ) {
      throw new AdminGrantConflictError(input.targetUserId);
    }
    throw error;
  }

  // Outside the lease: the resolver takes its own lease when it needs to
  // rewrite `cmuxPlan` after the override stopped masking Stripe state.
  const billing = input.stripeBillingStatus ?? stripeBillingStatusForUser;
  const fresh = (await app.getUser(input.targetUserId)) ?? mutated;
  await resolveProPlanStatus(fresh, {
    stripeBillingStatus: billing,
    withFreshMetadataUser: (userId, operation) =>
      withFreshUser(userId, (user, lease) => operation(user, lease)),
  });
  const reloaded = (await app.getUser(input.targetUserId)) ?? fresh;
  return adminUserRow(reloaded, await billing(reloaded.id));
}

export function grantRecordFromServerMetadata(raw: unknown): AdminPlanGrantRecord | null {
  const record = metadataRecord(raw).cmuxAdminPlanGrant;
  if (!record || typeof record !== "object" || Array.isArray(record)) return null;
  const value = record as Record<string, unknown>;
  if (typeof value.byUserId !== "string" || typeof value.at !== "string") return null;
  return {
    plan: typeof value.plan === "string" ? value.plan : null,
    byUserId: value.byUserId,
    byEmail: typeof value.byEmail === "string" ? value.byEmail : null,
    at: value.at,
  };
}

function metadataRecord(raw: unknown): Record<string, unknown> {
  return raw && typeof raw === "object" && !Array.isArray(raw)
    ? { ...(raw as Record<string, unknown>) }
    : {};
}

function defaultAdminStackApp(): AdminStackApp {
  const app = getStackServerApp();
  return {
    getUser: (userId) => app.getUser(userId),
    listUsers: (options) => app.listUsers(options),
    getTeam: (teamId) => app.getTeam(teamId),
    listTeams: (options) => app.listTeams(options),
  };
}

function defaultWithFreshUser(app: AdminStackApp): FreshAdminUserMutation {
  return async (userId, operation) => {
    const loader: AccountMetadataUserLoader<AdminStackUser> = {
      getUser: (requestedUserId) => app.getUser(requestedUserId),
    };
    return await withFreshAccountMetadataUser({
      db: cloudDb(),
      userId,
      loader,
      operation: async (user, lease) => await operation(user, lease),
    });
  };
}

// ---------------------------------------------------------------------------
// Teams

export async function searchAdminTeams(
  query: string,
  options: {
    readonly app?: AdminStackApp;
    readonly stripeBillingStatus?: (teamId: string) => Promise<StripeBillingStatus>;
  } = {},
): Promise<AdminTeamRow[]> {
  const trimmed = query.trim();
  if (trimmed.length < ADMIN_USER_SEARCH_MIN_QUERY_LENGTH) return [];
  const app = options.app ?? defaultAdminStackApp();
  const teams = await app.listTeams({ query: trimmed, limit: ADMIN_USER_SEARCH_LIMIT });
  const billing = options.stripeBillingStatus ?? stripeBillingStatusForTeam;
  return await Promise.all(
    teams.map(async (team) => adminTeamRow(team, await billing(team.id), await memberCount(team))),
  );
}

async function memberCount(team: AdminStackTeam): Promise<number> {
  try {
    return (await team.listUsers()).length;
  } catch {
    return 0;
  }
}

export function adminTeamRow(
  team: AdminStackTeam,
  stripe: StripeBillingStatus,
  members: number,
): AdminTeamRow {
  const manualPlanId = manualVmPlanOverride(team.clientReadOnlyMetadata);
  return {
    id: team.id,
    displayName: team.displayName,
    createdAt: team.createdAt ? team.createdAt.toISOString() : null,
    memberCount: members,
    isTeam: stripe.hasActiveSubscription || isPaidPlanId(manualPlanId),
    manualPlanId,
    metadataPlanId: metadataPlanId(team.clientReadOnlyMetadata),
    stripe: {
      subscriptionStatus: stripe.subscriptionStatus,
      cancelAtPeriodEnd: stripe.cancelAtPeriodEnd,
      hasActiveSubscription: stripe.hasActiveSubscription,
    },
    lastGrant: grantRecordFromServerMetadata(team.serverMetadata),
  };
}

export class AdminTeamNotFoundError extends Error {
  constructor(readonly teamId: string) {
    super("Stack team not found");
    this.name = "AdminTeamNotFoundError";
  }
}

/**
 * Writes or clears the team's `cmuxVmPlan` override. A paid team override
 * gives every member the Team plan through billing team resolution, the same
 * way a Stripe Team subscription writes `cmuxPlan: "team"`.
 */
export async function setTeamManualPlanGrant(input: {
  readonly teamId: string;
  readonly plan: typeof TEAM_PLAN_ID | null;
  readonly admin: { readonly id: string; readonly primaryEmail?: string | null };
  readonly now?: () => Date;
  readonly app?: AdminStackApp;
  readonly stripeBillingStatus?: (teamId: string) => Promise<StripeBillingStatus>;
}): Promise<AdminTeamRow> {
  const app = input.app ?? defaultAdminStackApp();
  const now = input.now ?? (() => new Date());
  const team = await app.getTeam(input.teamId);
  if (!team) throw new AdminTeamNotFoundError(input.teamId);
  const client = metadataRecord(team.clientReadOnlyMetadata);
  if (input.plan === null) {
    delete client.cmuxVmPlan;
  } else {
    client.cmuxVmPlan = input.plan;
  }
  const server = metadataRecord(team.serverMetadata);
  const grant: AdminPlanGrantRecord = {
    plan: input.plan,
    byUserId: input.admin.id,
    byEmail: input.admin.primaryEmail ?? null,
    at: now().toISOString(),
  };
  server.cmuxAdminPlanGrant = grant;
  await team.update({
    clientReadOnlyMetadata: client as ProMetadataJson,
    serverMetadata: server as ProMetadataJson,
  });
  const reloaded = (await app.getTeam(input.teamId)) ?? team;
  const billing = input.stripeBillingStatus ?? stripeBillingStatusForTeam;
  return adminTeamRow(reloaded, await billing(reloaded.id), await memberCount(reloaded));
}

// ---------------------------------------------------------------------------
// Pending grants for emails without a Stack user yet

export type AdminGrantsDb = Pick<ReturnType<typeof cloudDb>, "select" | "insert" | "update">;

export function isPlausibleEmail(value: string): boolean {
  const trimmed = value.trim();
  if (trimmed.length < 3 || trimmed.length > 254) return false;
  if (!/^[\x21-\x7e]+$/.test(trimmed)) return false;
  const at = trimmed.lastIndexOf("@");
  if (at <= 0 || at === trimmed.length - 1) return false;
  return /^[a-z0-9.-]+\.[a-z]{2,}$/i.test(trimmed.slice(at + 1));
}

export async function listPendingEmailGrants(
  query: string,
  options: { readonly db?: AdminGrantsDb } = {},
): Promise<AdminPendingGrantRow[]> {
  const trimmed = query.trim().toLowerCase();
  if (trimmed.length < ADMIN_USER_SEARCH_MIN_QUERY_LENGTH) return [];
  const db = options.db ?? cloudDb();
  const rows = await db
    .select({
      id: adminPlanGrants.id,
      email: adminPlanGrants.email,
      plan: adminPlanGrants.plan,
      grantedByEmail: adminPlanGrants.grantedByEmail,
      createdAt: adminPlanGrants.createdAt,
    })
    .from(adminPlanGrants)
    .where(and(isNull(adminPlanGrants.appliedAt), isNull(adminPlanGrants.revokedAt)))
    .orderBy(desc(adminPlanGrants.createdAt))
    .limit(200);
  return rows
    .filter((row) => row.email.includes(trimmed))
    .slice(0, ADMIN_USER_SEARCH_LIMIT)
    .map((row) => ({
      id: row.id,
      email: row.email,
      plan: row.plan,
      grantedByEmail: row.grantedByEmail ?? null,
      createdAt: row.createdAt.toISOString(),
    }));
}

export async function createPendingEmailGrant(input: {
  readonly email: string;
  readonly plan: AdminGrantablePlanId;
  readonly admin: { readonly id: string; readonly primaryEmail?: string | null };
  readonly db?: AdminGrantsDb;
}): Promise<AdminPendingGrantRow> {
  if (!isPlausibleEmail(input.email)) {
    throw new AdminInvalidEmailError(input.email);
  }
  const db = input.db ?? cloudDb();
  const email = canonicalizeEmailForMatching(input.email);
  const [row] = await db
    .insert(adminPlanGrants)
    .values({
      email,
      plan: input.plan,
      grantedByUserId: input.admin.id,
      grantedByEmail: input.admin.primaryEmail ?? null,
    })
    .returning({
      id: adminPlanGrants.id,
      email: adminPlanGrants.email,
      plan: adminPlanGrants.plan,
      grantedByEmail: adminPlanGrants.grantedByEmail,
      createdAt: adminPlanGrants.createdAt,
    });
  if (!row) throw new Error("admin_plan_grants insert returned no row");
  return {
    id: row.id,
    email: row.email,
    plan: row.plan,
    grantedByEmail: row.grantedByEmail ?? null,
    createdAt: row.createdAt.toISOString(),
  };
}

/**
 * True when Postgres reports the admin_plan_grants relation missing (42P01),
 * i.e. the deployment has not run the migration yet. drizzle wraps pg errors,
 * so the code is read from `cause` as well as the error itself.
 */
export function isMissingGrantsTableError(error: unknown): boolean {
  const seen = new Set<unknown>();
  let current: unknown = error;
  while (current && typeof current === "object" && !seen.has(current)) {
    seen.add(current);
    const record = current as { code?: unknown; message?: unknown; cause?: unknown };
    if (record.code === "42P01") return true;
    if (typeof record.message === "string" && /relation "?admin_plan_grants"? does not exist/.test(record.message)) {
      return true;
    }
    current = record.cause;
  }
  return false;
}

export class AdminInvalidEmailError extends Error {
  constructor(readonly email: string) {
    super("Not a plausible email address");
    this.name = "AdminInvalidEmailError";
  }
}

export async function revokePendingEmailGrant(input: {
  readonly grantId: string;
  readonly db?: AdminGrantsDb;
}): Promise<void> {
  const db = input.db ?? cloudDb();
  await db
    .update(adminPlanGrants)
    .set({ revokedAt: new Date() })
    .where(and(eq(adminPlanGrants.id, input.grantId), isNull(adminPlanGrants.appliedAt)));
}

/**
 * Applies every open grant addressed to the user's verified primary email.
 * Called from the after-sign-in callback, which only runs it once Stack
 * reports the mailbox verified. The newest grant wins when several are open.
 */
export async function applyPendingEmailGrants(
  user: { readonly id: string; readonly primaryEmail?: string | null },
  options: {
    readonly db?: AdminGrantsDb;
    readonly grant?: (input: SetManualPlanGrantInput) => Promise<unknown>;
  } = {},
): Promise<number> {
  if (!user.primaryEmail) return 0;
  const db = options.db ?? cloudDb();
  const email = canonicalizeEmailForMatching(user.primaryEmail);
  let rows: Array<{
    id: string;
    plan: string;
    grantedByUserId: string;
    grantedByEmail: string | null;
  }>;
  try {
    rows = await openGrantsForEmail(db, email);
  } catch (error) {
    // No table yet (migration pending) or no database: nothing to apply.
    if (isMissingGrantsTableError(error) || isMissingDatabaseConfigError(error)) return 0;
    throw error;
  }
  if (rows.length === 0) return 0;
  const newest = rows[0]!;
  if (isAdminGrantablePlanId(newest.plan)) {
    await (options.grant ?? setManualPlanGrant)({
      targetUserId: user.id,
      plan: newest.plan,
      admin: { id: newest.grantedByUserId, primaryEmail: newest.grantedByEmail },
    });
  }
  const appliedAt = new Date();
  for (const row of rows) {
    await db
      .update(adminPlanGrants)
      .set({ appliedAt, appliedUserId: user.id })
      .where(eq(adminPlanGrants.id, row.id));
  }
  return rows.length;
}

function isMissingDatabaseConfigError(error: unknown): boolean {
  return error instanceof Error && /DATABASE_URL is required/.test(error.message);
}

async function openGrantsForEmail(db: AdminGrantsDb, email: string) {
  return await db
    .select({
      id: adminPlanGrants.id,
      plan: adminPlanGrants.plan,
      grantedByUserId: adminPlanGrants.grantedByUserId,
      grantedByEmail: adminPlanGrants.grantedByEmail,
    })
    .from(adminPlanGrants)
    .where(
      and(
        eq(adminPlanGrants.email, email),
        isNull(adminPlanGrants.appliedAt),
        isNull(adminPlanGrants.revokedAt),
      ),
    )
    .orderBy(desc(adminPlanGrants.createdAt))
    .limit(20);
}
