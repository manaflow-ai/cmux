import { and, asc, desc, eq, isNull, or, sql } from "drizzle-orm";
import type Stripe from "stripe";

import { stackServerApp } from "../../app/lib/stack";
import { cloudDb } from "../../db/client";
import {
  accountDeletionTombstones,
  billingEmailClaims,
  stripeCustomers,
  stripeSubscriptions,
} from "../../db/schema";
import {
  type AccountDeletionUserMutationLease,
  accountDeletionAdvisoryLockKey,
  accountDeletionUserHash,
  isBlockingAccountDeletionTombstone,
} from "../account/deletionLock";
import {
  type AccountMetadataUserLoader,
  withFreshAccountMetadataUser,
} from "../account/metadataMutation";
import {
  PRO_PLAN_ID,
  type ProMetadataJson,
  TEAM_PLAN_ID,
  syncProPlanMetadata,
  syncTeamPlanMetadata,
} from "./pro";
import { stripe } from "./stripe";
import { isAscConfigured } from "../asc/client";
import {
  removeProTesterAccess,
  removeTester,
  type RemoveTesterOptions,
} from "../asc/testflight";
import { captureAscError } from "../errors";

export const ACTIVE_STRIPE_SUBSCRIPTION_STATUSES = new Set([
  "active",
  "trialing",
  "past_due",
]);
const DELETED_ACCOUNT_ACTOR_ID = "deleted-account";

type BillingDb = ReturnType<typeof cloudDb>;
type BillingDbClient = Pick<BillingDb, "select" | "insert" | "update">;
type BillingDbTransaction = BillingDbClient & {
  execute(query: unknown): Promise<unknown>;
};
type StripeBillingClient = Pick<ReturnType<typeof stripe>, "customers" | "subscriptions">;

/** A Stack account that may prove ownership of a parked Pro checkout. */
export type ProBillingClaimUser = {
  readonly id: string;
  readonly primaryEmail?: string | null;
  readonly primaryEmailVerified?: boolean;
  readonly isAnonymous?: boolean;
  readonly isRestricted?: boolean;
};

export type BillingOwnershipClaim = {
  readonly id: string;
  readonly email: string;
  readonly stripeCustomerId: string;
  readonly stackUserId: string;
  readonly claimedByUserId: string | null;
};

export type BillingOwnershipTransfer = {
  readonly kind: "claimed";
  readonly claimId: string;
  readonly email: string;
  readonly customerId: string;
  readonly subscriptionIds: readonly string[];
  readonly sourceStackUserId: string;
  readonly targetStackUserId: string;
};

export type BillingOwnershipRepository = {
  findClaims: (
    email: string,
    targetStackUserId: string,
  ) => Promise<readonly BillingOwnershipClaim[]>;
  transferClaim: (
    claim: BillingOwnershipClaim,
    targetStackUserId: string,
  ) => Promise<BillingOwnershipTransfer | null>;
};

type StripeSubscriptionValuesInput = {
  subscription: Stripe.Subscription;
  customerId: string;
  stackUserId: string;
  stackTeamId?: string | null;
  scope: "user" | "team";
};

type StackBillingUser = {
  readonly id: string;
  readonly primaryEmail?: string | null;
  readonly primaryEmailVerified?: boolean;
  readonly isAnonymous?: boolean;
  readonly isRestricted?: boolean;
  readonly clientReadOnlyMetadata?: unknown;
  update(options: {
    primaryEmail?: string | null;
    primaryEmailAuthEnabled?: boolean;
    clientReadOnlyMetadata?: unknown;
  }): Promise<unknown>;
};

type StackBillingUserLookup = {
  readonly id: string;
  readonly primaryEmail?: string | null;
};

type StackBillingTeam = {
  readonly id: string;
  readonly clientReadOnlyMetadata?: unknown;
  update(options: {
    clientReadOnlyMetadata: ProMetadataJson;
  }): Promise<unknown>;
};

type StackBillingApp = {
  getUser(id: string): Promise<StackBillingUser | null>;
  listUsers?(options?: {
    query?: string;
    limit?: number;
    includeAnonymous?: boolean;
    includeRestricted?: boolean;
  }): Promise<readonly StackBillingUserLookup[]>;
  getTeam?(id: string): Promise<StackBillingTeam | null>;
};

type BillingPurchaseDependencies = {
  db?: BillingDb;
  stackApp?: StackBillingApp | null;
  stripeClient?: () => StripeBillingClient;
  ownershipRepository?: BillingOwnershipRepository;
  testflight?: {
    isAscConfigured?: () => boolean;
    removeTester?: (
      email: string,
      options?: RemoveTesterOptions,
    ) => Promise<void>;
    captureAscError?: (
      error: unknown,
      context?: Record<string, string | number | boolean | null | undefined>,
    ) => void;
  };
};

/**
 * Attach a parked anonymous Pro checkout to the currently authenticated
 * account. A claim is usable only when Stack itself says the account is
 * non-anonymous and its primary email is verified. The email is merely the
 * selector for a server-created claim; it is never accepted as proof on its
 * own.
 *
 * The database transfer is transactional and keyed by the exact claim and
 * Stripe ids. Stripe metadata is reconciled after the transfer so a webhook
 * cannot grant access to an account selected only by an unverified email.
 */
export async function claimPendingProBilling(
  user: ProBillingClaimUser,
  dependencies: BillingPurchaseDependencies = {},
): Promise<{ readonly claimed: number }> {
  const email = verifiedClaimEmail(user);
  if (!email) return { claimed: 0 };

  const app = dependencies.stackApp ?? stackServerApp;
  if (!app) return { claimed: 0 };
  const db = dependencies.db ?? cloudDb();
  const repository =
    dependencies.ownershipRepository ?? makeBillingOwnershipRepository(db);
  const claims = await repository.findClaims(email, user.id);
  let claimed = 0;

  for (const claim of claims) {
    if (claim.claimedByUserId && claim.claimedByUserId !== user.id) continue;

    // A fresh claim must originate from the anonymous purchaser created by
    // checkout. Never transfer a claim from an ordinary account, even when its
    // billing email happens to match.
    if (!claim.claimedByUserId) {
      const source = await app.getUser(claim.stackUserId);
      if (
        !source ||
        source.id === user.id ||
        source.isAnonymous !== true
      ) {
        continue;
      }
    }

    const transfer = await repository.transferClaim(claim, user.id);
    if (!transfer) continue;
    claimed += 1;
    await syncTransferredStripeOwnership(
      transfer,
      dependencies.stripeClient ?? stripe,
    );
  }

  return { claimed };
}

export type CheckoutCompletionInput = {
  session: Stripe.Checkout.Session;
  subscription?: Stripe.Subscription | null;
  customer?: Stripe.Customer | Stripe.DeletedCustomer | null;
};

type CheckoutCompletionResult =
  | { scope: "user"; stackUserId: string; subscriptionId: string }
  | { scope: "team"; stackTeamId: string; subscriptionId: string }
  | { skipped: "account_deletion_in_progress"; stackUserId: string; subscriptionId: string };

type UserCheckoutPostCommitSync = {
  user: StackBillingUser;
  email: string | null;
  stripeCustomerId: string;
  stackUserId: string;
  stackApp: StackBillingApp | null | undefined;
};

type CheckoutCompletionLockedResult = {
  result: CheckoutCompletionResult;
  checkoutCleanup?: {
    deleteCustomer: boolean;
  };
  postCommitUserSync?: UserCheckoutPostCommitSync;
  postCommitTeamSync?: {
    stackTeamId: string;
    stackApp: StackBillingApp | null | undefined;
  };
};

export async function recordCheckoutCompletion(
  input: CheckoutCompletionInput,
  dependencies: BillingPurchaseDependencies = {},
): Promise<CheckoutCompletionResult> {
  const subscription = input.subscription ?? expandedSubscription(input.session);
  if (!subscription) {
    throw new Error("Stripe checkout session is missing an expanded subscription");
  }
  const customerId = customerIdFromSession(input.session, input.customer);
  if (!customerId) {
    throw new Error("Stripe checkout session is missing a customer id");
  }
  const teamScope = teamScopeFromSession(input.session, subscription);
  if (teamScope) {
    return recordTeamCheckoutCompletion({
      subscription,
      customerId,
      stackTeamId: teamScope.stackTeamId,
      stackUserId: teamScope.stackUserId,
      dependencies,
    });
  }

  const stackUserId = stackUserIdFromSession(input.session, subscription);
  if (!stackUserId) {
    throw new Error("Stripe checkout session is missing stackUserId");
  }

  const db = dependencies.db ?? cloudDb();
  const user = await loadOptionalStackUser(stackUserId, dependencies.stackApp);
  const lockedResult = await withAccountDeletionUserLock(
    db,
    stackUserId,
    async (tx): Promise<CheckoutCompletionLockedResult> => {
      if (
        await hasCheckoutBlockingAccountDeletionTombstone(stackUserId, tx) ||
        (user && isAccountDeletionInProgress(user))
      ) {
        return {
          checkoutCleanup: { deleteCustomer: true },
          result: {
            skipped: "account_deletion_in_progress",
            stackUserId,
            subscriptionId: subscription.id,
          },
        };
      }
      if (!user) throw new Error(`Stack user not found for checkout completion: ${stackUserId}`);

      const email = checkoutEmail(input.session, input.customer);
      await upsertStripeCustomer(tx, {
        customerId,
        stackUserId,
        email,
      });
      await upsertStripeSubscription(tx, {
        subscription,
        customerId,
        stackUserId,
        scope: "user",
      });

      return {
        postCommitUserSync: {
          user,
          email,
          stripeCustomerId: customerId,
          stackUserId,
          stackApp: dependencies.stackApp ?? stackServerApp,
        },
        result: { scope: "user", stackUserId, subscriptionId: subscription.id },
      };
    },
  );

  if (lockedResult.checkoutCleanup) {
    await cleanupCheckoutStripeResourcesForAccountDeletion({
      subscription,
      customerId,
      dependencies,
      deleteCustomer: lockedResult.checkoutCleanup.deleteCustomer,
    });
  }
  if (lockedResult.postCommitUserSync) {
    await syncUserCheckoutAfterCommit(db, lockedResult.postCommitUserSync);
  }

  return lockedResult.result;
}

async function syncUserCheckoutAfterCommit(
  db: BillingDb,
  input: UserCheckoutPostCommitSync,
): Promise<void> {
  await syncStackUserMetadataWithAccountDeletionGuard({
    db,
    stackUserId: input.stackUserId,
    stackApp: input.stackApp,
    sync: async (user, mutationLease) => {
      if (input.email) {
        await attachPurchaseEmailOrRecordClaim(db, {
          user,
          email: input.email,
          stripeCustomerId: input.stripeCustomerId,
          stackUserId: input.stackUserId,
          stackApp: input.stackApp,
        }, mutationLease);
      }
      await syncProPlanMetadata(user, true, mutationLease);
    },
  });
}

async function cleanupCheckoutStripeResourcesForAccountDeletion(input: {
  subscription: Stripe.Subscription;
  customerId: string;
  dependencies: BillingPurchaseDependencies;
  deleteCustomer: boolean;
}): Promise<void> {
  const { subscription, customerId, dependencies } = input;
  const client = (dependencies.stripeClient ?? stripe)();
  await cancelCheckoutSubscription(client, subscription.id);
  if (!input.deleteCustomer) return;
  try {
    await client.customers.del(customerId);
  } catch (error) {
    if (isStripeCustomerAlreadyDeletedError(error)) return;
    throw error;
  }
}

async function cancelCheckoutSubscription(
  client: Pick<ReturnType<typeof stripe>, "subscriptions">,
  subscriptionId: string,
): Promise<void> {
  try {
    await client.subscriptions.cancel(subscriptionId);
  } catch (error) {
    if (!isStripeSubscriptionAlreadyCanceledError(error)) throw error;
  }
}

export async function applySubscriptionUpdate(
  subscription: Stripe.Subscription,
  dependencies: BillingPurchaseDependencies = {},
): Promise<
  | { scope: "user"; stackUserId: string; isActive: boolean }
  | { scope: "team"; stackTeamId: string; isActive: boolean }
  | { skipped: true }
> {
  if (subscription.metadata?.app !== "cmux") return { skipped: true };

  const db = dependencies.db ?? cloudDb();
  const customerId = customerIdFromSubscription(subscription);
  if (!customerId) return { skipped: true };

  const teamScope = teamScopeFromSubscription(subscription);
  if (teamScope) {
    const metadataStackUserId = nonEmptyString(subscription.metadata?.stackUserId);
    const mappedStackUserId = await stackUserIdForTeamStripeCustomer(db, {
      stackTeamId: teamScope.stackTeamId,
      customerId,
    });
    if (mappedStackUserId === DELETED_ACCOUNT_ACTOR_ID) return { skipped: true };
    if (
      metadataStackUserId &&
      mappedStackUserId &&
      metadataStackUserId !== mappedStackUserId
    ) return { skipped: true };
    const stackUserId = mappedStackUserId ?? metadataStackUserId;
    if (!stackUserId || stackUserId === DELETED_ACCOUNT_ACTOR_ID) return { skipped: true };
    const isActive = isActiveStripeSubscriptionStatus(subscription.status);
    const ownerStackUserId = teamSubscriptionOwnerStackUserId(stackUserId, teamScope.stackTeamId);
    const legacyTeamScopedOwner = stackUserId === teamScope.stackTeamId;
    if (!ownerStackUserId && !legacyTeamScopedOwner) return { skipped: true };

    const applyTeamUpdate = async (
      tx: BillingDbClient,
      expectedOwner:
        | { kind: "user"; stackUserId: string }
        | { kind: "legacy-team" },
    ): Promise<
        | { skipped: true }
        | { scope: "team"; stackTeamId: string; isActive: boolean }
      > => {
        const transactionMappedStackUserId = await stackUserIdForTeamStripeCustomer(tx, {
          stackTeamId: teamScope.stackTeamId,
          customerId,
        });
        if (transactionMappedStackUserId === DELETED_ACCOUNT_ACTOR_ID) return { skipped: true };
        if (
          metadataStackUserId &&
          transactionMappedStackUserId &&
          metadataStackUserId !== transactionMappedStackUserId
        ) return { skipped: true };

        const transactionStackUserId = transactionMappedStackUserId ?? metadataStackUserId;
        if (!transactionStackUserId || transactionStackUserId === DELETED_ACCOUNT_ACTOR_ID) return { skipped: true };
        const transactionOwnerStackUserId = teamSubscriptionOwnerStackUserId(
          transactionStackUserId,
          teamScope.stackTeamId,
        );
        if (expectedOwner.kind === "user") {
          if (transactionOwnerStackUserId !== expectedOwner.stackUserId) return { skipped: true };
          if (await hasCheckoutBlockingAccountDeletionTombstone(expectedOwner.stackUserId, tx)) return { skipped: true };
          const owner = await loadOptionalStackUser(expectedOwner.stackUserId, dependencies.stackApp);
          if (!owner || isAccountDeletionInProgress(owner)) return { skipped: true };
        } else if (transactionStackUserId !== teamScope.stackTeamId) {
          return { skipped: true };
        }

        await upsertTeamStripeCustomer(tx, {
          customerId,
          stackUserId: transactionStackUserId,
          stackTeamId: teamScope.stackTeamId,
        });
        await upsertStripeSubscription(tx, {
          subscription,
          customerId,
          stackUserId: transactionStackUserId,
          stackTeamId: teamScope.stackTeamId,
          scope: "team",
        });

        return { scope: "team", stackTeamId: teamScope.stackTeamId, isActive };
      };

    const lockedResult = ownerStackUserId
      ? await withAccountDeletionUserLock(
        db,
        ownerStackUserId,
        (tx) => applyTeamUpdate(tx, { kind: "user", stackUserId: ownerStackUserId }),
      )
      : await db.transaction((tx) => applyTeamUpdate(tx, { kind: "legacy-team" }));
    if ("skipped" in lockedResult) return { skipped: true };
    const team = await loadStackTeam(teamScope.stackTeamId, dependencies.stackApp);
    await syncTeamPlanMetadata(team, isActive);
    return lockedResult;
  }

  const metadataStackUserId = subscription.metadata?.stackUserId;
  const mappedStackUserId = await stackUserIdForStripeCustomer(db, customerId);
  if (mappedStackUserId === DELETED_ACCOUNT_ACTOR_ID) return { skipped: true };
  if (
    metadataStackUserId &&
    mappedStackUserId &&
    metadataStackUserId !== mappedStackUserId
  ) return { skipped: true };

  const stackUserId = mappedStackUserId ?? metadataStackUserId;
  if (!stackUserId || stackUserId === DELETED_ACCOUNT_ACTOR_ID) return { skipped: true };

  const isActive = isActiveStripeSubscriptionStatus(subscription.status);
  const lockedResult = await withAccountDeletionUserLock(
    db,
    stackUserId,
    async (tx): Promise<
      | { skipped: true }
      | { user: StackBillingUser; stackUserId: string; isActive: boolean }
    > => {
      const hasUserSubscription = await userStripeSubscriptionExists(tx, {
        subscriptionId: subscription.id,
        stackUserId,
      });
      const isMetadataOnlyUserSubscription = !hasUserSubscription &&
        !mappedStackUserId &&
        metadataStackUserId === stackUserId;

      if (await hasCheckoutBlockingAccountDeletionTombstone(stackUserId, tx)) return { skipped: true };
      const user = await loadOptionalStackUser(stackUserId, dependencies.stackApp);
      if (!user && isMetadataOnlyUserSubscription) return { skipped: true };
      if (!user) throw new Error(`Stack user not found for Stripe subscription update: ${stackUserId}`);
      if (isAccountDeletionInProgress(user)) return { skipped: true };

      if (hasUserSubscription) {
        await updateExistingUserStripeSubscription(tx, {
          subscription,
          customerId,
          stackUserId,
        });
      } else {
        await upsertStripeSubscription(tx, {
          subscription,
          customerId,
          stackUserId,
          scope: "user",
        });
      }

      return { user, stackUserId, isActive };
    },
  );
  if ("skipped" in lockedResult) return { skipped: true };

  await syncStackUserMetadataWithAccountDeletionGuard({
    db,
    stackUserId: lockedResult.stackUserId,
    stackApp: dependencies.stackApp ?? stackServerApp,
    sync: async (freshUser, mutationLease) => {
      const currentMetadata = await syncProPlanMetadata(
        freshUser,
        isActive,
        mutationLease,
      );
      if (!isActive) {
        await removeUserFromTestflightOnLapse(
          freshUser,
          lockedResult.stackUserId,
          currentMetadata,
          dependencies,
          mutationLease,
        );
      }
    },
  });
  return { scope: "user", stackUserId: lockedResult.stackUserId, isActive };
}

function isAccountDeletionInProgress(user: StackBillingUser): boolean {
  const metadata = user.clientReadOnlyMetadata;
  return Boolean(
    metadata &&
      typeof metadata === "object" &&
      !Array.isArray(metadata) &&
      (metadata as Record<string, unknown>).cmuxAccountDeleting === true
  );
}

async function hasCheckoutBlockingAccountDeletionTombstone(
  stackUserId: string,
  db: BillingDbClient,
): Promise<boolean> {
  const [row] = await db
    .select({
      status: accountDeletionTombstones.status,
      updatedAt: accountDeletionTombstones.updatedAt,
    })
    .from(accountDeletionTombstones)
    .where(eq(accountDeletionTombstones.userIdHash, accountDeletionUserHash(stackUserId)))
    .limit(1);
  return row ? isBlockingAccountDeletionTombstone(row) : false;
}

async function withAccountDeletionUserLock<T>(
  db: BillingDb,
  stackUserId: string,
  callback: (tx: BillingDbClient) => Promise<T>,
): Promise<T> {
  return db.transaction(async (tx) => {
    const accountTx = tx as BillingDbTransaction;
    await accountTx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(stackUserId)}, 0))`,
    );
    return callback(accountTx);
  });
}

async function syncStackUserMetadataWithAccountDeletionGuard(input: {
  readonly db: BillingDb;
  readonly stackUserId: string;
  readonly stackApp: StackBillingApp | null | undefined;
  readonly sync: (
    user: StackBillingUser,
    mutationLease: AccountDeletionUserMutationLease,
  ) => Promise<void>;
}): Promise<boolean> {
  const stackApp = input.stackApp ?? stackServerApp;
  if (!stackApp) throw new Error("Stack Auth is not configured");
  const loader: AccountMetadataUserLoader<StackBillingUser> = {
    getUser: (requestedUserId) => stackApp.getUser(requestedUserId),
  };
  return await withFreshAccountMetadataUser({
    db: input.db,
    userId: input.stackUserId,
    loader,
    operation: async (freshUser, mutationLease) => {
      if (!freshUser || isAccountDeletionInProgress(freshUser)) return false;
      await input.sync(freshUser, mutationLease);
      return true;
    },
  });
}

function teamSubscriptionOwnerStackUserId(
  stackUserId: string,
  stackTeamId: string,
): string | null {
  return stackUserId !== stackTeamId && stackUserId !== DELETED_ACCOUNT_ACTOR_ID
    ? stackUserId
    : null;
}

export async function latestStripeSubscriptionForSession(
  session: Stripe.Checkout.Session,
  db: BillingDb = cloudDb(),
) {
  const subscription = expandedSubscription(session);
  const subscriptionId = subscription?.id ?? stringId(session.subscription);
  if (!subscriptionId) return null;
  const rows = await db
    .select()
    .from(stripeSubscriptions)
    .where(eq(stripeSubscriptions.id, subscriptionId))
    .limit(1);
  return rows[0] ?? null;
}

export function isActiveStripeSubscriptionStatus(status: string): boolean {
  return ACTIVE_STRIPE_SUBSCRIPTION_STATUSES.has(status);
}

function isStripeSubscriptionAlreadyCanceledError(error: unknown): boolean {
  const statusCode =
    error && typeof error === "object"
      ? (error as { statusCode?: unknown; raw?: { statusCode?: unknown } }).statusCode ??
        (error as { raw?: { statusCode?: unknown } }).raw?.statusCode
      : undefined;
  if (statusCode === 404) return true;

  const message =
    error && typeof error === "object" && typeof (error as { message?: unknown }).message === "string"
      ? (error as { message: string }).message
      : String(error);
  return /already been canceled/i.test(message);
}

function isStripeCustomerAlreadyDeletedError(error: unknown): boolean {
  const statusCode =
    error && typeof error === "object"
      ? (error as { statusCode?: unknown; raw?: { statusCode?: unknown } }).statusCode ??
        (error as { raw?: { statusCode?: unknown } }).raw?.statusCode
      : undefined;
  if (statusCode === 404) return true;

  const message =
    error && typeof error === "object" && typeof (error as { message?: unknown }).message === "string"
      ? (error as { message: string }).message
      : String(error);
  return /no such customer|already deleted/i.test(message);
}

export function isCmuxCheckoutSession(
  session: Pick<Stripe.Checkout.Session, "client_reference_id" | "metadata">,
): boolean {
  if (session.metadata?.app === "cmux") return true;
  if (session.metadata?.app) return false;
  return Boolean(session.client_reference_id && session.metadata?.plan === "pro");
}

async function loadOptionalStackUser(
  stackUserId: string,
  stackApp: StackBillingApp | null | undefined,
): Promise<StackBillingUser | null> {
  const app = stackApp ?? stackServerApp;
  if (!app) throw new Error("Stack Auth is not configured");
  return app.getUser(stackUserId);
}

async function loadStackTeam(
  stackTeamId: string,
  stackApp: StackBillingApp | null | undefined,
): Promise<StackBillingTeam> {
  const app = stackApp ?? stackServerApp;
  if (!app) throw new Error("Stack Auth is not configured");
  if (typeof app.getTeam !== "function") {
    throw new Error("Stack Auth server SDK cannot load teams");
  }
  const team = await app.getTeam(stackTeamId);
  if (!team) throw new Error(`Stack team not found for Stripe purchase: ${stackTeamId}`);
  if (typeof team.update !== "function") {
    throw new Error("Stack Auth server SDK cannot update team metadata");
  }
  return team as StackBillingTeam;
}

async function removeUserFromTestflightOnLapse(
  user: StackBillingUser,
  stackUserId: string,
  metadataAfterPlanLapse: ProMetadataJson,
  dependencies: BillingPurchaseDependencies,
  mutationLease: AccountDeletionUserMutationLease,
): Promise<void> {
  const configured = dependencies.testflight?.isAscConfigured ?? isAscConfigured;
  if (!configured()) return;

  try {
    await removeProTesterAccess(
      user.primaryEmail,
      metadataAfterPlanLapse,
      dependencies.testflight?.removeTester ?? removeTester,
      {
        beforeExternalMutation: mutationLease.refresh,
        updateMetadata: (clientReadOnlyMetadata) => user.update({
          clientReadOnlyMetadata,
        }),
      },
    );
  } catch (error) {
    (dependencies.testflight?.captureAscError ?? captureAscError)(error, {
      route: "/api/stripe/webhook",
      stackUserId,
      email: user.primaryEmail,
    });
    throw error;
  }
}

async function recordTeamCheckoutCompletion(input: {
  subscription: Stripe.Subscription;
  customerId: string;
  stackTeamId: string;
  stackUserId?: string | null;
  dependencies: BillingPurchaseDependencies;
}): Promise<CheckoutCompletionResult> {
  const db = input.dependencies.db ?? cloudDb();
  const checkoutCustomerOwnership = await teamStripeCustomerOwnership(db, {
    stackTeamId: input.stackTeamId,
    customerId: input.customerId,
  });
  const checkoutOwnerStackUserId =
    input.stackUserId ?? checkoutCustomerOwnership.stackUserId;
  const checkoutOwnerIsLegacyTeam =
    checkoutOwnerStackUserId === input.stackTeamId;
  const ownerStackUserId = checkoutOwnerStackUserId
    ? checkoutOwnerIsLegacyTeam
      ? input.stackTeamId
      : teamSubscriptionOwnerStackUserId(checkoutOwnerStackUserId, input.stackTeamId)
    : null;
  if (!ownerStackUserId) {
    await cleanupCheckoutStripeResourcesForAccountDeletion({
      subscription: input.subscription,
      customerId: input.customerId,
      dependencies: input.dependencies,
      deleteCustomer: !checkoutCustomerOwnership.customerRowExists,
    });
    return {
      skipped: "account_deletion_in_progress",
      stackUserId: checkoutOwnerStackUserId ?? input.stackTeamId,
      subscriptionId: input.subscription.id,
    };
  }

  const owner = checkoutOwnerIsLegacyTeam
    ? null
    : await loadOptionalStackUser(ownerStackUserId, input.dependencies.stackApp);
  const lockedResult = await withAccountDeletionUserLock(db, ownerStackUserId, async (tx) => {
    const transactionCustomerOwnership = await teamStripeCustomerOwnership(tx, {
      stackTeamId: input.stackTeamId,
      customerId: input.customerId,
    });
    const stackUserId =
      input.stackUserId ??
      transactionCustomerOwnership.stackUserId ??
      checkoutOwnerStackUserId;
    const transactionOwnerIsLegacyTeam = stackUserId === input.stackTeamId;
    const transactionOwnerStackUserId = stackUserId
      ? transactionOwnerIsLegacyTeam
        ? input.stackTeamId
        : teamSubscriptionOwnerStackUserId(stackUserId, input.stackTeamId)
      : null;
    const ownerChangedDuringCheckout = transactionOwnerStackUserId !== ownerStackUserId;
    const observedExistingCheckoutCustomer =
      checkoutCustomerOwnership.customerRowExists ||
      transactionCustomerOwnership.customerRowExists;
    if (
      !transactionOwnerStackUserId ||
      !stackUserId ||
      (!transactionOwnerIsLegacyTeam && await hasCheckoutBlockingAccountDeletionTombstone(stackUserId, tx)) ||
      ownerChangedDuringCheckout ||
      (!transactionOwnerIsLegacyTeam && transactionOwnerStackUserId && !owner) ||
      (owner && isAccountDeletionInProgress(owner))
    ) {
      return {
        checkoutCleanup: { deleteCustomer: !observedExistingCheckoutCustomer },
        result: {
          skipped: "account_deletion_in_progress" as const,
          stackUserId: stackUserId ?? input.stackTeamId,
          subscriptionId: input.subscription.id,
        },
      };
    }

    await upsertTeamStripeCustomer(tx, {
      customerId: input.customerId,
      stackUserId,
      stackTeamId: input.stackTeamId,
    });
    await upsertStripeSubscription(tx, {
      subscription: input.subscription,
      customerId: input.customerId,
      stackUserId,
      stackTeamId: input.stackTeamId,
      scope: "team",
    });

    return {
      postCommitTeamSync: {
        stackTeamId: input.stackTeamId,
        stackApp: input.dependencies.stackApp,
      },
      result: {
        scope: "team" as const,
        stackTeamId: input.stackTeamId,
        subscriptionId: input.subscription.id,
      },
    };
  });

  if (lockedResult.checkoutCleanup) {
    await cleanupCheckoutStripeResourcesForAccountDeletion({
      subscription: input.subscription,
      customerId: input.customerId,
      dependencies: input.dependencies,
      deleteCustomer: lockedResult.checkoutCleanup.deleteCustomer,
    });
  }
  if (lockedResult.postCommitTeamSync) {
    const team = await loadStackTeam(
      lockedResult.postCommitTeamSync.stackTeamId,
      lockedResult.postCommitTeamSync.stackApp,
    );
    await syncTeamPlanMetadata(team, true);
  }

  return lockedResult.result;
}

async function upsertStripeCustomer(
  db: BillingDbClient,
  input: { customerId: string; stackUserId: string; email: string | null },
): Promise<void> {
  const [existingForStackUser] = await db
    .select({ id: stripeCustomers.id })
    .from(stripeCustomers)
    .where(
      and(
        eq(stripeCustomers.stackUserId, input.stackUserId),
        isNull(stripeCustomers.stackTeamId),
      ),
    )
    .limit(1);
  if (existingForStackUser) {
    await db
      .update(stripeCustomers)
      .set({
        id: input.customerId,
        stackTeamId: null,
        email: input.email,
        updatedAt: sql`now()`,
      })
      .where(
        and(
          eq(stripeCustomers.stackUserId, input.stackUserId),
          isNull(stripeCustomers.stackTeamId),
        ),
      );
    return;
  }

  try {
    await db
      .insert(stripeCustomers)
      .values({
        id: input.customerId,
        stackUserId: input.stackUserId,
        stackTeamId: null,
        email: input.email,
      })
      .onConflictDoUpdate({
        target: stripeCustomers.id,
        set: {
          stackUserId: input.stackUserId,
          stackTeamId: null,
          email: input.email,
          updatedAt: sql`now()`,
        },
      });
  } catch (error) {
    if (!isStackUserUniqueConflict(error)) throw error;
    await db
      .update(stripeCustomers)
      .set({
        id: input.customerId,
        stackTeamId: null,
        email: input.email,
        updatedAt: sql`now()`,
      })
      .where(
        and(
          eq(stripeCustomers.stackUserId, input.stackUserId),
          isNull(stripeCustomers.stackTeamId),
        ),
      );
  }
}

async function upsertTeamStripeCustomer(
  db: BillingDbClient,
  input: { customerId: string; stackUserId: string; stackTeamId: string },
): Promise<void> {
  const [existingForStackTeam] = await db
    .select({ id: stripeCustomers.id })
    .from(stripeCustomers)
    .where(eq(stripeCustomers.stackTeamId, input.stackTeamId))
    .limit(1);
  if (existingForStackTeam) {
    await db
      .update(stripeCustomers)
      .set({
        id: input.customerId,
        stackUserId: input.stackUserId,
        updatedAt: sql`now()`,
      })
      .where(eq(stripeCustomers.stackTeamId, input.stackTeamId));
    return;
  }

  try {
    await db
      .insert(stripeCustomers)
      .values({
        id: input.customerId,
        stackUserId: input.stackUserId,
        stackTeamId: input.stackTeamId,
        email: null,
      })
      .onConflictDoUpdate({
        target: stripeCustomers.id,
        set: {
          stackUserId: input.stackUserId,
          stackTeamId: input.stackTeamId,
          email: null,
          updatedAt: sql`now()`,
        },
      });
  } catch (error) {
    if (!isStackTeamUniqueConflict(error)) throw error;
    await db
      .update(stripeCustomers)
      .set({
        id: input.customerId,
        stackUserId: input.stackUserId,
        updatedAt: sql`now()`,
      })
      .where(eq(stripeCustomers.stackTeamId, input.stackTeamId));
  }
}

async function upsertStripeSubscription(
  db: BillingDbClient,
  input: StripeSubscriptionValuesInput,
): Promise<void> {
  const values = stripeSubscriptionValues(input);
  const updateValues = mutableStripeSubscriptionValues(input);
  await db
    .insert(stripeSubscriptions)
    .values(values)
    .onConflictDoUpdate({
      target: stripeSubscriptions.id,
      set: {
        ...updateValues,
        updatedAt: sql`now()`,
      },
    });
}

async function updateExistingUserStripeSubscription(
  db: BillingDbClient,
  input: {
    subscription: Stripe.Subscription;
    customerId: string;
    stackUserId: string;
  },
): Promise<void> {
  const updateValues = mutableStripeSubscriptionValues({
    ...input,
    scope: "user",
  });
  await db
    .update(stripeSubscriptions)
    .set({
      ...updateValues,
      updatedAt: sql`now()`,
    })
    .where(
      and(
        eq(stripeSubscriptions.id, input.subscription.id),
        eq(stripeSubscriptions.stackUserId, input.stackUserId),
        eq(stripeSubscriptions.scope, "user"),
        isNull(stripeSubscriptions.stackTeamId),
      ),
    );
}

function stripeSubscriptionValues(input: StripeSubscriptionValuesInput) {
  const { subscription } = input;
  const plan = input.scope === "team" ? TEAM_PLAN_ID : PRO_PLAN_ID;
  return {
    id: subscription.id,
    customerId: input.customerId,
    stackUserId: input.stackUserId,
    stackTeamId: input.stackTeamId ?? null,
    status: subscription.status,
    priceId: subscriptionPriceId(subscription),
    plan,
    seats: input.scope === "team" ? subscriptionSeats(subscription) : null,
    scope: input.scope,
    currentPeriodEnd: subscriptionCurrentPeriodEnd(subscription),
    cancelAtPeriodEnd: subscription.cancel_at_period_end,
    raw: JSON.parse(JSON.stringify(subscription)) as Record<string, unknown>,
  };
}

function mutableStripeSubscriptionValues(input: StripeSubscriptionValuesInput) {
  const values = stripeSubscriptionValues(input);
  return {
    customerId: values.customerId,
    stackUserId: values.stackUserId,
    stackTeamId: values.stackTeamId,
    status: values.status,
    priceId: values.priceId,
    plan: values.plan,
    seats: values.seats,
    scope: values.scope,
    currentPeriodEnd: values.currentPeriodEnd,
    cancelAtPeriodEnd: values.cancelAtPeriodEnd,
    raw: values.raw,
  };
}

async function userStripeSubscriptionExists(
  db: BillingDbClient,
  input: { subscriptionId: string; stackUserId: string },
): Promise<boolean> {
  const [row] = await db
    .select({ id: stripeSubscriptions.id })
    .from(stripeSubscriptions)
    .where(
      and(
        eq(stripeSubscriptions.id, input.subscriptionId),
        eq(stripeSubscriptions.stackUserId, input.stackUserId),
        eq(stripeSubscriptions.scope, "user"),
        isNull(stripeSubscriptions.stackTeamId),
      ),
    )
    .limit(1);
  return Boolean(row);
}

async function attachPurchaseEmailOrRecordClaim(
  db: BillingDb,
  input: {
    user: StackBillingUser;
    email: string;
    stripeCustomerId: string;
    stackUserId: string;
    stackApp: StackBillingApp | null | undefined;
  },
  mutationLease: AccountDeletionUserMutationLease,
): Promise<void> {
  if (input.user.primaryEmail) return;
  await mutationLease.refresh();
  let ownerId: string | null = null;
  try {
    ownerId = await findUserIdByEmail(input.stackApp, input.email);
  } catch {
    ownerId = null;
  }
  if (ownerId && ownerId !== input.stackUserId) {
    await mutationLease.refresh();
    await recordBillingEmailClaim(db, input);
    return;
  }
  try {
    await mutationLease.refresh();
    await input.user.update({
      primaryEmail: input.email,
      primaryEmailAuthEnabled: true,
    });
  } catch (error) {
    if (!isEmailAlreadyUsedError(error)) throw error;
    await mutationLease.refresh();
    await recordBillingEmailClaim(db, input);
  }
}

async function findUserIdByEmail(
  stackApp: StackBillingApp | null | undefined,
  email: string,
): Promise<string | null> {
  if (!stackApp?.listUsers) {
    throw new Error("Stack Auth server SDK cannot list users");
  }
  const normalizedEmail = email.trim().toLowerCase();
  const users = await stackApp.listUsers({
    query: normalizedEmail,
    limit: 20,
    includeAnonymous: true,
    includeRestricted: true,
  });
  const owner = users.find(
    (user) => user.primaryEmail?.trim().toLowerCase() === normalizedEmail,
  );
  return owner?.id ?? null;
}

async function recordBillingEmailClaim(
  db: BillingDbClient,
  input: {
    email: string;
    stripeCustomerId: string;
    stackUserId: string;
  },
): Promise<void> {
  const existing = await db
    .select({ id: billingEmailClaims.id })
    .from(billingEmailClaims)
    .where(
      and(
        eq(billingEmailClaims.email, input.email),
        eq(billingEmailClaims.stripeCustomerId, input.stripeCustomerId),
        eq(billingEmailClaims.stackUserId, input.stackUserId),
        eq(billingEmailClaims.plan, PRO_PLAN_ID),
      ),
    )
    .limit(1);
  if (existing.length > 0) return;
  await db.insert(billingEmailClaims).values({
    email: input.email,
    stripeCustomerId: input.stripeCustomerId,
    stackUserId: input.stackUserId,
    plan: PRO_PLAN_ID,
  });
}

function verifiedClaimEmail(user: ProBillingClaimUser): string | null {
  if (
    user.isAnonymous === true ||
    user.isRestricted === true ||
    user.primaryEmailVerified !== true
  ) {
    return null;
  }
  const email = user.primaryEmail?.trim().toLowerCase();
  return email && email.includes("@") ? email : null;
}

function makeBillingOwnershipRepository(db: BillingDb): BillingOwnershipRepository {
  return {
    findClaims: async (email, targetStackUserId) => {
      const rows = await db
        .select({
          id: billingEmailClaims.id,
          email: billingEmailClaims.email,
          stripeCustomerId: billingEmailClaims.stripeCustomerId,
          stackUserId: billingEmailClaims.stackUserId,
          claimedByUserId: billingEmailClaims.claimedByUserId,
        })
        .from(billingEmailClaims)
        .where(
          and(
            eq(billingEmailClaims.email, email),
            eq(billingEmailClaims.plan, PRO_PLAN_ID),
            or(
              isNull(billingEmailClaims.claimedByUserId),
              eq(billingEmailClaims.claimedByUserId, targetStackUserId),
            ),
          ),
        )
        .orderBy(asc(billingEmailClaims.createdAt))
        .limit(20);
      return rows;
    },
    transferClaim: (claim, targetStackUserId) =>
      transferBillingOwnershipClaim(db, claim, targetStackUserId),
  };
}

async function transferBillingOwnershipClaim(
  db: BillingDb,
  claim: BillingOwnershipClaim,
  targetStackUserId: string,
): Promise<BillingOwnershipTransfer | null> {
  const sourceStackUserId = claim.stackUserId;
  const lockIDs = [...new Set([sourceStackUserId, targetStackUserId])].sort();
  return await db.transaction(async (tx) => {
    const accountTx = tx as BillingDbTransaction;
    for (const lockID of lockIDs) {
      await accountTx.execute(
        sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(lockID)}, 0))`,
      );
    }

    const [freshClaim] = await accountTx
      .select({
        id: billingEmailClaims.id,
        email: billingEmailClaims.email,
        stripeCustomerId: billingEmailClaims.stripeCustomerId,
        stackUserId: billingEmailClaims.stackUserId,
        claimedByUserId: billingEmailClaims.claimedByUserId,
      })
      .from(billingEmailClaims)
      .where(eq(billingEmailClaims.id, claim.id))
      .limit(1);
    if (!freshClaim) return null;
    if (
      freshClaim.claimedByUserId &&
      freshClaim.claimedByUserId !== targetStackUserId
    ) {
      return null;
    }

    const effectiveSource = freshClaim.claimedByUserId === targetStackUserId
      ? targetStackUserId
      : freshClaim.stackUserId;
    if (!effectiveSource || effectiveSource === DELETED_ACCOUNT_ACTOR_ID) return null;
    if (
      await hasCheckoutBlockingAccountDeletionTombstone(effectiveSource, accountTx) ||
      await hasCheckoutBlockingAccountDeletionTombstone(targetStackUserId, accountTx)
    ) {
      return null;
    }

    const [targetCustomer] = await accountTx
      .select({ id: stripeCustomers.id })
      .from(stripeCustomers)
      .where(
        and(
          eq(stripeCustomers.stackUserId, targetStackUserId),
          isNull(stripeCustomers.stackTeamId),
        ),
      )
      .limit(1);
    if (targetCustomer && targetCustomer.id !== freshClaim.stripeCustomerId) {
      // Do not silently merge two paid accounts. An operator can resolve this
      // explicit conflict after checking the Stripe customer records.
      return null;
    }

    const sourceCustomer = await accountTx
      .select({ id: stripeCustomers.id })
      .from(stripeCustomers)
      .where(
        and(
          eq(stripeCustomers.id, freshClaim.stripeCustomerId),
          eq(stripeCustomers.stackUserId, effectiveSource),
          isNull(stripeCustomers.stackTeamId),
        ),
      )
      .limit(1);
    if (sourceCustomer.length === 0 && !targetCustomer) return null;

    const sourceSubscriptions = await accountTx
      .select({ id: stripeSubscriptions.id, status: stripeSubscriptions.status })
      .from(stripeSubscriptions)
      .where(
        and(
          eq(stripeSubscriptions.customerId, freshClaim.stripeCustomerId),
          eq(stripeSubscriptions.stackUserId, effectiveSource),
          eq(stripeSubscriptions.scope, "user"),
          eq(stripeSubscriptions.plan, PRO_PLAN_ID),
          isNull(stripeSubscriptions.stackTeamId),
        ),
      )
      .limit(50);
    const subscriptionIDs = sourceSubscriptions.map((row) => row.id);
    if (
      sourceSubscriptions.length === 0 ||
      !sourceSubscriptions.some((row) => isActiveStripeSubscriptionStatus(row.status))
    ) {
      // A parked claim without a live subscription must never turn into Pro.
      return null;
    }

    const targetSubscriptions = await accountTx
      .select({ id: stripeSubscriptions.id, status: stripeSubscriptions.status })
      .from(stripeSubscriptions)
      .where(
        and(
          eq(stripeSubscriptions.stackUserId, targetStackUserId),
          eq(stripeSubscriptions.scope, "user"),
          eq(stripeSubscriptions.plan, PRO_PLAN_ID),
          isNull(stripeSubscriptions.stackTeamId),
        ),
      )
      .limit(50);
    if (
      targetSubscriptions.some(
        (row) =>
          isActiveStripeSubscriptionStatus(row.status) &&
          !subscriptionIDs.includes(row.id),
      )
    ) {
      return null;
    }

    const now = new Date();
    if (sourceCustomer.length > 0) {
      await accountTx
        .update(stripeCustomers)
        .set({
          stackUserId: targetStackUserId,
          email: freshClaim.email,
          updatedAt: now,
        })
        .where(
          and(
            eq(stripeCustomers.id, freshClaim.stripeCustomerId),
            eq(stripeCustomers.stackUserId, effectiveSource),
            isNull(stripeCustomers.stackTeamId),
          ),
        );
    }
    await accountTx
      .update(stripeSubscriptions)
      .set({ stackUserId: targetStackUserId, updatedAt: now })
      .where(
        and(
          eq(stripeSubscriptions.customerId, freshClaim.stripeCustomerId),
          eq(stripeSubscriptions.stackUserId, effectiveSource),
          eq(stripeSubscriptions.scope, "user"),
          eq(stripeSubscriptions.plan, PRO_PLAN_ID),
          isNull(stripeSubscriptions.stackTeamId),
        ),
      );
    await accountTx
      .update(billingEmailClaims)
      .set({ claimedByUserId: targetStackUserId, claimedAt: now })
      .where(eq(billingEmailClaims.id, freshClaim.id));

    return {
      kind: "claimed" as const,
      claimId: freshClaim.id,
      email: freshClaim.email,
      customerId: freshClaim.stripeCustomerId,
      subscriptionIds: subscriptionIDs,
      sourceStackUserId: effectiveSource,
      targetStackUserId,
    };
  });
}

async function syncTransferredStripeOwnership(
  transfer: BillingOwnershipTransfer,
  clientFactory: () => StripeBillingClient,
): Promise<void> {
  // The durable DB transfer is authoritative. Stripe metadata is repaired on
  // a best-effort basis here; a later webhook or operator reconciliation can
  // safely retry these idempotent updates without changing ownership again.
  try {
    const client = clientFactory();
    const customer = await client.customers.retrieve(transfer.customerId);
    if (customer.deleted) return;
    const customerEmail = customer.email?.trim().toLowerCase();
    if (customerEmail && customerEmail !== transfer.email) return;
    await client.customers.update(transfer.customerId, {
      metadata: {
        ...customer.metadata,
        app: "cmux",
        stackUserId: transfer.targetStackUserId,
      },
    });

    for (const subscriptionID of transfer.subscriptionIds) {
      const subscription = await client.subscriptions.retrieve(subscriptionID);
      if (stringId(subscription.customer) !== transfer.customerId) continue;
      await client.subscriptions.update(subscriptionID, {
        metadata: {
          ...subscription.metadata,
          app: "cmux",
          plan: PRO_PLAN_ID,
          stackUserId: transfer.targetStackUserId,
        },
      });
    }
  } catch {
    // Keep the user-facing plan available from the committed local ownership
    // rows. Metadata repair is intentionally retryable and must not make a
    // successful account claim look like a failed purchase.
  }
}

async function stackUserIdForStripeCustomer(
  db: BillingDbClient,
  customerId: string,
): Promise<string | null> {
  const rows = await db
    .select({ stackUserId: stripeCustomers.stackUserId })
    .from(stripeCustomers)
    .where(eq(stripeCustomers.id, customerId))
    .orderBy(desc(stripeCustomers.updatedAt))
    .limit(1);
  return rows[0]?.stackUserId ?? null;
}

async function stackUserIdForTeamStripeCustomer(
  db: BillingDbClient,
  input: { stackTeamId: string; customerId: string },
): Promise<string | null> {
  return (await teamStripeCustomerOwnership(db, input)).stackUserId;
}

async function teamStripeCustomerOwnership(
  db: BillingDbClient,
  input: { stackTeamId: string; customerId: string },
): Promise<{ stackUserId: string | null; customerRowExists: boolean }> {
  const byTeam = await db
    .select({ id: stripeCustomers.id, stackUserId: stripeCustomers.stackUserId })
    .from(stripeCustomers)
    .where(eq(stripeCustomers.stackTeamId, input.stackTeamId))
    .orderBy(desc(stripeCustomers.updatedAt))
    .limit(1);
  if (byTeam[0]) {
    return {
      stackUserId: byTeam[0].stackUserId ?? null,
      customerRowExists: byTeam[0].id === input.customerId,
    };
  }

  const byCustomer = await db
    .select({ stackUserId: stripeCustomers.stackUserId })
    .from(stripeCustomers)
    .where(eq(stripeCustomers.id, input.customerId))
    .orderBy(desc(stripeCustomers.updatedAt))
    .limit(1);
  return {
    stackUserId: byCustomer[0]?.stackUserId ?? null,
    customerRowExists: Boolean(byCustomer[0]),
  };
}

function expandedSubscription(
  session: Stripe.Checkout.Session,
): Stripe.Subscription | null {
  return typeof session.subscription === "object" && session.subscription !== null
    ? session.subscription
    : null;
}

function teamScopeFromSession(
  session: Stripe.Checkout.Session,
  subscription: Stripe.Subscription,
): { stackTeamId: string; stackUserId: string | null } | null {
  const metadata = session.metadata?.plan === TEAM_PLAN_ID
    ? session.metadata
    : subscription.metadata;
  const stackTeamId = metadata?.stackTeamId;
  const metadataStackUserId =
    nonEmptyString(session.metadata?.stackUserId) ??
    nonEmptyString(subscription.metadata?.stackUserId);
  const clientReferenceStackUserId =
    nonEmptyString(session.client_reference_id) !== stackTeamId
      ? nonEmptyString(session.client_reference_id)
      : null;
  return metadata?.plan === TEAM_PLAN_ID && typeof stackTeamId === "string" && stackTeamId
    ? { stackTeamId, stackUserId: metadataStackUserId ?? clientReferenceStackUserId }
    : null;
}

function teamScopeFromSubscription(
  subscription: Stripe.Subscription,
): { stackTeamId: string } | null {
  const stackTeamId = subscription.metadata?.stackTeamId;
  return subscription.metadata?.plan === TEAM_PLAN_ID &&
    typeof stackTeamId === "string" &&
    stackTeamId
    ? { stackTeamId }
    : null;
}

function stackUserIdFromSession(
  session: Stripe.Checkout.Session,
  subscription: Stripe.Subscription,
): string | null {
  return session.client_reference_id ?? subscription.metadata?.stackUserId ?? null;
}

function nonEmptyString(value: unknown): string | null {
  return typeof value === "string" && value ? value : null;
}

function customerIdFromSession(
  session: Stripe.Checkout.Session,
  customer: Stripe.Customer | Stripe.DeletedCustomer | null | undefined,
): string | null {
  return customer && !customer.deleted
    ? customer.id
    : stringId(session.customer);
}

function customerIdFromSubscription(subscription: Stripe.Subscription): string | null {
  return stringId(subscription.customer);
}

function checkoutEmail(
  session: Stripe.Checkout.Session,
  customer: Stripe.Customer | Stripe.DeletedCustomer | null | undefined,
): string | null {
  const email = session.customer_details?.email ?? (customer && !customer.deleted ? customer.email : null);
  return email ? email.trim().toLowerCase() : null;
}

function subscriptionPriceId(subscription: Stripe.Subscription): string | null {
  return subscription.items.data[0]?.price.id ?? null;
}

function subscriptionSeats(subscription: Stripe.Subscription): number | null {
  const quantity = subscription.items.data[0]?.quantity;
  return typeof quantity === "number" && Number.isFinite(quantity) ? quantity : null;
}

function subscriptionCurrentPeriodEnd(subscription: Stripe.Subscription): Date | null {
  const timestamp = subscription.items.data[0]?.current_period_end;
  return typeof timestamp === "number" ? new Date(timestamp * 1000) : null;
}

function stringId(value: string | { id: string } | null | undefined): string | null {
  if (!value) return null;
  return typeof value === "string" ? value : value.id;
}

function isEmailAlreadyUsedError(error: unknown): boolean {
  const text = error instanceof Error ? `${error.name} ${error.message}` : String(error);
  return /already.{0,40}(used|taken)|CONTACT_CHANNEL_ALREADY_USED_FOR_AUTH_BY_SOMEONE_ELSE/i.test(text);
}

function isStackUserUniqueConflict(error: unknown): boolean {
  if (isStackUserUniqueConflictCandidate(error)) return true;
  const cause = (error as { cause?: unknown } | null)?.cause;
  if (isStackUserUniqueConflictCandidate(cause)) return true;
  const text = error instanceof Error ? error.message : String(error);
  return /stripe_customers_stack_user_id_unique/.test(text);
}

function isStackUserUniqueConflictCandidate(error: unknown): boolean {
  const candidate = error as { code?: string; constraint?: string } | null;
  return (
    candidate?.code === "23505" &&
    candidate.constraint === "stripe_customers_stack_user_id_unique"
  );
}

function isStackTeamUniqueConflict(error: unknown): boolean {
  if (isStackTeamUniqueConflictCandidate(error)) return true;
  const cause = (error as { cause?: unknown } | null)?.cause;
  if (isStackTeamUniqueConflictCandidate(cause)) return true;
  const text = error instanceof Error ? error.message : String(error);
  return /stripe_customers_stack_team_id_unique/.test(text);
}

function isStackTeamUniqueConflictCandidate(error: unknown): boolean {
  const candidate = error as { code?: string; constraint?: string } | null;
  return (
    candidate?.code === "23505" &&
    candidate.constraint === "stripe_customers_stack_team_id_unique"
  );
}
