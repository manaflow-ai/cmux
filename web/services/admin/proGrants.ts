// Operator Pro grants.
//
// A grant writes `clientReadOnlyMetadata.cmuxVmPlan`, the manual override that
// `resolveProPlanStatus` and Cloud VM entitlements already honor and that
// Stripe reconciliation never touches. Removing the grant deletes the key so
// the account falls back to its real Stripe state. Who granted what is kept in
// `serverMetadata.cmuxAdminPlanGrant`, which end users cannot read.

import { cloudDb } from "../../db/client";
import { getStackServerApp } from "../../app/lib/stack";
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
  isPaidPlanId,
  manualVmPlanOverride,
  metadataPlanId,
  resolveProPlanStatus,
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

export type AdminStackApp = {
  getUser(userId: string): Promise<AdminStackUser | null>;
  listUsers(options: {
    query?: string;
    limit?: number;
    includeAnonymous?: boolean;
    includeRestricted?: boolean;
  }): Promise<readonly AdminStackUser[]>;
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
