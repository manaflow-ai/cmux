// Operator Pro grants.
//
// A grant writes `clientReadOnlyMetadata.cmuxVmPlan`, the manual override that
// `resolveProPlanStatus` and Cloud VM entitlements already honor and that
// Stripe reconciliation never touches. Removing the grant deletes the key so
// the account falls back to its real Stripe state. Who granted what is kept in
// `serverMetadata.cmuxAdminPlanGrant`, which end users cannot read.

import { and, desc, eq, ilike, inArray, isNotNull, isNull, lt, or } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { adminPlanGrants } from "../../db/schema";
import { getStackServerApp } from "../../app/lib/stack";
import { canonicalizeEmailForMatching } from "../billing/emailMatching";
import { isPlainEmailLocalPart } from "./access";
import {
  AccountDeletionMutationBlockedError,
  AccountDeletionUserMutationInProgressError,
  withAccountDeletionUserMutation,
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
  hasActiveTeamSubscriptionForTeam,
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
  /** Null when member listing failed. */
  readonly memberCount: number | null;
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
  /** Set when the grant was applied from a pending email grant row. */
  readonly pendingGrantId?: string | null;
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
  /**
   * Only write when the user's current override and audit record match this
   * grant. Used when unwinding a pending email grant so an unrelated manual
   * grant on the same account is left alone.
   */
  readonly onlyIfCurrent?: {
    readonly plan: string;
    readonly byUserId: string;
    /** Required to equal the audit record's pendingGrantId (null matches a direct grant). */
    readonly pendingGrantId: string | null;
  };
  /** Recorded in the audit record when applying a pending email grant. */
  readonly pendingGrantId?: string;
  /**
   * Skip the write when the account's audit record is newer than this
   * instant. Used when applying a pending email grant so it never overwrites
   * a later direct admin decision on the same account.
   */
  readonly unlessAuditNewerThan?: Date;
  /**
   * After a direct admin write on a verified account, revoke open pending
   * grants for the same email so an older pending grant cannot undo it.
   * Defaults to true for direct writes; pending-grant application passes
   * false.
   */
  readonly supersedePending?: boolean;
  readonly grantsDb?: AdminGrantsDb;
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
  let wrote = false;
  try {
    mutated = await withFreshUser(input.targetUserId, async (user, lease) => {
      if (user.isAnonymous) throw new AdminUserNotFoundError(input.targetUserId);
      if (input.onlyIfCurrent) {
        const currentPlan = manualVmPlanOverride(user.clientReadOnlyMetadata);
        const audit = grantRecordFromServerMetadata(user.serverMetadata);
        if (
          currentPlan !== input.onlyIfCurrent.plan.toLowerCase() ||
          audit?.byUserId !== input.onlyIfCurrent.byUserId ||
          (audit?.pendingGrantId ?? null) !== input.onlyIfCurrent.pendingGrantId
        ) {
          return user;
        }
      }
      if (input.unlessAuditNewerThan) {
        const audit = grantRecordFromServerMetadata(user.serverMetadata);
        const auditAt = audit ? Date.parse(audit.at) : Number.NaN;
        if (!Number.isNaN(auditAt) && auditAt > input.unlessAuditNewerThan.getTime()) {
          return user;
        }
      }
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
        pendingGrantId: input.pendingGrantId ?? null,
      };
      server.cmuxAdminPlanGrant = grant;
      await user.update({
        clientReadOnlyMetadata: client as ProMetadataJson,
        serverMetadata: server as ProMetadataJson,
      });
      wrote = true;
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

  // A direct admin decision on a verified account supersedes any older
  // pending grant addressed to that mailbox; otherwise the pending grant would
  // re-apply at the next sign-in and silently undo this write.
  if (wrote && input.supersedePending !== false && mutated.primaryEmailVerified && mutated.primaryEmail) {
    await supersedeOpenGrantsForEmail(mutated.primaryEmail, mutated.id, input.grantsDb);
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
    pendingGrantId: typeof value.pendingGrantId === "string" ? value.pendingGrantId : null,
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

/** Null when the provider could not list members; the UI then blocks a Team grant. */
async function memberCount(team: AdminStackTeam): Promise<number | null> {
  try {
    return (await team.listUsers()).length;
  } catch {
    return null;
  }
}

export function adminTeamRow(
  team: AdminStackTeam,
  stripe: StripeBillingStatus,
  members: number | null,
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

/** Reloads the team under a metadata-mutation lease and runs one write. */
export type FreshAdminTeamMutation = <Result>(
  teamId: string,
  operation: (
    team: AdminStackTeam,
    lease: AccountDeletionUserMutationLease,
  ) => Promise<Result>,
) => Promise<Result>;

/**
 * Writes or clears the team's `cmuxVmPlan` override. A paid team override
 * gives every member the Team plan through billing team resolution, the same
 * way a Stripe Team subscription writes `cmuxPlan: "team"`.
 *
 * The write runs under the shared account-mutation lease keyed by the team
 * id, and the team is re-read inside it, so two admins cannot clobber each
 * other's metadata. In the same write the `cmuxPlan` mirror is reconciled
 * against the live Stripe team subscription, so removing a grant from a team
 * whose subscription lapsed leaves no stale paid mirror behind.
 */
export async function setTeamManualPlanGrant(input: {
  readonly teamId: string;
  readonly plan: typeof TEAM_PLAN_ID | null;
  readonly admin: { readonly id: string; readonly primaryEmail?: string | null };
  readonly now?: () => Date;
  readonly app?: AdminStackApp;
  readonly withFreshTeam?: FreshAdminTeamMutation;
  readonly hasActiveTeamSubscription?: (teamId: string) => Promise<boolean>;
  readonly stripeBillingStatus?: (teamId: string) => Promise<StripeBillingStatus>;
}): Promise<AdminTeamRow> {
  const app = input.app ?? defaultAdminStackApp();
  const now = input.now ?? (() => new Date());
  const withFreshTeam = input.withFreshTeam ?? defaultWithFreshTeam(app);
  const hasStripeTeam = input.hasActiveTeamSubscription ?? hasActiveTeamSubscriptionForTeam;

  try {
    await withFreshTeam(input.teamId, async (team, lease) => {
      const stripeActive = await hasStripeTeam(team.id);
      await lease.refresh();
      const client = metadataRecord(team.clientReadOnlyMetadata);
      if (input.plan === null) {
        delete client.cmuxVmPlan;
      } else {
        client.cmuxVmPlan = input.plan;
      }
      // Mirror reconciliation, like syncTeamPlanMetadata but clearing any
      // stale paid value: entitlements treat pro, team, and founders alike.
      if (stripeActive) {
        client.cmuxPlan = TEAM_PLAN_ID;
      } else if (isPaidPlanId(typeof client.cmuxPlan === "string" ? client.cmuxPlan : null)) {
        delete client.cmuxPlan;
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
    });
  } catch (error) {
    if (error instanceof AdminTeamNotFoundError) throw error;
    if (
      error instanceof AccountDeletionMutationBlockedError ||
      error instanceof AccountDeletionUserMutationInProgressError
    ) {
      throw new AdminGrantConflictError(input.teamId);
    }
    throw error;
  }

  const reloaded = await app.getTeam(input.teamId);
  if (!reloaded) throw new AdminTeamNotFoundError(input.teamId);
  const billing = input.stripeBillingStatus ?? stripeBillingStatusForTeam;
  return adminTeamRow(reloaded, await billing(reloaded.id), await memberCount(reloaded));
}

/** Team lease key. Teams share the account-mutation lease table under a prefixed id. */
function teamMutationKey(teamId: string): string {
  return `team:${teamId}`;
}

function defaultWithFreshTeam(app: AdminStackApp): FreshAdminTeamMutation {
  return async (teamId, operation) =>
    await withAccountDeletionUserMutation(cloudDb(), teamMutationKey(teamId), async (lease) => {
      const team = await app.getTeam(teamId);
      if (!team || team.id !== teamId) throw new AdminTeamNotFoundError(teamId);
      return await operation(team, lease);
    });
}

// ---------------------------------------------------------------------------
// Pending grants for emails without a Stack user yet

export type AdminGrantsDb = Pick<ReturnType<typeof cloudDb>, "select" | "insert" | "update"> & {
  transaction<Result>(
    operation: (tx: Pick<ReturnType<typeof cloudDb>, "select" | "insert" | "update">) => Promise<Result>,
  ): Promise<Result>;
};

export function isPlausibleEmail(value: string): boolean {
  const trimmed = value.trim();
  if (trimmed.length < 3 || trimmed.length > 254) return false;
  const at = trimmed.lastIndexOf("@");
  if (at <= 0 || at === trimmed.length - 1) return false;
  if (!isPlainEmailLocalPart(trimmed.slice(0, at))) return false;
  return /^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$/i.test(trimmed.slice(at + 1));
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
    .where(
      and(
        isNull(adminPlanGrants.appliedAt),
        isNull(adminPlanGrants.revokedAt),
        ilike(adminPlanGrants.email, `%${escapeLikePattern(trimmed)}%`),
      ),
    )
    .orderBy(desc(adminPlanGrants.createdAt))
    .limit(ADMIN_USER_SEARCH_LIMIT);
  return rows.map((row) => ({
    id: row.id,
    email: row.email,
    plan: row.plan,
    grantedByEmail: row.grantedByEmail ?? null,
    createdAt: row.createdAt.toISOString(),
  }));
}

function escapeLikePattern(value: string): string {
  return value.replace(/[\\%_]/g, (char) => `\\${char}`);
}

export type CreatePendingEmailGrantResult = AdminPendingGrantRow & {
  /**
   * Accounts whose superseded grant could not be cleared right now. The
   * clear is retried at that user's next sign-in; an admin can also use
   * "Remove grant" on the user row immediately. Never empty silently: the
   * route reports it and the UI shows it.
   */
  readonly unclearedUserIds: readonly string[];
};

export async function createPendingEmailGrant(input: {
  readonly email: string;
  readonly plan: AdminGrantablePlanId;
  readonly admin: { readonly id: string; readonly primaryEmail?: string | null };
  readonly db?: AdminGrantsDb;
  readonly grant?: (input: SetManualPlanGrantInput) => Promise<unknown>;
}): Promise<CreatePendingEmailGrantResult> {
  if (!isPlausibleEmail(input.email)) {
    throw new AdminInvalidEmailError(input.email);
  }
  const db = input.db ?? cloudDb();
  const email = canonicalizeEmailForMatching(input.email);
  // One open grant per email: a new grant supersedes any earlier open one, so
  // sign-in never has more than one row to apply and the newest plan wins.
  // Supersede and insert commit together, and the partial unique index on
  // open emails makes a concurrent second grant fail instead of leaving two
  // open rows. A superseded row that a sign-in had claimed may already have
  // written metadata; that grant is cleared after the commit through the
  // conditional clear, and if the clear fails the row keeps its claim marker
  // so the user's next sign-in retries it (retryRevokedGrantCleanup).
  const { row, superseded } = await db.transaction(async (tx) => {
    const supersededRows = await tx
      .update(adminPlanGrants)
      .set({ revokedAt: new Date() })
      .where(
        and(
          eq(adminPlanGrants.email, email),
          isNull(adminPlanGrants.appliedAt),
          isNull(adminPlanGrants.revokedAt),
        ),
      )
      .returning({
        id: adminPlanGrants.id,
        plan: adminPlanGrants.plan,
        appliedUserId: adminPlanGrants.appliedUserId,
        grantedByUserId: adminPlanGrants.grantedByUserId,
        grantedByEmail: adminPlanGrants.grantedByEmail,
      });
    const [inserted] = await tx
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
    return { row: inserted, superseded: supersededRows };
  });
  const unclearedUserIds: string[] = [];
  for (const old of superseded) {
    if (!old.appliedUserId) continue;
    try {
      await (input.grant ?? setManualPlanGrant)({
        targetUserId: old.appliedUserId,
        plan: null,
        admin: input.admin,
        onlyIfCurrent: { plan: old.plan, byUserId: old.grantedByUserId, pendingGrantId: old.id },
        supersedePending: false,
      });
      await db
        .update(adminPlanGrants)
        .set({ appliedUserId: null, claimedAt: null })
        .where(eq(adminPlanGrants.id, old.id));
    } catch (error) {
      if (error instanceof AdminUserNotFoundError) continue;
      console.error("admin.pending_grants.supersede_clear_failed", {
        grantId: old.id,
        failure: error instanceof Error ? error.name : "unknown",
      });
      unclearedUserIds.push(old.appliedUserId);
    }
  }
  if (!row) throw new Error("admin_plan_grants insert returned no row");
  return {
    id: row.id,
    email: row.email,
    plan: row.plan,
    grantedByEmail: row.grantedByEmail ?? null,
    createdAt: row.createdAt.toISOString(),
    unclearedUserIds,
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

/**
 * Revokes open pending grants for an email that are unclaimed or claimed by
 * the given user. Rows claimed by another user are left for that sign-in.
 * Tolerates a missing database or table.
 */
async function supersedeOpenGrantsForEmail(
  rawEmail: string,
  userId: string,
  grantsDb?: AdminGrantsDb,
): Promise<void> {
  const email = canonicalizeEmailForMatching(rawEmail);
  try {
    const db = grantsDb ?? cloudDb();
    await db
      .update(adminPlanGrants)
      .set({ revokedAt: new Date() })
      .where(
        and(
          eq(adminPlanGrants.email, email),
          isNull(adminPlanGrants.appliedAt),
          isNull(adminPlanGrants.revokedAt),
          or(isNull(adminPlanGrants.appliedUserId), eq(adminPlanGrants.appliedUserId, userId)),
        ),
      );
  } catch (error) {
    if (isMissingGrantsTableError(error) || isMissingDatabaseConfigError(error)) return;
    throw error;
  }
}

/** A claim older than this is treated as abandoned and may be re-claimed. */
export const ADMIN_GRANT_CLAIM_TTL_MS = 10 * 60 * 1000;

/**
 * Revokes an open grant. If a sign-in had claimed the row but never finalized
 * it (process or database failure after the metadata write), the claimer's
 * manual grant is removed as well, but only when that grant is the one this
 * row produced (same plan, same granting admin in the audit record), so an
 * unrelated manual grant on the account is left alone.
 *
 * The row is revoked first so an in-flight apply cannot finalize it. If the
 * metadata clear then fails, the revoke is undone (best effort) and the
 * error propagates, so the row stays open and the admin can retry.
 */
export async function revokePendingEmailGrant(input: {
  readonly grantId: string;
  readonly db?: AdminGrantsDb;
  readonly admin?: { readonly id: string; readonly primaryEmail?: string | null };
  readonly grant?: (input: SetManualPlanGrantInput) => Promise<unknown>;
}): Promise<{ readonly revoked: boolean; readonly clearedUserId: string | null }> {
  const db = input.db ?? cloudDb();
  const rows = await db
    .update(adminPlanGrants)
    .set({ revokedAt: new Date() })
    .where(
      and(
        eq(adminPlanGrants.id, input.grantId),
        isNull(adminPlanGrants.appliedAt),
        isNull(adminPlanGrants.revokedAt),
      ),
    )
    .returning({
      id: adminPlanGrants.id,
      plan: adminPlanGrants.plan,
      appliedUserId: adminPlanGrants.appliedUserId,
      grantedByUserId: adminPlanGrants.grantedByUserId,
      grantedByEmail: adminPlanGrants.grantedByEmail,
    });
  const row = rows[0];
  if (!row) return { revoked: false, clearedUserId: null };
  if (!row.appliedUserId) return { revoked: true, clearedUserId: null };
  try {
    await (input.grant ?? setManualPlanGrant)({
      targetUserId: row.appliedUserId,
      plan: null,
      admin: input.admin ?? { id: row.grantedByUserId, primaryEmail: row.grantedByEmail },
      onlyIfCurrent: { plan: row.plan, byUserId: row.grantedByUserId, pendingGrantId: row.id },
      supersedePending: false,
    });
  } catch (error) {
    if (!(error instanceof AdminUserNotFoundError)) {
      await db
        .update(adminPlanGrants)
        .set({ revokedAt: null })
        .where(and(eq(adminPlanGrants.id, row.id), isNull(adminPlanGrants.appliedAt)))
        .catch(() => undefined);
      throw error;
    }
  }
  await db
    .update(adminPlanGrants)
    .set({ appliedUserId: null, claimedAt: null })
    .where(eq(adminPlanGrants.id, row.id));
  return { revoked: true, clearedUserId: row.appliedUserId };
}

/**
 * Applies every open grant addressed to the user's verified primary email.
 * Called from the after-sign-in callback, which only runs it once Stack
 * reports the mailbox verified. The newest grant wins when several are open.
 *
 * Work is bounded: createPendingEmailGrant keeps at most one open row per
 * email, and claim, finalize, and release are each a single statement.
 *
 * Protocol, so that a revoke always wins until the grant is durably applied:
 * 1. claim: set applied_user_id and claimed_at on open rows that are
 *    unclaimed, claimed by this same user, or whose claim is older than
 *    ADMIN_GRANT_CLAIM_TTL_MS (applied_at stays NULL, so the rows still count
 *    as pending and can still be revoked);
 * 2. write the metadata grant for the newest claimed row;
 * 3. finalize: set applied_at on claimed rows that are still unrevoked;
 * 4. if the applied row was revoked during 2, remove the grant again.
 * A failed write releases the claim; a crash mid-way leaves a claim that the
 * same user's next sign-in, or anyone after the TTL, picks up again. The
 * metadata write is idempotent, so a retry after a crash is safe.
 */
export async function applyPendingEmailGrants(
  user: { readonly id: string; readonly primaryEmail?: string | null },
  options: {
    readonly db?: AdminGrantsDb;
    readonly grant?: (input: SetManualPlanGrantInput) => Promise<unknown>;
    readonly now?: () => Date;
  } = {},
): Promise<number> {
  if (!user.primaryEmail) return 0;
  const db = options.db ?? cloudDb();
  const grant = options.grant ?? setManualPlanGrant;
  const now = options.now ?? (() => new Date());
  const email = canonicalizeEmailForMatching(user.primaryEmail);
  try {
    await retryRevokedGrantCleanup(db, email, user.id, grant);
  } catch (error) {
    if (isMissingGrantsTableError(error) || isMissingDatabaseConfigError(error)) return 0;
    throw error;
  }
  const claimedAt = now();
  const staleBefore = new Date(claimedAt.getTime() - ADMIN_GRANT_CLAIM_TTL_MS);
  let claimed: Array<{
    id: string;
    plan: string;
    grantedByUserId: string;
    grantedByEmail: string | null;
    createdAt: Date;
  }>;
  try {
    claimed = await db
      .update(adminPlanGrants)
      .set({ appliedUserId: user.id, claimedAt })
      .where(
        and(
          eq(adminPlanGrants.email, email),
          isNull(adminPlanGrants.appliedAt),
          isNull(adminPlanGrants.revokedAt),
          or(
            isNull(adminPlanGrants.appliedUserId),
            eq(adminPlanGrants.appliedUserId, user.id),
            isNull(adminPlanGrants.claimedAt),
            lt(adminPlanGrants.claimedAt, staleBefore),
          ),
        ),
      )
      .returning({
        id: adminPlanGrants.id,
        plan: adminPlanGrants.plan,
        grantedByUserId: adminPlanGrants.grantedByUserId,
        grantedByEmail: adminPlanGrants.grantedByEmail,
        createdAt: adminPlanGrants.createdAt,
      });
  } catch (error) {
    // No table yet (migration pending) or no database: nothing to apply.
    if (isMissingGrantsTableError(error) || isMissingDatabaseConfigError(error)) return 0;
    throw error;
  }
  if (claimed.length === 0) return 0;
  const claimedIds = claimed.map((row) => row.id);
  const releaseClaims = async () => {
    await db
      .update(adminPlanGrants)
      .set({ appliedUserId: null, claimedAt: null })
      .where(and(inArray(adminPlanGrants.id, claimedIds), isNull(adminPlanGrants.appliedAt)))
      .catch(() => undefined);
  };

  const newest = [...claimed].sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime())[0]!;
  const plan = isAdminGrantablePlanId(newest.plan) ? newest.plan : null;
  if (plan !== null) {
    try {
      await grant({
        targetUserId: user.id,
        plan,
        admin: { id: newest.grantedByUserId, primaryEmail: newest.grantedByEmail },
        // A direct admin decision made after this grant was created wins.
        unlessAuditNewerThan: newest.createdAt,
        supersedePending: false,
        pendingGrantId: newest.id,
      });
    } catch (error) {
      await releaseClaims();
      throw error;
    }
  }

  // Finalize only rows this sign-in still owns: a claim stolen after the TTL
  // belongs to that later sign-in, which finalizes (or compensates) itself.
  const done = await db
    .update(adminPlanGrants)
    .set({ appliedAt: now() })
    .where(
      and(
        inArray(adminPlanGrants.id, claimedIds),
        eq(adminPlanGrants.appliedUserId, user.id),
        isNull(adminPlanGrants.appliedAt),
        isNull(adminPlanGrants.revokedAt),
      ),
    )
    .returning({ id: adminPlanGrants.id });
  const finalized = new Set(done.map((row) => row.id));
  if (plan !== null && !finalized.has(newest.id)) {
    // Not ours to keep: either revoked while the write was in flight (the
    // revoke wins), or the claim was taken over after the TTL by a later
    // sign-in for the same email (that sign-in owns the grant now). Either
    // way remove exactly the grant this row produced. This does not depend
    // on the claim marker, which a concurrent revoke may already have
    // cleared before our write landed.
    const revoked = await wasRevoked(db, newest.id);
    try {
      await grant({
        targetUserId: user.id,
        plan: null,
        admin: { id: newest.grantedByUserId, primaryEmail: newest.grantedByEmail },
        onlyIfCurrent: { plan: newest.plan, byUserId: newest.grantedByUserId, pendingGrantId: newest.id },
        supersedePending: false,
      });
    } catch (error) {
      // For a revoked row, put the marker back so retryRevokedGrantCleanup
      // retries at this user's next sign-in. A taken-over row belongs to the
      // other sign-in; do not steal its marker back.
      if (revoked) {
        await db
          .update(adminPlanGrants)
          .set({ appliedUserId: user.id, claimedAt: now() })
          .where(and(eq(adminPlanGrants.id, newest.id), isNull(adminPlanGrants.appliedAt)))
          .catch(() => undefined);
      }
      throw error;
    }
    if (revoked) {
      await db
        .update(adminPlanGrants)
        .set({ appliedUserId: null, claimedAt: null })
        .where(eq(adminPlanGrants.id, newest.id));
    }
  }
  return finalized.size;
}

async function wasRevoked(db: AdminGrantsDb, grantId: string): Promise<boolean> {
  const rows = await db
    .select({ id: adminPlanGrants.id })
    .from(adminPlanGrants)
    .where(
      and(
        eq(adminPlanGrants.id, grantId),
        isNull(adminPlanGrants.appliedAt),
        isNotNull(adminPlanGrants.revokedAt),
      ),
    )
    .orderBy(desc(adminPlanGrants.createdAt))
    .limit(1);
  return rows.length > 0;
}

/**
 * Durable cleanup for the revoke/apply race: a revoked row that still carries
 * applied_user_id (and no applied_at) means a grant was written for that user
 * and the compensating clear did not complete. Retry it here, on the user's
 * own sign-in, and release the marker once the clear succeeds.
 */
async function retryRevokedGrantCleanup(
  db: AdminGrantsDb,
  email: string,
  userId: string,
  grant: (input: SetManualPlanGrantInput) => Promise<unknown>,
): Promise<void> {
  const dangling = await db
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
        isNotNull(adminPlanGrants.revokedAt),
        isNull(adminPlanGrants.appliedAt),
        eq(adminPlanGrants.appliedUserId, userId),
      ),
    )
    .orderBy(desc(adminPlanGrants.createdAt))
    .limit(ADMIN_USER_SEARCH_LIMIT);
  for (const row of dangling) {
    await grant({
      targetUserId: userId,
      plan: null,
      admin: { id: row.grantedByUserId, primaryEmail: row.grantedByEmail },
      onlyIfCurrent: { plan: row.plan, byUserId: row.grantedByUserId, pendingGrantId: row.id },
      supersedePending: false,
    });
    await db
      .update(adminPlanGrants)
      .set({ appliedUserId: null, claimedAt: null })
      .where(eq(adminPlanGrants.id, row.id));
  }
}

function isMissingDatabaseConfigError(error: unknown): boolean {
  return error instanceof Error && /DATABASE_URL is required/.test(error.message);
}

