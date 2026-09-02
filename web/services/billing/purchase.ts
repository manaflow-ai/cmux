import { and, desc, eq, inArray, isNull, or, sql } from "drizzle-orm";
import type Stripe from "stripe";

import {
  getStackServerApp,
  promoteStackUserFromAnonymousViaApi,
} from "../../app/lib/stack";
import { cloudDb } from "../../db/client";
import {
  accountDeletionTombstones,
  billingEmailClaims,
  stripeCustomers,
  stripeSubscriptions,
} from "../../db/schema";
import {
  withAccountDeletionUserMutation,
  AccountDeletionMutationBlockedError,
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
  enrollTester,
  removeTester,
  type RemoveTesterOptions,
} from "../asc/testflight";
import { captureAscError } from "../errors";
import {
  canonicalizeEmailForMatching,
  emailVariantsForMatching,
  isGmailAddress,
} from "./emailMatching";
import {
  isUnsupportedVerificationFieldError,
  type StackPurchaseUser,
} from "./stackVerification";
import {
  makePurchaseMagicLinkDeliveryStore,
  PurchaseMagicLinkProviderRejectedError,
  type PurchaseMagicLinkDeliveryStore,
} from "./emailVerificationDelivery";

export { canonicalizeEmailForMatching } from "./emailMatching";

export const ACTIVE_STRIPE_SUBSCRIPTION_STATUSES = new Set([
  "active",
  "trialing",
  "past_due",
]);
const DELETED_ACCOUNT_ACTOR_ID = "deleted-account";
const PURCHASE_MAGIC_LINK_CALLBACK = "https://cmux.com/handler/after-sign-in";
const STACK_USER_LOOKUP_PAGE_SIZE = 100;
const MAX_STACK_USER_LOOKUP_PAGES = 100;

type BillingDb = ReturnType<typeof cloudDb>;
type BillingDbClient = Pick<BillingDb, "select" | "insert" | "update">;
type BillingDbTransaction = BillingDbClient & {
  execute(query: unknown): Promise<unknown>;
};
type StripeBillingClient = Pick<ReturnType<typeof stripe>, "customers" | "subscriptions">;

/** A Stack account that may own a paid billing record. */
export type ProBillingClaimUser = StackPurchaseUser & {
  readonly isAnonymous?: boolean;
  readonly isRestricted?: boolean;
  readonly clientReadOnlyMetadata?: unknown;
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
  /** Founder rows need a post-verification TestFlight enrollment. */
  readonly founderSubscriptionIds?: readonly string[];
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

export type StackBillingUser = ProBillingClaimUser & {
  readonly id: string;
  update(options: {
    primaryEmail?: string | null;
    primaryEmailAuthEnabled?: boolean;
    primaryEmailVerified?: boolean;
    clientReadOnlyMetadata?: unknown;
  }): Promise<unknown>;
};

type StackBillingUserLookup = {
  readonly id: string;
  readonly primaryEmail?: string | null;
  readonly primaryEmailVerified?: boolean;
  readonly isAnonymous?: boolean;
  readonly isRestricted?: boolean;
  readonly update?: StackBillingUser["update"];
  readonly setPrimaryEmail?: StackPurchaseUser["setPrimaryEmail"];
};

type StackBillingUserList = readonly StackBillingUserLookup[] & {
  readonly nextCursor?: string | null;
};

type StackBillingTeam = {
  readonly id: string;
  readonly clientReadOnlyMetadata?: unknown;
  update(options: {
    clientReadOnlyMetadata: ProMetadataJson;
  }): Promise<unknown>;
};

export type StackBillingApp = {
  getUser(id: string): Promise<StackBillingUser | null>;
  listUsers?(options?: {
    cursor?: string;
    query?: string;
    limit?: number;
    includeAnonymous?: boolean;
    includeRestricted?: boolean;
  }): Promise<StackBillingUserList>;
  createUser?(options: {
    primaryEmail?: string | null;
    primaryEmailAuthEnabled?: boolean;
    primaryEmailVerified?: boolean;
    displayName?: string;
    clientReadOnlyMetadata?: unknown;
  }): Promise<StackBillingUser>;
  sendMagicLinkEmail?(email: string, options?: { callbackUrl?: string }): Promise<unknown>;
  getTeam?(id: string): Promise<StackBillingTeam | null>;
};

export type BillingPurchaseDependencies = {
  db?: BillingDb;
  stackApp?: StackBillingApp | null;
  stripeClient?: () => StripeBillingClient;
  ownershipRepository?: BillingOwnershipRepository;
  magicLinkDelivery?: PurchaseMagicLinkDeliveryStore;
  testflight?: {
    isAscConfigured?: () => boolean;
    enrollTester?: (
      email: string,
      firstName?: string,
      lastName?: string,
    ) => Promise<void>;
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

export type CheckoutCompletionInput = {
  session: Stripe.Checkout.Session;
  subscription?: Stripe.Subscription | null;
  customer?: Stripe.Customer | Stripe.DeletedCustomer | null;
  /** Optional literal address used for TestFlight enrollment during recovery. */
  enrollmentEmail?: string | null;
  /** Internal recovery seam allowing a verified email owner to remap parked rows. */
  allowCanonicalOwnershipRecovery?: boolean;
  /**
   * Keep an anonymous source as the billing owner while recovery creates or
   * selects an unverified destination account. The source claim is transferred
   * only after Stack verifies the destination mailbox.
   */
  deferAnonymousCanonicalOwnerResolution?: boolean;
  /** Keep Pro metadata disabled until the destination mailbox is verified. */
  deferProMetadataUntilVerification?: boolean;
  /** Use the idempotent delivery ledger for a user-requested recovery link. */
  sendRecoveryMagicLink?: boolean;
};

export type CheckoutCompletionResult =
  | { scope: "user"; stackUserId: string; subscriptionId: string }
  | { scope: "team"; stackTeamId: string; subscriptionId: string }
  | { skipped: "account_deletion_in_progress"; stackUserId: string; subscriptionId: string };

/**
 * A recovery checkout whose Stripe rows remain on an anonymous source until
 * the destination mailbox completes Stack verification.
 */
export type DeferredCheckoutCompletionResult = {
  readonly deferred: "email_verification";
  readonly stackUserId: string;
  readonly subscriptionId: string;
  readonly deliveryEmail: string;
};

export type FoundersCheckoutCompletionResult =
  | { scope: "user"; stackUserId: string; subscriptionId: string }
  | { skipped: "account_deletion_in_progress"; stackUserId: string; subscriptionId: string }
  | { skipped: "no_customer_email"; subscriptionId: string };

type UserCheckoutPostCommitSync = {
  user: StackBillingUser;
  email: string | null;
  checkoutSessionId: string;
  stripeCustomerId: string;
  stackUserId: string;
  stackApp: StackBillingApp | null | undefined;
  deferProMetadataUntilVerification?: boolean;
  sendRecoveryMagicLink?: boolean;
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
  if (hasConflictingFounderMetadata(input.session, subscription)) {
    throw new Error("Stripe checkout has conflicting product metadata");
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

  const requestedStackUserId = stackUserIdFromSession(input.session, subscription);
  if (!requestedStackUserId) {
    throw new Error("Stripe checkout session is missing stackUserId");
  }

  const db = dependencies.db ?? cloudDb();
  const checkoutStackApp = dependencies.stackApp ?? getStackServerApp();
  let stackUserId = requestedStackUserId;
  let user = await loadOptionalStackUser(stackUserId, checkoutStackApp);
  let resolvedFromAnonymousAlias = false;
  let remappedSourceStackUserId: string | null = null;
  const checkoutEmailValue = checkoutEmail(input.session, input.customer);
  // A checkout can be replayed after an earlier recovery moved its Stripe
  // customer to the verified destination account. Always fence the mapped
  // customer before any upsert can move ownership back. This read also rejects
  // a Team-scoped customer accidentally presented as a personal checkout.
  const mappedCustomerBeforeLookup = await stripeCustomerRowForId(db, customerId);
  if (mappedCustomerBeforeLookup?.stackTeamId != null) {
    throw new Error("Stripe checkout customer belongs to a Team");
  }
  if (
    mappedCustomerBeforeLookup?.stackUserId &&
    mappedCustomerBeforeLookup.stackUserId !== requestedStackUserId
  ) {
    const mappedOwner = await loadOptionalStackUser(
      mappedCustomerBeforeLookup.stackUserId,
      checkoutStackApp,
    );
    const canonicalEmailMatches = Boolean(
      checkoutEmailValue &&
        mappedOwner &&
        mappedOwner.primaryEmail &&
        canonicalizeEmailForMatching(mappedOwner.primaryEmail ?? "") ===
          canonicalizeEmailForMatching(checkoutEmailValue),
    );
    const parkedAnonymousSource = Boolean(
      mappedOwner?.isAnonymous === true && !mappedOwner.primaryEmail,
    );
    const recoveryTargetIsVerified = Boolean(
      input.allowCanonicalOwnershipRecovery &&
        user &&
        user.isAnonymous !== true &&
        user.isRestricted !== true &&
        user.primaryEmailVerified === true &&
        (canonicalEmailMatches || parkedAnonymousSource) &&
        canonicalizeEmailForMatching(user.primaryEmail ?? "") ===
          canonicalizeEmailForMatching(checkoutEmailValue ?? ""),
    );
    if (!recoveryTargetIsVerified) {
      throw new Error("Stripe checkout customer ownership conflict");
    }
    if (!mappedOwner || await hasCheckoutBlockingAccountDeletionTombstone(mappedOwner.id, db)) {
      throw new Error("Stripe checkout customer ownership conflict");
    }
    resolvedFromAnonymousAlias = true;
    remappedSourceStackUserId = mappedCustomerBeforeLookup.stackUserId;
  }
  // Stripe's anonymous checkout user is only a temporary holder. If the
  // purchased mailbox already belongs to a canonical Stack account (including
  // a dotted Gmail alias), write the purchase directly to that account instead
  // of creating a permanent unresolved claim.
  if (
    user?.isAnonymous === true &&
    checkoutEmailValue &&
    !input.deferAnonymousCanonicalOwnerResolution
  ) {
    try {
      const ownerId = await findUserIdByEmail(
        checkoutStackApp,
        checkoutEmailValue,
      );
      if (ownerId && ownerId !== stackUserId) {
        const owner = await loadOptionalStackUser(ownerId, checkoutStackApp);
        if (owner && isVerifiedCanonicalBillingOwner(owner, checkoutEmailValue)) {
          stackUserId = ownerId;
          user = owner;
          resolvedFromAnonymousAlias = true;
        }
      }
    } catch {
      // A temporary Stack lookup outage falls back to the normal claim path;
      // the next recovery/sign-in can resolve that claim safely.
    }
  }
  const effectiveSubscription = resolvedFromAnonymousAlias
    ? ({
        ...subscription,
        metadata: {
          ...subscription.metadata,
          app: "cmux",
          plan: PRO_PLAN_ID,
          stackUserId,
        },
      } as Stripe.Subscription)
    : subscription;
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
      if (resolvedFromAnonymousAlias) {
        const mappedCustomer = await stripeCustomerRowForId(tx, customerId);
        if (mappedCustomer && mappedCustomer.stackUserId !== stackUserId) {
          if (mappedCustomer.stackTeamId != null) {
            throw new Error("Stripe checkout customer ownership conflict");
          }
          if (
            (!input.allowCanonicalOwnershipRecovery &&
              mappedCustomer.stackUserId !== requestedStackUserId) ||
            (input.allowCanonicalOwnershipRecovery &&
              mappedCustomer.stackUserId !== remappedSourceStackUserId)
          ) {
            throw new Error("Stripe checkout customer ownership conflict");
          }
          // The anonymous holder may already have been written by an earlier
          // webhook delivery. Move that exact customer/subscription pair to
          // the canonical mailbox account under the same transaction.
          await tx
            .update(stripeCustomers)
            .set({ stackUserId, updatedAt: sql`now()` })
            .where(eq(stripeCustomers.id, customerId));
          await tx
            .update(stripeSubscriptions)
            .set({ stackUserId, updatedAt: sql`now()` })
            .where(
              and(
                eq(stripeSubscriptions.customerId, customerId),
                eq(stripeSubscriptions.id, effectiveSubscription.id),
                eq(stripeSubscriptions.scope, "user"),
                isNull(stripeSubscriptions.stackTeamId),
              ),
            );
        }
      }
      await upsertStripeCustomer(tx, {
        customerId,
        stackUserId,
        email: checkoutLiteralEmail(input.session, input.customer),
      });
      await upsertStripeSubscription(tx, {
        subscription: effectiveSubscription,
        customerId,
        stackUserId,
        scope: "user",
      });

      return {
        postCommitUserSync: {
          user,
          email,
          checkoutSessionId: input.session.id,
          stripeCustomerId: customerId,
          stackUserId,
          stackApp: checkoutStackApp,
          deferProMetadataUntilVerification:
            input.deferProMetadataUntilVerification,
          sendRecoveryMagicLink: input.sendRecoveryMagicLink,
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
    await syncUserCheckoutAfterCommit(
      db,
      lockedResult.postCommitUserSync,
      dependencies,
    );
  }
  if (resolvedFromAnonymousAlias) {
    const sourceToClear = remappedSourceStackUserId ?? requestedStackUserId;
    try {
      await syncStackUserMetadataWithAccountDeletionGuard({
        db,
        stackUserId: sourceToClear,
        stackApp: checkoutStackApp,
        sync: async (source, mutationLease) => {
          if (source.id !== sourceToClear) return;
          if (await hasActiveUserProSubscription(db, source.id)) return;
          await syncProPlanMetadata(source, false, mutationLease);
        },
      });
    } catch {
      // The ownership move is durable; anonymous-source cleanup can retry on
      // the next billing read without moving the customer back.
    }
    await syncResolvedStripeOwnership(
      customerId,
      effectiveSubscription.id,
      stackUserId,
      dependencies,
    );
    await resolveBillingEmailClaimsForCustomer(
      db,
      customerId,
      stackUserId,
      user,
      checkoutEmailValue,
    );
  }

  return lockedResult.result;
}

/**
 * Provision a Founder's Edition checkout that has no Stack user id in Stripe
 * metadata. The buyer email is the lookup key; all durable billing writes and
 * metadata changes remain idempotent on the Stripe customer/subscription ids.
 */
export async function recordFoundersCheckoutCompletion(
  input: CheckoutCompletionInput,
  dependencies: BillingPurchaseDependencies = {},
): Promise<FoundersCheckoutCompletionResult> {
  const providerSubscription = input.subscription ?? expandedSubscription(input.session);
  if (!isCmuxCheckoutSession(input.session, providerSubscription)) {
    throw new Error("Stripe Founder's Edition checkout is not a cmux purchase");
  }
  if (hasConflictingFounderMetadata(input.session, providerSubscription)) {
    throw new Error("Stripe Founder's Edition checkout has conflicting product metadata");
  }
  const email = checkoutEmail(input.session, input.customer);
  if (!email) {
    return {
      skipped: "no_customer_email",
      subscriptionId:
        providerSubscription?.id ??
        stringId(input.session.subscription) ??
        stringId(input.session.payment_intent) ??
        `founders_${input.session.id}`,
    };
  }

  const customerId = customerIdFromSession(input.session, input.customer);
  if (!customerId) {
    throw new Error("Stripe Founder's Edition checkout is missing a customer id");
  }
  const subscription = normalizeFounderSubscription(
    providerSubscription ?? syntheticFounderSubscription(input.session, customerId),
  );

  const stackApp = dependencies.stackApp ?? getStackServerApp();
  if (!stackApp) throw new Error("Stack Auth is not configured");
  const db = dependencies.db ?? cloudDb();
  const knownStackUserIds = [
    input.session.client_reference_id,
    input.session.metadata?.stackUserId,
    providerSubscription?.metadata?.stackUserId,
    input.customer && !input.customer.deleted
      ? input.customer.metadata?.stackUserId
      : null,
  ].filter((value): value is string => typeof value === "string" && value.length > 0);

  // A Founder payment-link checkout may not carry a Stack id. Check the
  // durable Stripe owner and its deletion tombstone before the email lookup
  // can create a new shell for an account that is being deleted.
  const mappedCustomerBeforeCreate = await stripeCustomerRowForId(db, customerId);
  if (mappedCustomerBeforeCreate?.stackTeamId != null) {
    throw new Error("Stripe Founder's Edition customer belongs to a Team");
  }
  let preResolvedOwner: StackBillingUser | null = null;
  if (mappedCustomerBeforeCreate?.stackUserId) {
    const mappedOwnerID = mappedCustomerBeforeCreate.stackUserId;
    if (await hasCheckoutBlockingAccountDeletionTombstone(mappedOwnerID, db)) {
      return {
        skipped: "account_deletion_in_progress",
        stackUserId: mappedOwnerID,
        subscriptionId: subscription.id,
      };
    }
    const mappedOwner = await loadOptionalStackUser(mappedOwnerID, stackApp);
    if (!mappedOwner || isAccountDeletionInProgress(mappedOwner)) {
      if (!mappedOwner) {
        // A missing provider user with no tombstone is an ownership conflict,
        // not permission to create a replacement identity.
        throw new Error("Stripe Founder's Edition customer ownership conflict");
      }
      return {
        skipped: "account_deletion_in_progress",
        stackUserId: mappedOwnerID,
        subscriptionId: subscription.id,
      };
    }
    if (!isCompatibleFounderOwner(mappedOwner, email)) {
      throw new Error("Stripe Founder's Edition customer ownership conflict");
    }
    preResolvedOwner = mappedOwner;
  }
  // Resolve the account without changing Stack state. Verification and
  // anonymous promotion happen later, after the deletion guard is held by the
  // metadata sync. A missing account is created as an unverified shell under a
  // canonical-email lease so concurrent paid webhooks cannot create twins.
  const user = preResolvedOwner ?? await findOrCreateCheckoutBillingUser(
      stackApp,
      db,
      email,
      knownStackUserIds,
    );
  if (!user) throw new Error("Stack Auth did not return a billing user");

  // Resolve the only potentially external owner lookup before taking the
  // database advisory lock. The locked transaction re-checks the row and
  // fails closed if ownership changed while the Stack request was in flight.
  const mappedCustomerBeforeLock = mappedCustomerBeforeCreate;
  let mappedOwnerBeforeLock: StackBillingUser | null = null;
  if (mappedCustomerBeforeLock && mappedCustomerBeforeLock.stackUserId !== user.id) {
    if (mappedCustomerBeforeLock.stackTeamId != null) {
      throw new Error("Stripe Founder's Edition customer ownership conflict");
    }
    mappedOwnerBeforeLock = await loadOptionalStackUser(
      mappedCustomerBeforeLock.stackUserId,
      stackApp,
    );
    if (
      !mappedOwnerBeforeLock ||
      isAccountDeletionInProgress(mappedOwnerBeforeLock) ||
      !isCompatibleFounderOwner(mappedOwnerBeforeLock, email)
    ) {
      throw new Error("Stripe Founder's Edition customer ownership conflict");
    }
  }
  const lockedResult = await withAccountDeletionUserLock(
    db,
    user.id,
    async (tx): Promise<
      | {
          result: FoundersCheckoutCompletionResult;
          postCommit: boolean;
          remappedSourceStackUserId?: string;
        }
    > => {
      if (
        await hasCheckoutBlockingAccountDeletionTombstone(user.id, tx) ||
        isAccountDeletionInProgress(user)
      ) {
        return {
          result: {
            skipped: "account_deletion_in_progress",
            stackUserId: user.id,
            subscriptionId: subscription.id,
          },
          postCommit: false,
        };
      }

      const mappedCustomer = await stripeCustomerRowForId(tx, customerId);
      let remappedSourceStackUserId: string | undefined;
      if (mappedCustomer && mappedCustomer.stackUserId !== user.id) {
        if (mappedCustomer.stackTeamId != null) {
          throw new Error("Stripe Founder's Edition customer ownership conflict");
        }
        if (
          !mappedCustomerBeforeLock ||
          mappedCustomerBeforeLock.stackUserId !== mappedCustomer.stackUserId ||
          (mappedCustomerBeforeLock.stackTeamId ?? null) !==
            (mappedCustomer.stackTeamId ?? null) ||
          mappedOwnerBeforeLock?.id !== mappedCustomer.stackUserId
        ) {
          throw new Error("Stripe Founder's Edition customer ownership conflict");
        }
        if (
          await hasCheckoutBlockingAccountDeletionTombstone(
            mappedCustomer.stackUserId,
            tx,
          )
        ) {
          throw new Error("Stripe Founder's Edition customer ownership conflict");
        }
        // The two Stack accounts represent the same canonical mailbox (most
        // commonly a dotted Gmail duplicate). Move only the local billing rows;
        // account merge/deletion remains an operator follow-up.
        await tx
          .update(stripeCustomers)
          .set({ stackUserId: user.id, updatedAt: sql`now()` })
          .where(eq(stripeCustomers.id, customerId));
        await tx
          .update(stripeSubscriptions)
          .set({ stackUserId: user.id, updatedAt: sql`now()` })
          .where(
            and(
              eq(stripeSubscriptions.customerId, customerId),
              eq(stripeSubscriptions.id, subscription.id),
              eq(stripeSubscriptions.scope, "user"),
              isNull(stripeSubscriptions.stackTeamId),
            ),
          );
        remappedSourceStackUserId = mappedCustomer.stackUserId;
      }

      await upsertStripeCustomer(tx, {
        customerId,
        stackUserId: user.id,
        // Keep the exact Stripe spelling for audit; account matching uses the
        // canonical form separately.
        email: checkoutLiteralEmail(input.session, input.customer),
      });
      await upsertStripeSubscription(tx, {
        subscription,
        customerId,
        stackUserId: user.id,
        scope: "user",
      });
      return {
        result: {
          scope: "user",
          stackUserId: user.id,
          subscriptionId: subscription.id,
        },
        postCommit: true,
        ...(remappedSourceStackUserId
          ? { remappedSourceStackUserId }
          : {}),
      };
    },
  );

  if (!lockedResult.postCommit || !("scope" in lockedResult.result)) {
    return lockedResult.result;
  }

  await syncStackUserMetadataWithAccountDeletionGuard({
    db,
    stackUserId: user.id,
    stackApp,
    sync: async (freshUser, mutationLease) => {
      // A newly-created user already has an email, while an older account may
      // still need the literal Stripe address attached. Neither path marks the
      // channel verified until Stack accepts the recipient's link.
      await attachPurchaseEmailOrRecordClaim(
        db,
        {
          user: freshUser,
          email,
          checkoutSessionId: input.session.id,
          stripeCustomerId: customerId,
          stackUserId: user.id,
          stackApp,
        },
        mutationLease,
        dependencies,
      );
      // Payment identifies a purchase, but it does not prove mailbox control.
      // Re-read after attaching or promoting the channel, then grant the
      // Founder entitlement only when Stack reports a verified ordinary owner.
      const entitlementUser = await stackApp.getUser(user.id);
      if (entitlementUser && isVerifiedCanonicalBillingOwner(entitlementUser, email)) {
        await syncProPlanMetadata(entitlementUser, true, mutationLease);
        await enrollFounderTester(
          input.enrollmentEmail?.trim() || email,
          checkoutCustomerName(input.session, input.customer),
          dependencies,
        );
      } else {
        await mutationLease.refresh();
        await recordBillingEmailClaim(db, {
          email,
          stripeCustomerId: customerId,
          stackUserId: user.id,
        });
      }
      if (input.sendRecoveryMagicLink) {
        await requestPurchaseMagicLink(
          db,
          {
            email,
            checkoutSessionId: input.session.id,
            stackUserId: user.id,
            stackApp,
          },
          mutationLease,
          dependencies,
        );
      }
    },
  });

  if (lockedResult.remappedSourceStackUserId) {
    try {
      await syncStackUserMetadataWithAccountDeletionGuard({
        db,
        stackUserId: lockedResult.remappedSourceStackUserId,
        stackApp,
        sync: async (source, mutationLease) => {
          if (await hasActiveUserProSubscription(db, source.id)) return;
          await syncProPlanMetadata(source, false, mutationLease);
        },
      });
    } catch {
      // The ownership move is durable; stale source metadata can be repaired
      // on the next billing read or by the manual duplicate-account cleanup.
    }
    await syncResolvedStripeOwnership(
      customerId,
      subscription.id,
      user.id,
      dependencies,
    );
  }

  await resolveBillingEmailClaimsForCustomer(
    db,
    customerId,
    user.id,
    user,
    email,
  );
  return lockedResult.result;
}

/**
 * Provision a paid Pro checkout when its original anonymous Stack id is no
 * longer usable. Recovery and the lockout backfill call this same boundary so
 * they cannot diverge from webhook behavior.
 */
export async function recordProCheckoutCompletionByEmail(
  input: CheckoutCompletionInput,
  dependencies: BillingPurchaseDependencies = {},
): Promise<
  | CheckoutCompletionResult
  | FoundersCheckoutCompletionResult
  | DeferredCheckoutCompletionResult
> {
  const session = input.session;
  const subscription = input.subscription ?? expandedSubscription(session);
  if (!isCmuxCheckoutSession(session, subscription)) {
    throw new Error("Stripe Pro checkout is not a cmux purchase");
  }
  if (isFounderCheckoutMetadata(session.metadata, subscription)) {
    return recordFoundersCheckoutCompletion(input, dependencies);
  }

  const email = checkoutEmail(session, input.customer);
  if (!email) {
    if (!subscription) throw new Error("Stripe Pro checkout is missing a subscription");
    return { skipped: "no_customer_email", subscriptionId: subscription.id };
  }
  const customerId = customerIdFromSession(session, input.customer);
  if (!customerId) throw new Error("Stripe Pro checkout is missing a customer id");
  if (!subscription) throw new Error("Stripe Pro checkout is missing a subscription");
  const stackApp = dependencies.stackApp ?? getStackServerApp();
  if (!stackApp) throw new Error("Stack Auth is not configured");
  const db = dependencies.db ?? cloudDb();
  const knownStackUserIds = [
    session.client_reference_id,
    session.metadata?.stackUserId,
    subscription.metadata?.stackUserId,
    input.customer && !input.customer.deleted
      ? input.customer.metadata?.stackUserId
      : null,
  ].filter((value): value is string => typeof value === "string" && value.length > 0);
  const existingUser = await findOrCreateCheckoutBillingUser(
    stackApp,
    db,
    email,
    knownStackUserIds,
  );
  if (!existingUser) throw new Error("Stack Auth did not return a billing user");

  // Recovery may need to create a destination account before the mailbox is
  // verified. If Stripe still belongs to an anonymous checkout account, keep
  // the paid rows on that source and create a claim. Moving them to an
  // unverified destination would either fail closed or grant ownership before
  // the recipient proves control of the address.
  if (existingUser.primaryEmailVerified !== true) {
    const mappedCustomer = await stripeCustomerRowForId(db, customerId);
    if (mappedCustomer?.stackTeamId != null) {
      throw new Error("Stripe checkout customer belongs to a Team");
    }
    if (
      mappedCustomer &&
      mappedCustomer.stackUserId !== existingUser.id
    ) {
      const source = await loadOptionalStackUser(mappedCustomer.stackUserId, stackApp);
      if (
        !source ||
        source.isAnonymous !== true ||
        isAccountDeletionInProgress(source) ||
        (await hasCheckoutBlockingAccountDeletionTombstone(source.id, db))
      ) {
        throw new Error("Stripe checkout customer ownership conflict");
      }
      const sourceSession = {
        ...session,
        client_reference_id: source.id,
        metadata: {
          ...(session.metadata ?? {}),
          app: "cmux",
          plan: PRO_PLAN_ID,
          stackUserId: source.id,
        },
      } as Stripe.Checkout.Session;
      const sourceSubscription = {
        ...subscription,
        metadata: {
          ...subscription.metadata,
          app: "cmux",
          plan: PRO_PLAN_ID,
          stackUserId: source.id,
        },
      } as Stripe.Subscription;
      const parked = await recordCheckoutCompletion(
        {
          ...input,
          session: sourceSession,
          subscription: sourceSubscription,
          allowCanonicalOwnershipRecovery: false,
          deferAnonymousCanonicalOwnerResolution: true,
        },
        dependencies,
      );
      if ("skipped" in parked) return parked;
      if (parked.scope !== "user") {
        throw new Error("Stripe checkout customer ownership conflict");
      }
      return {
        deferred: "email_verification",
        stackUserId: source.id,
        subscriptionId: subscription.id,
        deliveryEmail: email,
      };
    }
  }

  const rewrittenSession = {
    ...session,
    client_reference_id: existingUser.id,
    metadata: {
      ...(session.metadata ?? {}),
      app: "cmux",
      plan: "pro",
      stackUserId: existingUser.id,
    },
  } as Stripe.Checkout.Session;
  // Keep the original session object for audit and email callers; only the
  // shared recorder needs the resolved Stack reference.
  const result = await recordCheckoutCompletion(
    {
      session: rewrittenSession,
      subscription: {
        ...subscription,
        metadata: {
          ...subscription.metadata,
          app: "cmux",
          plan: "pro",
          stackUserId: existingUser.id,
        },
      },
      customer: input.customer,
      allowCanonicalOwnershipRecovery: true,
      deferProMetadataUntilVerification:
        existingUser.primaryEmailVerified !== true,
      sendRecoveryMagicLink: input.sendRecoveryMagicLink,
    },
    dependencies,
  );
  if (!("skipped" in result) && existingUser.primaryEmailVerified !== true) {
    return {
      deferred: "email_verification",
      stackUserId: existingUser.id,
      subscriptionId: subscription.id,
      deliveryEmail: email,
    };
  }
  if (!("skipped" in result)) {
    await resolveBillingEmailClaimsForCustomer(
      db,
      customerId,
      existingUser.id,
      existingUser,
      email,
    );
    await syncResolvedStripeOwnership(
      customerId,
      subscription.id,
      existingUser.id,
      dependencies,
    );
  }
  return result;
}

async function resolveBillingEmailClaimsForCustomer(
  db: BillingDb,
  customerId: string,
  targetStackUserId: string,
  targetUser: ProBillingClaimUser | null | undefined,
  email?: string | null,
): Promise<void> {
  const verifiedTargetEmail = targetUser ? verifiedClaimEmail(targetUser) : null;
  if (
    !verifiedTargetEmail ||
    !email ||
    canonicalizeEmailForMatching(email) !== verifiedTargetEmail
  ) {
    // A paid checkout can create an unverified shell. It must not consume a
    // claim because only Stack verification proves that this user controls the
    // mailbox and may receive ownership.
    return;
  }
  const basePredicate = and(
    eq(billingEmailClaims.stripeCustomerId, customerId),
    eq(billingEmailClaims.plan, PRO_PLAN_ID),
    isNull(billingEmailClaims.claimedByUserId),
  );
  // Claims written by older deployments may retain dotted Gmail spelling.
  // Restrict the read in SQL, then compare canonically for those legacy rows so
  // a recovery for one mailbox cannot consume an unrelated claim.
  const matchingEmail = canonicalizeEmailForMatching(email);
  const literalEmail = email.trim().toLowerCase();
  const rows = await db
    .select({ id: billingEmailClaims.id, email: billingEmailClaims.email })
    .from(billingEmailClaims)
    .where(
      and(
        basePredicate,
        or(
          ...emailVariantsForMatching(literalEmail).map((variant) =>
            eq(billingEmailClaims.email, variant),
          ),
          sql`btrim(lower(${billingEmailClaims.email})) = ${literalEmail}`,
        ),
      ),
    )
    .limit(100);
  for (const row of rows) {
    if (canonicalizeEmailForMatching(row.email) !== matchingEmail) continue;
    await db
      .update(billingEmailClaims)
      .set({ claimedByUserId: targetStackUserId, claimedAt: new Date() })
      .where(
        and(
          eq(billingEmailClaims.id, row.id),
          isNull(billingEmailClaims.claimedByUserId),
        ),
      );
  }
}

/**
 * Resolve a checkout account without changing an existing Stack identity.
 *
 * Mailbox verification and anonymous promotion run only after Stack confirms
 * the email channel. A new account starts as an unverified shell under a
 * canonical-email lease; the post-commit mutation can attach the channel and
 * send a sign-in link, but it never marks an existing mailbox as verified.
 */
async function findOrCreateCheckoutBillingUser(
  stackApp: StackBillingApp,
  db: BillingDb,
  email: string,
  knownStackUserIds: readonly string[] = [],
): Promise<StackBillingUser> {
  const existing = await findBillingUserByEmail(stackApp, email);
  if (existing) return existing;
  if (!stackApp.createUser) {
    throw new Error("Stack Auth server SDK cannot create users");
  }

  const emailLockKey = `billing-email:${canonicalizeEmailForMatching(email)}`;
  try {
    return await withAccountDeletionUserMutation(
      db,
      emailLockKey,
      async (lease) => {
        // A concurrent webhook may have created the canonical account while
        // the first read was in flight. Re-read while the email lease is held
        // before creating another identity.
        const raced = await findBillingUserByEmail(stackApp, email);
        if (raced) return raced;

        const deletionBlocked = await hasCheckoutBlockingAccountDeletionForUsers(
          knownStackUserIds,
          db,
        );
        if (deletionBlocked) {
          throw new AccountDeletionMutationBlockedError(
            knownStackUserIds[0] ?? emailLockKey,
          );
        }

        await lease.refresh();
        try {
          return await createUnverifiedCheckoutUser(stackApp, email);
        } catch (error) {
          // Stack enforces a unique email independently of our lease. If a
          // different worker won that race, return its account and let the
          // deletion-guarded post-commit mutation finish provisioning it.
          if (!isEmailAlreadyUsedError(error)) throw error;
          const winner = await findBillingUserByEmail(stackApp, email);
          if (winner) return winner;
          throw error;
        }
      },
    );
  } catch (error) {
    if (error instanceof AccountDeletionMutationBlockedError) {
      throw new Error("Checkout account creation is blocked by account deletion", {
        cause: error,
      });
    }
    throw error;
  }
}

async function createUnverifiedCheckoutUser(
  stackApp: StackBillingApp,
  email: string,
): Promise<StackBillingUser> {
  const primaryEmail = email.trim();
  try {
    return await stackApp.createUser!({
      primaryEmail,
      // Auth may be requested before verification. Stack keeps the account
      // restricted until the one-time link proves control of this channel.
      primaryEmailAuthEnabled: true,
      primaryEmailVerified: false,
    });
  } catch (error) {
    // Older Stack SDKs can reject the explicit verification field. The
    // primary-email create still starts an unverified shell; the next read
    // determines whether a verification message is needed.
    if (!isUnsupportedVerificationFieldError(error)) throw error;
    return await stackApp.createUser!({
      primaryEmail,
      primaryEmailAuthEnabled: true,
    });
  }
}

/** Find an existing account by canonical billing email, or create one. */
export async function findOrCreateBillingUser(
  stackApp: StackBillingApp,
  email: string,
): Promise<StackBillingUser> {
  const existing = await findBillingUserByEmail(stackApp, email);
  if (existing) {
    // Stripe proves payment, not control of the mailbox. Leave an existing
    // account's verification and auth state unchanged until Stack completes
    // its own email or magic-link verification flow.
    return existing;
  }
  if (!stackApp.createUser) {
    throw new Error("Stack Auth server SDK cannot create users");
  }

  const trimmedEmail = email.trim();
  try {
    return await createUnverifiedCheckoutUser(stackApp, trimmedEmail);
  } catch (error) {
    // Another webhook can win the canonical-email race. Re-read before
    // surfacing the create failure so retries remain idempotent.
    if (!isEmailAlreadyUsedError(error)) throw error;
    const raced = await findBillingUserByEmail(stackApp, email);
    if (raced) return raced;
    throw error;
  }
}

/** Find a mutable Stack user using Gmail-aware canonical matching. */
export async function findBillingUserByEmail(
  stackApp: StackBillingApp,
  email: string,
): Promise<StackBillingUser | null> {
  const listUsers = stackApp.listUsers;
  if (!listUsers) {
    throw new Error("Stack Auth server SDK cannot list users");
  }
  // Stack's implementation reads private state through `this`; keep the
  // receiver when passing the method to the paginated lookup helper.
  const boundListUsers = listUsers.bind(stackApp);
  const matchingEmail = canonicalizeEmailForMatching(email);
  const literalEmail = email.trim().toLowerCase();
  const queries = emailVariantsForMatching(literalEmail);
  const candidateByID = new Map<string, StackBillingUserLookup>();
  for (const query of queries) {
    await collectBillingUserLookupCandidates(
      boundListUsers,
      query,
      matchingEmail,
      candidateByID,
      20,
    );
  }
  if (candidateByID.size === 0 && isGmailAddress(literalEmail)) {
    // Stack's free-text query is literal and does not understand Gmail's
    // dot-insensitive namespace. Scan the provider's paginated user list as a
    // bounded fallback, then apply the canonical comparison locally. An
    // incomplete scan fails closed instead of creating the wrong account.
    await collectBillingUserLookupCandidates(
      boundListUsers,
      undefined,
      matchingEmail,
      candidateByID,
      STACK_USER_LOOKUP_PAGE_SIZE,
    );
  }
  const candidates = [...candidateByID.values()].sort(compareStackUserLookup);
  for (const candidate of candidates) {
    if (typeof candidate.update === "function") {
      return candidate as StackBillingUser;
    }
    const user = await stackApp.getUser(candidate.id);
    if (user) return user;
  }
  return null;
}

/**
 * Resolve pending billing-email claims for a verified Stack account.
 *
 * Claims are only created when an anonymous checkout could not attach its
 * email. A verified destination account can consume them later; an email
 * string by itself is never treated as ownership proof.
 */
export async function claimPendingProBilling(
  user: ProBillingClaimUser,
  dependencies: BillingPurchaseDependencies = {},
): Promise<{ readonly claimed: number }> {
  const email = verifiedClaimEmail(user);
  if (!email) return { claimed: 0 };
  let stackApp: StackBillingApp | null = dependencies.stackApp ?? null;
  if (!stackApp) {
    try {
      stackApp = getStackServerApp();
    } catch {
      return { claimed: 0 };
    }
  }
  if (!stackApp) return { claimed: 0 };
  const db = dependencies.db ?? cloudDb();
  const repository =
    dependencies.ownershipRepository ?? makeBillingOwnershipRepository(db);
  const claims = await repository.findClaims(email, user.id);
  let claimed = 0;
  let founderClaimed = false;

  for (const claim of claims) {
    if (claim.claimedByUserId) continue;
    // Keep this check at the consumer boundary as well as in the SQL-backed
    // repository. Custom recovery readers and stale deployments must not be
    // able to turn an unrelated claim into a billing ownership transfer.
    if (canonicalizeEmailForMatching(claim.email) !== email) continue;
    const source = await stackApp.getUser(claim.stackUserId);
    if (!source || (source.id !== user.id && source.isAnonymous !== true)) {
      continue;
    }
    const transfer = await repository.transferClaim(claim, user.id);
    if (!transfer) continue;
    claimed += 1;
    founderClaimed ||= (transfer.founderSubscriptionIds?.length ?? 0) > 0;
    await clearTransferredSourceProMetadata(transfer, db, stackApp);
    await syncTransferredStripeOwnership(transfer, dependencies.stripeClient ?? stripe);
  }
  // A claim is marked consumed before external Stripe and TestFlight calls so
  // ownership cannot be taken twice. Re-check the durable Founder row on each
  // verified billing read, which gives a failed TestFlight call a safe retry
  // path after the claim itself has already been consumed.
  const founderPurchasePending =
    founderClaimed || (await hasActiveFounderSubscription(db, user.id));
  if (claimed > 0 || founderPurchasePending) {
    // Ownership transfer and entitlement metadata are separate stores. Refresh
    // the destination under the same account-deletion guard used by webhook
    // fulfillment so a recovered account is immediately recognized as Pro.
    let entitlementReady = false;
    await syncStackUserMetadataWithAccountDeletionGuard({
      db,
      stackUserId: user.id,
      stackApp,
      sync: async (freshUser, lease) => {
        if (
          freshUser.isAnonymous === true ||
          freshUser.isRestricted === true ||
          freshUser.primaryEmailVerified !== true ||
          isAccountDeletionInProgress(freshUser) ||
          canonicalizeEmailForMatching(freshUser.primaryEmail ?? "") !== email
        ) {
          return;
        }
        await syncProPlanMetadata(freshUser, true, lease);
        entitlementReady = true;
      },
    });
    if (founderPurchasePending && entitlementReady) {
      // TestFlight enrollment is an external side effect. Keep it after the
      // verified metadata write, and make it idempotent so a failed attempt can
      // be retried by the next authenticated billing read.
      await enrollFounderTester(user.primaryEmail?.trim() || email, undefined, dependencies);
    }
  }
  return { claimed };
}

/**
 * Move a known Stripe customer's local ownership to an explicitly selected
 * Stack account. This is reserved for audited recovery/backfill cases (such
 * as the Gmail dotted-address duplicate) and never deletes or merges Stack
 * accounts.
 */
export async function remapBillingOwnershipForRecovery(
  input: {
    readonly customerId: string;
    readonly subscriptionIds: readonly string[];
    readonly targetStackUserId: string;
    readonly email?: string | null;
  },
  dependencies: BillingPurchaseDependencies = {},
): Promise<void> {
  const db = dependencies.db ?? cloudDb();
  await withAccountDeletionUserLock(db, input.targetStackUserId, async (tx) => {
    const [targetCustomer] = await tx
      .select({ id: stripeCustomers.id })
      .from(stripeCustomers)
      .where(
        and(
          eq(stripeCustomers.stackUserId, input.targetStackUserId),
          isNull(stripeCustomers.stackTeamId),
        ),
      )
      .limit(1);
    if (targetCustomer && targetCustomer.id !== input.customerId) {
      throw new Error("Recovery target already owns a different Stripe customer");
    }

    const [sourceCustomer] = await tx
      .select({
        id: stripeCustomers.id,
        stackTeamId: stripeCustomers.stackTeamId,
      })
      .from(stripeCustomers)
      .where(eq(stripeCustomers.id, input.customerId))
      .limit(1);
    if (sourceCustomer && sourceCustomer.stackTeamId != null) {
      throw new Error("Recovery cannot remap a Team Stripe customer");
    }

    await tx
      .update(stripeCustomers)
      .set({
        stackUserId: input.targetStackUserId,
        ...(input.email === undefined ? {} : { email: input.email }),
        updatedAt: sql`now()`,
      })
      .where(eq(stripeCustomers.id, input.customerId));
    if (input.subscriptionIds.length > 0) {
      await tx
        .update(stripeSubscriptions)
        .set({ stackUserId: input.targetStackUserId, updatedAt: sql`now()` })
        .where(
          and(
            inArray(stripeSubscriptions.id, [...input.subscriptionIds]),
            eq(stripeSubscriptions.customerId, input.customerId),
            eq(stripeSubscriptions.scope, "user"),
            isNull(stripeSubscriptions.stackTeamId),
          ),
        );
    }
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
  const email = user.primaryEmail?.trim();
  return email && email.includes("@")
    ? canonicalizeEmailForMatching(email)
    : null;
}

function makeBillingOwnershipRepository(
  db: BillingDb,
): BillingOwnershipRepository {
  return {
    findClaims: async (email) => {
      const matchingEmail = canonicalizeEmailForMatching(email);
      const literalEmail = email.trim().toLowerCase();
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
            eq(billingEmailClaims.plan, PRO_PLAN_ID),
            isNull(billingEmailClaims.claimedByUserId),
            or(
              ...emailVariantsForMatching(literalEmail).map((variant) =>
                eq(billingEmailClaims.email, variant),
              ),
              sql`btrim(lower(${billingEmailClaims.email})) = ${literalEmail}`,
            ),
          ),
        )
        .limit(100);
      return rows.filter(
        (row) => canonicalizeEmailForMatching(row.email) === matchingEmail,
      );
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
  return db.transaction(async (tx) => {
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
    if (!freshClaim || freshClaim.claimedByUserId) return null;

    if (
      await hasCheckoutBlockingAccountDeletionTombstone(sourceStackUserId, accountTx) ||
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
      return null;
    }

    const sourceCustomer = await accountTx
      .select({ id: stripeCustomers.id })
      .from(stripeCustomers)
      .where(
        and(
          eq(stripeCustomers.id, freshClaim.stripeCustomerId),
          eq(stripeCustomers.stackUserId, sourceStackUserId),
          isNull(stripeCustomers.stackTeamId),
        ),
      )
      .limit(1);
    const sourceSubscriptions = await accountTx
      .select({
        id: stripeSubscriptions.id,
        status: stripeSubscriptions.status,
        raw: stripeSubscriptions.raw,
      })
      .from(stripeSubscriptions)
      .where(
        and(
          eq(stripeSubscriptions.customerId, freshClaim.stripeCustomerId),
          eq(stripeSubscriptions.stackUserId, sourceStackUserId),
          eq(stripeSubscriptions.scope, "user"),
          eq(stripeSubscriptions.plan, PRO_PLAN_ID),
          isNull(stripeSubscriptions.stackTeamId),
        ),
      )
      .limit(100);
    if (
      sourceCustomer.length === 0 ||
      !sourceSubscriptions.some((row) =>
        isActiveStripeSubscriptionStatus(row.status),
      )
    ) {
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
      .limit(100);
    const sourceSubscriptionIDs = sourceSubscriptions.map((row) => row.id);
    const founderSubscriptionIds = sourceSubscriptions
      .filter((row) => isFounderSubscriptionRaw(row.raw))
      .map((row) => row.id);
    const sourceSubscriptionIDSet = new Set(sourceSubscriptionIDs);
    if (
      targetSubscriptions.some(
        (row) =>
          isActiveStripeSubscriptionStatus(row.status) &&
          !sourceSubscriptionIDSet.has(row.id),
      )
    ) {
      return null;
    }

    const now = new Date();
    await accountTx
      .update(stripeCustomers)
      .set({ stackUserId: targetStackUserId, updatedAt: now })
      .where(
        and(
          eq(stripeCustomers.id, freshClaim.stripeCustomerId),
          eq(stripeCustomers.stackUserId, sourceStackUserId),
          isNull(stripeCustomers.stackTeamId),
        ),
      );
    await accountTx
      .update(stripeSubscriptions)
      .set({ stackUserId: targetStackUserId, updatedAt: now })
      .where(
        and(
          eq(stripeSubscriptions.customerId, freshClaim.stripeCustomerId),
          eq(stripeSubscriptions.stackUserId, sourceStackUserId),
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
      subscriptionIds: sourceSubscriptionIDs,
      ...(founderSubscriptionIds.length > 0 ? { founderSubscriptionIds } : {}),
      sourceStackUserId,
      targetStackUserId,
    };
  });
}

async function clearTransferredSourceProMetadata(
  transfer: BillingOwnershipTransfer,
  db: BillingDb,
  stackApp: StackBillingApp,
): Promise<void> {
  if (transfer.sourceStackUserId === transfer.targetStackUserId) return;
  try {
    await syncStackUserMetadataWithAccountDeletionGuard({
      db,
      stackUserId: transfer.sourceStackUserId,
      stackApp,
      sync: async (source, lease) => {
        if (await hasActiveUserProSubscription(db, source.id)) return;
        await syncProPlanMetadata(source, false, lease);
      },
    });
  } catch {
    // The durable transfer already succeeded; source cleanup is retryable.
  }
}

async function syncTransferredStripeOwnership(
  transfer: BillingOwnershipTransfer,
  clientFactory: () => StripeBillingClient,
): Promise<void> {
  try {
    const client = clientFactory();
    const customer = await client.customers.retrieve(transfer.customerId);
    if (customer.deleted) return;
    await client.customers.update(transfer.customerId, {
      metadata: {
        ...customer.metadata,
        app: "cmux",
        plan: PRO_PLAN_ID,
        stackUserId: transfer.targetStackUserId,
      },
    });
    for (const subscriptionId of transfer.subscriptionIds) {
      const subscription = await client.subscriptions.retrieve(subscriptionId);
      if (stringId(subscription.customer) !== transfer.customerId) continue;
      await client.subscriptions.update(subscriptionId, {
        metadata: {
          ...subscription.metadata,
          app: "cmux",
          plan: PRO_PLAN_ID,
          stackUserId: transfer.targetStackUserId,
        },
      });
    }
  } catch {
    // Local ownership is authoritative; Stripe metadata can be repaired on a
    // later reconciliation without blocking sign-in.
  }
}

async function syncResolvedStripeOwnership(
  customerId: string,
  subscriptionId: string,
  stackUserId: string,
  dependencies: BillingPurchaseDependencies,
): Promise<void> {
  // Local rows are authoritative for the current request. Repair provider
  // metadata best-effort so later out-of-order subscription events map to the
  // canonical account instead of the temporary anonymous checkout id.
  try {
    const client = (dependencies.stripeClient ?? stripe)();
    const customer = await client.customers.retrieve(customerId);
    if (!customer.deleted) {
      await client.customers.update(customerId, {
        metadata: {
          ...customer.metadata,
          app: "cmux",
          plan: PRO_PLAN_ID,
          stackUserId,
        },
      });
    }
    const subscription = await client.subscriptions.retrieve(subscriptionId);
    if (stringId(subscription.customer) !== customerId) return;
    await client.subscriptions.update(subscriptionId, {
      metadata: {
        ...subscription.metadata,
        app: "cmux",
        plan: PRO_PLAN_ID,
        stackUserId,
      },
    });
  } catch {
    // A later webhook/reconciliation can repair provider metadata safely.
  }
}

async function enrollFounderTester(
  email: string,
  customerName: string | null | undefined,
  dependencies: BillingPurchaseDependencies,
): Promise<void> {
  const nameParts = (customerName ?? "").trim().split(/\s+/).filter(Boolean);
  const firstName = nameParts[0];
  const lastName = nameParts.length > 1 ? nameParts.slice(1).join(" ") : undefined;
  const injected = dependencies.testflight?.enrollTester;
  if (injected) {
    try {
      await injected(email, firstName, lastName);
    } catch (error) {
      if (!isTesterAlreadyExistsError(error)) throw error;
    }
    return;
  }
  const configured = dependencies.testflight?.isAscConfigured ?? isAscConfigured;
  if (!configured()) return;
  await enrollTester(email, firstName, lastName);
}

function isTesterAlreadyExistsError(error: unknown): boolean {
  const status =
    error && typeof error === "object" && "status" in error
      ? (error as { status?: unknown }).status
      : undefined;
  if (status === 409 || status === "409") return true;
  const message = error instanceof Error ? error.message : String(error);
  return /already\s+(exists|added|enrolled)|duplicate/i.test(message);
}

function syntheticFounderSubscription(
  session: Stripe.Checkout.Session,
  customerId: string,
): Stripe.Subscription {
  const id =
    stringId(session.subscription) ??
    stringId(session.payment_intent) ??
    `founders_${session.id}`;
  return {
    id,
    object: "subscription",
    customer: customerId,
    status: "active",
    metadata: {
      ...(session.metadata ?? {}),
      founders_edition: "true",
    },
    cancel_at_period_end: false,
    items: { object: "list", data: [], has_more: false, url: "" },
  } as unknown as Stripe.Subscription;
}

function normalizeFounderSubscription(
  subscription: Stripe.Subscription,
): Stripe.Subscription {
  // Founder's Edition is a paid entitlement, not a renewable service. Stripe
  // may expose a cancelled (or otherwise non-active) duplicate subscription
  // in its history; the caller has already required a paid checkout, so
  // recording that completed purchase as active keeps the local Pro
  // entitlement durable while preserving the provider object in `raw` for
  // audit.
  return {
    ...subscription,
    status: "active",
    metadata: {
      ...(subscription.metadata ?? {}),
      founders_edition: "true",
    },
  } as Stripe.Subscription;
}

async function syncUserCheckoutAfterCommit(
  db: BillingDb,
  input: UserCheckoutPostCommitSync,
  dependencies: BillingPurchaseDependencies,
): Promise<void> {
  await syncStackUserMetadataWithAccountDeletionGuard({
    db,
    stackUserId: input.stackUserId,
    stackApp: input.stackApp,
    sync: async (user, mutationLease) => {
      if (input.email) {
        await attachPurchaseEmailOrRecordClaim(
          db,
          {
            user,
            email: input.email,
            checkoutSessionId: input.checkoutSessionId,
            stripeCustomerId: input.stripeCustomerId,
            stackUserId: input.stackUserId,
            stackApp: input.stackApp,
          },
          mutationLease,
          dependencies,
        );
      }
      if (input.deferProMetadataUntilVerification) {
        // Keep a durable claim even when the provisional rows already belong
        // to this unverified account. The post-verification callback can then
        // atomically mark the claim, repair Stripe metadata, and enable Pro.
        if (input.email) {
          await mutationLease.refresh();
          await recordBillingEmailClaim(db, {
            email: input.email,
            stripeCustomerId: input.stripeCustomerId,
            stackUserId: input.stackUserId,
          });
          if (input.sendRecoveryMagicLink) {
            await requestPurchaseMagicLink(
              db,
              {
                email: input.email,
                checkoutSessionId: input.checkoutSessionId,
                stackUserId: input.stackUserId,
                stackApp: input.stackApp,
              },
              mutationLease,
              dependencies,
            );
          }
        }
        return;
      }
      await syncProPlanMetadata(user, true, mutationLease);
      if (input.sendRecoveryMagicLink && input.email) {
        await requestPurchaseMagicLink(
          db,
          {
            email: input.email,
            checkoutSessionId: input.checkoutSessionId,
            stackUserId: input.stackUserId,
            stackApp: input.stackApp,
          },
          mutationLease,
          dependencies,
        );
      }
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
  // Founder's Edition is a one-time purchase. Its payment-link checkout may
  // have produced a provider subscription that was later cancelled; never let
  // that provider lifecycle revoke the durable paid Founder entitlement.
  if (subscription.metadata?.founders_edition === "true") return { skipped: true };
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
    await syncTeamPlanMetadata(team, isActive, subscriptionSeats(subscription));
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
      const userSubscription = await userStripeSubscriptionState(tx, {
        subscriptionId: subscription.id,
        stackUserId,
      });
      if (userSubscription.isFounder) return { skipped: true };
      const hasUserSubscription = userSubscription.exists;
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
    stackApp: dependencies.stackApp ?? getStackServerApp(),
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

async function hasCheckoutBlockingAccountDeletionForUsers(
  stackUserIds: readonly string[],
  db: BillingDbClient,
): Promise<boolean> {
  const hashes = [
    ...new Set(
      stackUserIds
        .filter((stackUserId) => stackUserId.length > 0)
        .map(accountDeletionUserHash),
    ),
  ];
  if (hashes.length === 0) return false;
  const tombstones = await db
    .select({
      userIdHash: accountDeletionTombstones.userIdHash,
      status: accountDeletionTombstones.status,
      updatedAt: accountDeletionTombstones.updatedAt,
    })
    .from(accountDeletionTombstones)
    .where(inArray(accountDeletionTombstones.userIdHash, hashes))
    .limit(hashes.length);
  return tombstones.some((tombstone) => isBlockingAccountDeletionTombstone(tombstone));
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
  const stackApp = input.stackApp ?? getStackServerApp();
  if (!stackApp) throw new Error("Stack Auth is not configured");
  const loader: AccountMetadataUserLoader<StackBillingUser> = {
    getUser: (requestedUserId) => stackApp.getUser(requestedUserId),
  };
  return await withFreshAccountMetadataUser({
    db: input.db,
    userId: input.stackUserId,
    loader,
    operation: async (freshUser, mutationLease) => {
      if (
        !freshUser ||
        freshUser.id !== input.stackUserId ||
        isAccountDeletionInProgress(freshUser)
      ) return false;
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
  if (subscriptionId) {
    const rows = await db
      .select()
      .from(stripeSubscriptions)
      .where(eq(stripeSubscriptions.id, subscriptionId))
      .limit(1);
    // A concrete Stripe subscription id is an exact read key. Never replace a
    // missing or delayed row with another subscription for the same customer.
    return rows[0] ?? null;
  }

  // Founder's Edition payment-link sessions are one-time payments and often
  // have no Stripe subscription id. Only an explicitly marked Founder session
  // may use the synthetic customer fallback. A Pro checkout without a
  // subscription id must not inherit an unrelated customer subscription.
  if (!isFounderCheckoutMetadata(session.metadata, subscription)) return null;
  const customerId = customerIdFromSession(session, expandedCustomerForLookup(session));
  if (!customerId) return null;
  const rows = await db
    .select()
    .from(stripeSubscriptions)
    .where(
      and(
        eq(stripeSubscriptions.customerId, customerId),
        eq(stripeSubscriptions.plan, PRO_PLAN_ID),
        eq(stripeSubscriptions.scope, "user"),
        isNull(stripeSubscriptions.stackTeamId),
        sql`${stripeSubscriptions.raw}->'metadata'->>'founders_edition' = 'true'`,
      ),
    )
    .orderBy(desc(stripeSubscriptions.updatedAt))
    .limit(1);
  // Keep the application-side check as a second fence for test doubles and
  // databases that contain legacy rows with a nullable or malformed JSON
  // value. A normal Pro row must never satisfy a Founder success read-back.
  return rows.find((row) => isFounderSubscriptionRaw(row.raw)) ?? null;
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
  subscription?: Pick<Stripe.Subscription, "metadata"> | null,
): boolean {
  const sessionMetadata = session.metadata;
  const subscriptionMetadata = subscription?.metadata;
  // An explicit app marker on the checkout is the trust boundary. A nested
  // subscription cannot turn a foreign session into a cmux purchase.
  if (sessionMetadata?.app) return sessionMetadata.app === "cmux";
  if (subscriptionMetadata?.app) {
    if (subscriptionMetadata.app !== "cmux") return false;
    return true;
  }
  if (
    sessionMetadata?.founders_edition === "true" ||
    subscriptionMetadata?.founders_edition === "true"
  ) {
    return true;
  }
  return Boolean(session.client_reference_id && sessionMetadata?.plan === "pro");
}

function isFounderCheckoutMetadata(
  sessionMetadata: Stripe.Metadata | null | undefined,
  subscription: Pick<Stripe.Subscription, "metadata"> | null | undefined,
): boolean {
  return (
    sessionMetadata?.founders_edition === "true" ||
    subscription?.metadata?.founders_edition === "true"
  );
}

/**
 * Return true when a checkout claims the one-time Founder product together
 * with another product marker or Team scope. Founder and renewable Pro
 * metadata are mutually exclusive, too. Fail closed at every completion
 * entry point instead of granting a durable Founder entitlement from a
 * malformed checkout.
 */
export function hasConflictingFounderMetadata(
  session: Pick<Stripe.Checkout.Session, "metadata">,
  subscription?: Pick<Stripe.Subscription, "metadata"> | null,
  additionalMetadata: readonly (Stripe.Metadata | null | undefined)[] = [],
): boolean {
  const metadataSources = [
    session.metadata,
    subscription?.metadata,
    ...additionalMetadata,
  ];
  const isFounder = metadataSources.some(
    (metadata) => metadata?.founders_edition === "true",
  );
  if (!isFounder) return false;
  return metadataSources.some(
    (metadata) =>
      metadata?.plan === PRO_PLAN_ID ||
      metadata?.plan === TEAM_PLAN_ID ||
      Boolean(metadata?.stackTeamId),
  );
}

async function loadOptionalStackUser(
  stackUserId: string,
  stackApp: StackBillingApp | null | undefined,
): Promise<StackBillingUser | null> {
  const app = stackApp ?? getStackServerApp();
  if (!app) throw new Error("Stack Auth is not configured");
  return app.getUser(stackUserId);
}

async function loadStackTeam(
  stackTeamId: string,
  stackApp: StackBillingApp | null | undefined,
): Promise<StackBillingTeam> {
  const app = stackApp ?? getStackServerApp();
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
    await syncTeamPlanMetadata(team, true, subscriptionSeats(input.subscription));
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
    cancelAtPeriodEnd: Boolean(subscription.cancel_at_period_end),
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

async function userStripeSubscriptionState(
  db: BillingDbClient,
  input: { subscriptionId: string; stackUserId: string },
): Promise<{ readonly exists: boolean; readonly isFounder: boolean }> {
  const [row] = await db
    .select({ id: stripeSubscriptions.id, raw: stripeSubscriptions.raw })
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
  return {
    exists: Boolean(row),
    isFounder: Boolean(row && isFounderSubscriptionRaw(row.raw)),
  };
}

function isFounderSubscriptionRaw(raw: unknown): boolean {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return false;
  const metadata = (raw as Record<string, unknown>).metadata;
  return Boolean(
    metadata &&
      typeof metadata === "object" &&
      !Array.isArray(metadata) &&
      (metadata as Record<string, unknown>).founders_edition === "true",
  );
}

async function hasActiveUserProSubscription(
  db: BillingDbClient,
  stackUserId: string,
): Promise<boolean> {
  const rows = await db
    .select({ id: stripeSubscriptions.id })
    .from(stripeSubscriptions)
    .where(
      and(
        eq(stripeSubscriptions.stackUserId, stackUserId),
        eq(stripeSubscriptions.scope, "user"),
        eq(stripeSubscriptions.plan, PRO_PLAN_ID),
        inArray(stripeSubscriptions.status, [...ACTIVE_STRIPE_SUBSCRIPTION_STATUSES]),
        isNull(stripeSubscriptions.stackTeamId),
      ),
    )
    .limit(1);
  return rows.length > 0;
}

async function hasActiveFounderSubscription(
  db: BillingDbClient,
  stackUserId: string,
): Promise<boolean> {
  const rows = await db
    .select({ raw: stripeSubscriptions.raw })
    .from(stripeSubscriptions)
    .where(
      and(
        eq(stripeSubscriptions.stackUserId, stackUserId),
        eq(stripeSubscriptions.scope, "user"),
        eq(stripeSubscriptions.plan, PRO_PLAN_ID),
        inArray(stripeSubscriptions.status, [...ACTIVE_STRIPE_SUBSCRIPTION_STATUSES]),
        isNull(stripeSubscriptions.stackTeamId),
      ),
    )
    .limit(100);
  return rows.some((row) => isFounderSubscriptionRaw(row.raw));
}

async function attachPurchaseEmailOrRecordClaim(
  db: BillingDb,
  input: {
    user: StackBillingUser;
    email: string;
    checkoutSessionId: string;
    stripeCustomerId: string;
    stackUserId: string;
    stackApp: StackBillingApp | null | undefined;
  },
  mutationLease: AccountDeletionUserMutationLease,
  dependencies: BillingPurchaseDependencies,
): Promise<void> {
  const purchaseEmail = canonicalizeEmailForMatching(input.email);
  if (input.user.isAnonymous === true) {
    // Stack does not clear the anonymous flag when an email is attached through
    // the ordinary user update API. A verified channel can use the Hexclave
    // endpoint to clear that flag. The password field is omitted, which
    // preserves any password the buyer already set.
    if (
      input.user.primaryEmail &&
      canonicalizeEmailForMatching(input.user.primaryEmail) !== purchaseEmail
    ) {
      await mutationLease.refresh();
      const inserted = await recordBillingEmailClaim(db, input);
      if (inserted) {
        await requestPurchaseMagicLink(db, input, mutationLease, dependencies);
      }
      return;
    }
    if (input.user.primaryEmailVerified === true) {
      // A verified Stack channel is the only proof needed to remove the
      // anonymous restriction. The REST mutation omits password, so an
      // existing password survives the promotion.
      try {
        await mutationLease.refresh();
        await promoteStackUserFromAnonymousViaApi(input.user.id, input.email);
        await requestPurchaseMagicLink(db, input, mutationLease, dependencies);
      } catch (error) {
        if (!isEmailAlreadyUsedError(error)) throw error;
        await mutationLease.refresh();
        const inserted = await recordBillingEmailClaim(db, input);
        if (inserted) {
          await requestPurchaseMagicLink(db, input, mutationLease, dependencies);
        }
      }
    } else {
      // Payment does not prove mailbox control. Attach the channel as
      // unverified, then let Stack's one-time link establish ownership.
      try {
        await mutationLease.refresh();
        await input.user.update({
          primaryEmail: input.email,
          primaryEmailAuthEnabled: true,
          primaryEmailVerified: false,
        });
        await requestPurchaseMagicLink(db, input, mutationLease, dependencies);
      } catch (error) {
        if (!isEmailAlreadyUsedError(error)) throw error;
        await mutationLease.refresh();
        const inserted = await recordBillingEmailClaim(db, input);
        if (inserted) {
          await requestPurchaseMagicLink(db, input, mutationLease, dependencies);
        }
      }
    }
    return;
  }
  if (input.user.primaryEmail) {
    // Keep an existing account's spelling and verification state unchanged.
    // The billing email can trigger a recovery message, but only Stack can
    // verify the channel after the recipient proves mailbox control.
    if (
      canonicalizeEmailForMatching(input.user.primaryEmail) === purchaseEmail
    ) {
      if (input.user.primaryEmailVerified !== true) {
        await requestPurchaseMagicLink(db, input, mutationLease, dependencies);
      }
    }
    return;
  }
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
      primaryEmailVerified: false,
    });
    await requestPurchaseMagicLink(db, input, mutationLease, dependencies);
  } catch (error) {
    if (!isEmailAlreadyUsedError(error)) throw error;
    await mutationLease.refresh();
    await recordBillingEmailClaim(db, input);
  }
}

export async function findUserIdByEmail(
  stackApp: StackBillingApp | null | undefined,
  email: string,
): Promise<string | null> {
  const listUsers = stackApp?.listUsers;
  if (!listUsers) {
    throw new Error("Stack Auth server SDK cannot list users");
  }
  const boundListUsers = listUsers.bind(stackApp);
  const normalizedEmail = canonicalizeEmailForMatching(email);
  const literalEmail = email.trim().toLowerCase();
  const queries = emailVariantsForMatching(literalEmail);
  const ownersByID = new Map<string, StackBillingUserLookup>();
  for (const query of queries) {
    await collectBillingUserLookupCandidates(
      boundListUsers,
      query,
      normalizedEmail,
      ownersByID,
      20,
    );
  }
  if (ownersByID.size === 0 && isGmailAddress(literalEmail)) {
    await collectBillingUserLookupCandidates(
      boundListUsers,
      undefined,
      normalizedEmail,
      ownersByID,
      STACK_USER_LOOKUP_PAGE_SIZE,
    );
  }
  return [...ownersByID.values()].sort(compareStackUserLookup)[0]?.id ?? null;
}

async function collectBillingUserLookupCandidates(
  listUsers: NonNullable<StackBillingApp["listUsers"]>,
  query: string | undefined,
  matchingEmail: string,
  candidates: Map<string, StackBillingUserLookup>,
  limit: number,
): Promise<boolean> {
  let cursor: string | undefined;
  const seenCursors = new Set<string>();
  let foundCanonicalMatch = false;
  for (let page = 0; page < MAX_STACK_USER_LOOKUP_PAGES; page += 1) {
    const users = (await listUsers({
      ...(query ? { query } : {}),
      ...(cursor ? { cursor } : {}),
      limit,
      includeAnonymous: true,
      includeRestricted: true,
    })) as StackBillingUserList;
    for (const candidate of users) {
      if (
        candidate.primaryEmail &&
        canonicalizeEmailForMatching(candidate.primaryEmail) === matchingEmail
      ) {
        candidates.set(candidate.id, candidate);
        foundCanonicalMatch = true;
      }
    }
    const nextCursor = users.nextCursor ?? null;
    if (!nextCursor) return foundCanonicalMatch;
    if (seenCursors.has(nextCursor)) {
      throw new Error("Stack Auth user lookup pagination looped");
    }
    seenCursors.add(nextCursor);
    cursor = nextCursor;
  }
  throw new Error("Stack Auth user lookup exceeded its bounded page budget");
}

function compareStackUserLookup(
  left: StackBillingUserLookup,
  right: StackBillingUserLookup,
): number {
  const leftEmail = left.primaryEmail ?? "";
  const rightEmail = right.primaryEmail ?? "";
  const leftCanonical = canonicalizeEmailForMatching(leftEmail);
  const rightCanonical = canonicalizeEmailForMatching(rightEmail);
  const leftIsVerifiedOrdinary =
    left.primaryEmailVerified === true &&
    left.isAnonymous !== true &&
    left.isRestricted !== true;
  const rightIsVerifiedOrdinary =
    right.primaryEmailVerified === true &&
    right.isAnonymous !== true &&
    right.isRestricted !== true;
  if (leftIsVerifiedOrdinary !== rightIsVerifiedOrdinary) {
    return leftIsVerifiedOrdinary ? -1 : 1;
  }
  const leftIsOrdinary = left.isAnonymous !== true && left.isRestricted !== true;
  const rightIsOrdinary = right.isAnonymous !== true && right.isRestricted !== true;
  if (leftIsOrdinary !== rightIsOrdinary) return leftIsOrdinary ? -1 : 1;
  const leftIsVerified = left.primaryEmailVerified === true;
  const rightIsVerified = right.primaryEmailVerified === true;
  if (leftIsVerified !== rightIsVerified) return leftIsVerified ? -1 : 1;
  const leftDotCount = gmailLocalDotCount(leftEmail);
  const rightDotCount = gmailLocalDotCount(rightEmail);
  // After verified ownership, prefer the undotted Gmail spelling as the
  // canonical duplicate. Verification is ranked first so an unverified alias
  // cannot take billing ownership from a verified account.
  if (leftDotCount !== rightDotCount) return leftDotCount - rightDotCount;
  if (leftEmail.toLowerCase() === leftCanonical && rightEmail.toLowerCase() !== rightCanonical) return -1;
  if (rightEmail.toLowerCase() === rightCanonical && leftEmail.toLowerCase() !== leftCanonical) return 1;
  return left.id.localeCompare(right.id);
}

function isCompatibleFounderOwner(
  user: StackBillingUser,
  purchaseEmail: string,
): boolean {
  if (user.primaryEmail) {
    return (
      canonicalizeEmailForMatching(user.primaryEmail) ===
      canonicalizeEmailForMatching(purchaseEmail)
    );
  }
  return user.isAnonymous === true;
}

function isVerifiedCanonicalBillingOwner(
  user: StackBillingUser,
  purchaseEmail: string,
): boolean {
  return (
    user.isAnonymous !== true &&
    user.isRestricted !== true &&
    user.primaryEmailVerified === true &&
    canonicalizeEmailForMatching(user.primaryEmail ?? "") ===
      canonicalizeEmailForMatching(purchaseEmail)
  );
}

function gmailLocalDotCount(email: string): number {
  const normalized = email.trim().toLowerCase();
  const at = normalized.lastIndexOf("@");
  if (at <= 0) return 0;
  const domain = normalized.slice(at + 1);
  if (domain !== "gmail.com" && domain !== "googlemail.com") return 0;
  const local = normalized.slice(0, at);
  const plusIndex = local.indexOf("+");
  const mailbox = plusIndex < 0 ? local : local.slice(0, plusIndex);
  return [...mailbox].filter((character) => character === ".").length;
}

async function recordBillingEmailClaim(
  db: BillingDbClient,
  input: {
    email: string;
    stripeCustomerId: string;
    stackUserId: string;
  },
): Promise<boolean> {
  const matchingEmail = canonicalizeEmailForMatching(input.email);
  const existing = await db
    .select({
      id: billingEmailClaims.id,
      email: billingEmailClaims.email,
    })
    .from(billingEmailClaims)
    .where(
      and(
        eq(billingEmailClaims.stripeCustomerId, input.stripeCustomerId),
        eq(billingEmailClaims.stackUserId, input.stackUserId),
        eq(billingEmailClaims.plan, PRO_PLAN_ID),
        isNull(billingEmailClaims.claimedByUserId),
      ),
    )
    .limit(20);
  if (
    existing.some(
      (claim) =>
        !claim.email ||
        canonicalizeEmailForMatching(claim.email) === matchingEmail,
    )
  ) return false;
  await db.insert(billingEmailClaims).values({
    email: matchingEmail,
    stripeCustomerId: input.stripeCustomerId,
    stackUserId: input.stackUserId,
    plan: PRO_PLAN_ID,
  });
  return true;
}

/** Send one best-effort sign-in link after parking or promoting a purchase. */
async function requestPurchaseMagicLink(
  db: BillingDb,
  input: {
    email: string;
    checkoutSessionId: string;
    stackUserId: string;
    stackApp: StackBillingApp | null | undefined;
  },
  mutationLease: AccountDeletionUserMutationLease,
  dependencies: BillingPurchaseDependencies,
): Promise<void> {
  if (!input.stackApp?.sendMagicLinkEmail) return;
  await mutationLease.refresh();
  try {
    const deliveryStore =
      dependencies.magicLinkDelivery ?? makePurchaseMagicLinkDeliveryStore(db);
    await deliveryStore.deliverOnce(
      {
        checkoutSessionId: input.checkoutSessionId,
        stackUserId: input.stackUserId,
        email: canonicalizeEmailForMatching(input.email),
      },
      async () => {
        await mutationLease.refresh();
        const result = await input.stackApp!.sendMagicLinkEmail!(input.email, {
          callbackUrl: PURCHASE_MAGIC_LINK_CALLBACK,
        });
        if (isFailedStackResult(result)) {
          throw new PurchaseMagicLinkProviderRejectedError(
            "Stack sign-in link request failed",
          );
        }
      },
    );
  } catch {
    // The billing rows are already durable. A failed message can be retried by
    // the recovery endpoint, so email delivery must not roll back a purchase.
    console.warn("billing.purchase.magic_link_failed", {
      failure: "provider_unavailable",
    });
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

async function stripeCustomerRowForId(
  db: BillingDbClient,
  customerId: string,
): Promise<{ stackUserId: string; stackTeamId: string | null } | null> {
  const rows = await db
    .select({
      stackUserId: stripeCustomers.stackUserId,
      stackTeamId: stripeCustomers.stackTeamId,
    })
    .from(stripeCustomers)
    .where(eq(stripeCustomers.id, customerId))
    .limit(1);
  return rows[0] ?? null;
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

function expandedCustomerForLookup(
  session: Stripe.Checkout.Session,
): Stripe.Customer | Stripe.DeletedCustomer | null {
  return typeof session.customer === "object" && session.customer !== null
    ? session.customer
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
  if (customer && !customer.deleted) return customer.id;
  const sessionCustomerID = stringId(session.customer);
  if (sessionCustomerID) return sessionCustomerID;
  const paymentIntent = session.payment_intent;
  return typeof paymentIntent === "object" && paymentIntent !== null
    ? stringId(paymentIntent.customer)
    : null;
}

function customerIdFromSubscription(subscription: Stripe.Subscription): string | null {
  return stringId(subscription.customer);
}

function checkoutEmail(
  session: Stripe.Checkout.Session,
  customer: Stripe.Customer | Stripe.DeletedCustomer | null | undefined,
): string | null {
  const sessionEmail = session.customer_details?.email?.trim();
  const customerEmail = customer && !customer.deleted
    ? customer.email?.trim()
    : null;
  const email = sessionEmail || customerEmail;
  return email ? email.toLowerCase() : null;
}

function checkoutLiteralEmail(
  session: Stripe.Checkout.Session,
  customer: Stripe.Customer | Stripe.DeletedCustomer | null | undefined,
): string | null {
  const sessionEmail = session.customer_details?.email?.trim();
  const customerEmail = customer && !customer.deleted
    ? customer.email?.trim()
    : null;
  return sessionEmail || customerEmail || null;
}

function checkoutCustomerName(
  session: Stripe.Checkout.Session,
  customer: Stripe.Customer | Stripe.DeletedCustomer | null | undefined,
): string | null {
  const name =
    session.customer_details?.name ??
    (customer && !customer.deleted ? customer.name : null);
  const trimmed = name?.trim();
  return trimmed || null;
}

function subscriptionPriceId(subscription: Stripe.Subscription): string | null {
  return subscription.items?.data?.[0]?.price?.id ?? null;
}

function subscriptionSeats(subscription: Stripe.Subscription): number | null {
  const quantity = subscription.items?.data?.[0]?.quantity;
  return typeof quantity === "number" && Number.isFinite(quantity) ? quantity : null;
}

function subscriptionCurrentPeriodEnd(subscription: Stripe.Subscription): Date | null {
  const timestamp = subscription.items?.data?.[0]?.current_period_end;
  return typeof timestamp === "number" ? new Date(timestamp * 1000) : null;
}

function stringId(value: string | { id: string } | null | undefined): string | null {
  if (!value) return null;
  return typeof value === "string" ? value : value.id;
}

function isEmailAlreadyUsedError(error: unknown): boolean {
  const code =
    error && typeof error === "object" && "code" in error
      ? String((error as { code?: unknown }).code)
      : "";
  if (/USER_EMAIL_ALREADY_EXISTS|EMAIL_ALREADY_EXISTS|CONTACT_CHANNEL_ALREADY_USED/i.test(code)) {
    return true;
  }
  const nestedCode =
    error && typeof error === "object" && "cause" in error
      ? String((error as { cause?: { code?: unknown } }).cause?.code ?? "")
      : "";
  if (/USER_EMAIL_ALREADY_EXISTS|EMAIL_ALREADY_EXISTS|CONTACT_CHANNEL_ALREADY_USED/i.test(nestedCode)) {
    return true;
  }
  const text = error instanceof Error ? `${error.name} ${error.message}` : String(error);
  return /already.{0,40}(used|taken|exists)|CONTACT_CHANNEL_ALREADY_USED_FOR_AUTH_BY_SOMEONE_ELSE/i.test(text);
}

function isFailedStackResult(value: unknown): boolean {
  return Boolean(
    value &&
      typeof value === "object" &&
      "status" in value &&
      (value as { status?: unknown }).status === "error",
  );
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
