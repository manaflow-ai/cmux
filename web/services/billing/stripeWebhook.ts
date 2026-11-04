import { createHash } from "node:crypto";

import { eq } from "drizzle-orm";
import { after, NextResponse } from "next/server";
import type Stripe from "stripe";

import { env } from "../../app/env";
import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import { captureBillingError } from "../errors";
import {
  captureStripeBillingEvent as captureStripeBillingEventDefault,
  type StripeBillingAnalyticsSubject,
} from "../analytics/stripeBilling";
import {
  applySubscriptionUpdate as applySubscriptionUpdateDefault,
  hasConflictingFounderMetadata,
  isCmuxCheckoutSession,
  isActiveStripeSubscriptionStatus,
  recordCheckoutCompletion as recordCheckoutCompletionDefault,
  recordFoundersCheckoutCompletion as recordFoundersCheckoutCompletionDefault,
} from "./purchase";
import { sendProSignupWelcome as sendProSignupWelcomeDefault } from "./proFulfillment";
import {
  revokeRouteTokensForTeam as revokeRouteTokensForTeamDefault,
  revokeRouteTokensForUser as revokeRouteTokensForUserDefault,
} from "../coderouter/repository";
import { isStripeBillingConfigured, stripe } from "./stripe";
import { personalProWelcomeOwnsDelivery } from "./personalProWelcome";
import { isPersonalPlanId } from "./pro";
import { databaseTeamSeatQueue } from "./teamSeatQueue";
import { AccountDeletionUserMutationInProgressError } from "../account/deletionLock";
import {
  STRIPE_WEBHOOK_REPLAY_MAX_AGE_MS,
  STRIPE_WEBHOOK_RETRYABLE_ERROR_PREFIX,
} from "./stripeWebhookErrors";
import {
  createDrizzleStripeWebhookInbox,
  type StripeWebhookClaim,
  type StripeWebhookInbox,
  type StripeWebhookInboxEntry,
} from "./stripeWebhookInbox";
import {
  recordSpanError,
  setSpanAttributes,
  withApiRouteSpan,
} from "../telemetry";


/**
 * Every event type the billing webhook acts on. The live endpoint's
 * subscriptions (`scripts/stripe/provision-catalog.sh`) and the local
 * `stripe listen` (`scripts/stripe/dev-stack.sh`) must list exactly these;
 * tests/stripe-webhook-event-types.test.ts holds them together.
 */
export const STRIPE_WEBHOOK_EVENT_TYPES = [
  "checkout.session.completed",
  "checkout.session.async_payment_succeeded",
  "checkout.session.async_payment_failed",
  "checkout.session.expired",
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.deleted",
  "customer.subscription.paused",
  "customer.subscription.resumed",
  "customer.subscription.pending_update_applied",
  "customer.subscription.pending_update_expired",
  "invoice.paid",
  "invoice.payment_failed",
  "invoice.payment_action_required",
  "invoice.marked_uncollectible",
  "charge.refunded",
] as const satisfies readonly Stripe.Event.Type[];

type StripeWebhookDependencies = {
  webhookSecret: () => string | undefined;
  isConfigured: () => boolean;
  stripe: typeof stripe;
  inbox: StripeWebhookInbox;
  /** The current principal and status of a stored subscription, for a superseded event's analytics. */
  storedSubscriptionSubject?: (subscriptionId: string) => Promise<StripeBillingAnalyticsSubject | null>;
  now?: () => Date;
  recordCheckoutCompletion: typeof recordCheckoutCompletionDefault;
  recordFoundersCheckoutCompletion?: typeof recordFoundersCheckoutCompletionDefault;
  applySubscriptionUpdate: typeof applySubscriptionUpdateDefault;
  markTeamSeatsDirty?: (stackTeamId: string) => Promise<void>;
  sendProSignupWelcome: typeof sendProSignupWelcomeDefault;
  isPersonalWelcomeConfigured?: () => boolean;
  revokeCoderouterRouteTokens: typeof revokeRouteTokensForUserDefault;
  revokeCoderouterTeamRouteTokens: typeof revokeRouteTokensForTeamDefault;
  captureStripeBillingEvent: typeof captureStripeBillingEventDefault;
  defer: (task: () => Promise<void>) => void;
};

const defaultDependencies: StripeWebhookDependencies = {
  webhookSecret: () => env.STRIPE_WEBHOOK_SECRET,
  isConfigured: isStripeBillingConfigured,
  stripe,
  inbox: createDrizzleStripeWebhookInbox(),
  storedSubscriptionSubject: storedSubscriptionSubjectDefault,
  recordCheckoutCompletion: recordCheckoutCompletionDefault,
  recordFoundersCheckoutCompletion: recordFoundersCheckoutCompletionDefault,
  applySubscriptionUpdate: applySubscriptionUpdateDefault,
  markTeamSeatsDirty: (stackTeamId) => databaseTeamSeatQueue.markDirty(stackTeamId),
  sendProSignupWelcome: sendProSignupWelcomeDefault,
  isPersonalWelcomeConfigured,
  revokeCoderouterRouteTokens: revokeRouteTokensForUserDefault,
  revokeCoderouterTeamRouteTokens: revokeRouteTokensForTeamDefault,
  captureStripeBillingEvent: captureStripeBillingEventDefault,
  defer: (task) => after(task),
};

/**
 * Stores a verified event in the inbox and answers 2xx before any side
 * effect runs; processing follows the response, and the alerts cron drains
 * whatever it did not finish (`makeStripeWebhookReplayer`). A store failure
 * answers 500, so Stripe delivers the event again.
 */
export function makeStripeWebhookHandler(
  dependencies: StripeWebhookDependencies = defaultDependencies,
) {
  return async function POST(request: Request) {
  return withApiRouteSpan(
    request,
    "/api/stripe/webhook",
    { "cmux.subsystem": "stripe", "cmux.stripe.operation": "billing_webhook" },
    async (span): Promise<Response> => {
      const webhookSecret = dependencies.webhookSecret();
      if (!webhookSecret || !dependencies.isConfigured()) {
        return jsonError("Stripe billing webhook is not configured", 503);
      }

      const rawBody = await request.text();
      let event: Stripe.Event;
      try {
        event = dependencies.stripe().webhooks.constructEvent(
          rawBody,
          request.headers.get("stripe-signature") ?? "",
          webhookSecret,
        );
      } catch {
        return jsonError("Invalid Stripe signature", 400);
      }

      setSpanAttributes(span, { "cmux.stripe.event_type": event.type });
      const { processed } = await dependencies.inbox.record(inboxEntry(event, payloadHash(rawBody)));
      if (processed) return NextResponse.json({ ok: true, skipped: "duplicate" });

      dependencies.defer(async () => {
        try {
          await claimAndProcessStripeEvent(event, dependencies);
        } catch (error) {
          captureBillingError(error, {
            route: "/api/stripe/webhook",
            eventType: event.type,
            eventId: event.id,
          });
        }
      });
      return NextResponse.json({ ok: true, queued: true });
    },
  );
  };
}

type RecordedStripeEventOutcome =
  | { readonly ok: true; readonly result: Omit<StripeEventOutcome, "analytics"> }
  | { readonly ok: false; readonly retryable: boolean };

/**
 * How long one attempt holds an event, and its object, before another worker
 * may take it over. It outlives the longest a Vercel function can run (800 s),
 * so a worker is always gone before its lease lapses and can never apply a
 * stale subscription read after a newer event of the object has applied.
 */
const STRIPE_WEBHOOK_LEASE_MS = 15 * 60 * 1_000;
/** Wait before the next attempt after the Nth failure; the last step repeats. */
const STRIPE_WEBHOOK_RETRY_DELAYS_MS = [1, 5, 15, 60, 180].map((minutes) => minutes * 60 * 1_000);

/** Null when the event is processed or leased, or another event of its object is running. */
async function claimAndProcessStripeEvent(
  event: Stripe.Event,
  dependencies: StripeWebhookDependencies,
): Promise<RecordedStripeEventOutcome | null> {
  // The handler stored every other event's key; a refund's needs a Stripe read.
  if (event.type === "charge.refunded") await recordObjectKey(event, dependencies);
  const claim = await claimStripeEvent(event.id, dependencies);
  if (!claim) return null;
  return processClaimedStripeEvent(event, claim, dependencies);
}

function claimStripeEvent(
  id: string,
  dependencies: StripeWebhookDependencies,
): Promise<StripeWebhookClaim | null> {
  const now = currentTime(dependencies);
  return dependencies.inbox.claim(id, now, new Date(now.getTime() + STRIPE_WEBHOOK_LEASE_MS));
}

/**
 * Every claim is serialized on the event's object, so its key must be stored
 * before the claim: a refund's subscription is only known from its invoice,
 * and a row stored before the inbox existed has no key at all.
 */
async function recordObjectKey(
  event: Stripe.Event,
  dependencies: StripeWebhookDependencies,
): Promise<void> {
  const entry = inboxEntry(event, "");
  if (event.type === "charge.refunded") {
    const objectKey = await refundObjectKey(event.data.object, dependencies);
    if (!objectKey) return;
    await dependencies.inbox.record({ ...entry, objectKey });
    return;
  }
  if (entry.objectKey) await dependencies.inbox.record(entry);
}

async function refundObjectKey(
  charge: Stripe.Charge & { invoice?: string | Stripe.Invoice | null },
  dependencies: StripeWebhookDependencies,
): Promise<string | null> {
  const invoiceId = stringId(charge.invoice);
  if (!invoiceId) return null;
  const invoice = await dependencies.stripe().invoices.retrieve(invoiceId);
  return invoiceSubscriptionId(invoice) ?? invoice.id;
}

async function processClaimedStripeEvent(
  event: Stripe.Event,
  claim: StripeWebhookClaim,
  dependencies: StripeWebhookDependencies,
  span?: Parameters<typeof recordSpanError>[0],
): Promise<RecordedStripeEventOutcome> {
  try {
    const { analytics, ...result } =
      await skipSupersededStripeEvent(event, dependencies) ?? await processStripeEvent(event, dependencies);
    const recorded = await dependencies.inbox.complete(claim, result.skipped ?? null);
    if (recorded && analytics) {
      await analytics().catch((error: unknown) => {
        captureBillingError(error, { operation: "stripe_webhook_analytics", eventId: event.id });
      });
    }
    return { ok: true, result };
  } catch (error) {
    const retryable = isRetryableStripeEventError(error);
    const message = error instanceof Error ? error.message : String(error);
    if (span) {
      setSpanAttributes(span, { "cmux.stripe.retryable": retryable });
      recordSpanError(span, error);
    }
    // Lease contention resolves once the sibling event finishes. The inbox
    // retries it, and the billing alert pages only if the row is still
    // failing after the retry grace period.
    if (!retryable) {
      captureBillingError(error, {
        route: "/api/stripe/webhook",
        eventType: event.type,
        eventId: event.id,
      });
    }
    await dependencies.inbox.fail(
      claim,
      retryable ? `${STRIPE_WEBHOOK_RETRYABLE_ERROR_PREFIX}${message}` : message,
      nextAttemptAt(claim.attempts, currentTime(dependencies)),
    );
    return { ok: false, retryable };
  }
}

function nextAttemptAt(attempts: number, now: Date): Date {
  const delays = STRIPE_WEBHOOK_RETRY_DELAYS_MS;
  const delay = delays[Math.min(Math.max(attempts, 1), delays.length) - 1];
  return new Date(now.getTime() + delay);
}

function isRetryableStripeEventError(error: unknown): boolean {
  for (let current = error, depth = 0; current && depth < 5; depth += 1) {
    if (current instanceof AccountDeletionUserMutationInProgressError) return true;
    current = current instanceof Error ? current.cause : undefined;
  }
  return false;
}

export type StripeWebhookReplaySummary = {
  readonly attempted: number;
  readonly succeeded: number;
  readonly failed: number;
};

/** Events per cron run; the webhook's own `after()` processes nearly all of them first. */
const STRIPE_WEBHOOK_REPLAY_BATCH = 10;

/**
 * Drains the inbox: every unprocessed event that is due, longest-waiting
 * first, re-read from Stripe's authoritative event record. Processing is
 * idempotent, so an attempt racing the webhook's own produces the same
 * entitlement state, and the inbox lease keeps them from running at once.
 */
export function makeStripeWebhookReplayer(
  dependencies: StripeWebhookDependencies = defaultDependencies,
) {
  return async function replayFailedStripeWebhookEvents(
    now: Date = currentTime(dependencies),
  ): Promise<StripeWebhookReplaySummary> {
    if (!dependencies.isConfigured()) return { attempted: 0, succeeded: 0, failed: 0 };
    const ids = await dependencies.inbox.due(
      now,
      new Date(now.getTime() - STRIPE_WEBHOOK_REPLAY_MAX_AGE_MS),
      STRIPE_WEBHOOK_REPLAY_BATCH,
    );

    let attempted = 0;
    let succeeded = 0;
    let failed = 0;
    for (const id of ids) {
      let event: Stripe.Event;
      try {
        event = await dependencies.stripe().events.retrieve(id);
        await recordObjectKey(event, dependencies);
      } catch (error) {
        // Nothing was applied; count the attempt and back off.
        const claim = await claimStripeEvent(id, dependencies);
        if (!claim) continue;
        attempted += 1;
        failed += 1;
        captureBillingError(error, { operation: "stripe_webhook_replay", eventId: id });
        const message = error instanceof Error ? error.message : String(error);
        await dependencies.inbox.fail(claim, message, nextAttemptAt(claim.attempts, currentTime(dependencies)));
        continue;
      }
      const claim = await claimStripeEvent(id, dependencies);
      if (!claim) continue;
      attempted += 1;
      const outcome = await processClaimedStripeEvent(event, claim, dependencies);
      if (outcome.ok) succeeded += 1;
      else failed += 1;
    }
    return { attempted, succeeded, failed };
  };
}

function currentTime(dependencies: StripeWebhookDependencies): Date {
  return dependencies.now?.() ?? new Date();
}

function inboxEntry(event: Stripe.Event, hash: string): StripeWebhookInboxEntry {
  return {
    id: event.id,
    type: event.type,
    payloadHash: hash,
    objectKey: stripeEventObjectKey(event),
    createdAt: typeof event.created === "number" ? new Date(event.created * 1_000) : null,
  };
}

/**
 * The Stripe object whose state the event changes. Events of one subscription
 * share its id, whether they arrive as checkout, subscription or invoice
 * events, so they run one at a time.
 */
function stripeEventObjectKey(event: Stripe.Event): string | null {
  const type: string = event.type;
  if (type.startsWith("customer.subscription.")) {
    return (event.data.object as Stripe.Subscription).id;
  }
  if (type.startsWith("checkout.session.")) {
    const session = event.data.object as Stripe.Checkout.Session;
    return stringId(session.subscription) ?? session.id;
  }
  if (type.startsWith("invoice.")) {
    const invoice = event.data.object as Stripe.Invoice;
    return invoiceSubscriptionId(invoice) ?? invoice.id;
  }
  return null;
}

/**
 * Events whose processing re-applies Stripe's current subscription state and
 * nothing else. One that Stripe created before an already-applied event of
 * the same subscription has nothing newer to apply.
 */
const SUBSCRIPTION_STATE_EVENT_TYPES: ReadonlySet<string> = new Set<Stripe.Event.Type>([
  "checkout.session.async_payment_failed",
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.deleted",
  "customer.subscription.paused",
  "customer.subscription.resumed",
  "customer.subscription.pending_update_applied",
  "customer.subscription.pending_update_expired",
  "invoice.paid",
  "invoice.payment_failed",
  "invoice.payment_action_required",
  "invoice.marked_uncollectible",
]);

/**
 * Object-level dedupe: skip re-reading and re-applying a subscription that a
 * later event already applied, and still report this event's analytics under
 * the subscription's stored principal. Null when the event must be processed.
 */
async function skipSupersededStripeEvent(
  event: Stripe.Event,
  dependencies: StripeWebhookDependencies,
): Promise<StripeEventOutcome | null> {
  if (!SUBSCRIPTION_STATE_EVENT_TYPES.has(event.type)) return null;
  const entry = inboxEntry(event, "");
  if (!entry.objectKey || !entry.createdAt || !dependencies.storedSubscriptionSubject) return null;
  // A seat-changing event is only covered by a later event that also
  // reconciled the Team's seats.
  const coveringTypes = TEAM_SEAT_EVENT_TYPES.has(event.type)
    ? [...TEAM_SEAT_EVENT_TYPES]
    : [...SUBSCRIPTION_STATE_EVENT_TYPES];
  const supersededBy = await dependencies.inbox.supersededBy(entry, coveringTypes);
  if (!supersededBy) return null;
  const subject = await dependencies.storedSubscriptionSubject(entry.objectKey);
  if (!subject) return null;
  return {
    skipped: "superseded",
    analytics: () => dependencies.captureStripeBillingEvent(event, subject),
  };
}

async function storedSubscriptionSubjectDefault(
  subscriptionId: string,
): Promise<StripeBillingAnalyticsSubject | null> {
  const [row] = await cloudDb()
    .select({
      scope: stripeSubscriptions.scope,
      stackUserId: stripeSubscriptions.stackUserId,
      stackTeamId: stripeSubscriptions.stackTeamId,
      status: stripeSubscriptions.status,
    })
    .from(stripeSubscriptions)
    .where(eq(stripeSubscriptions.id, subscriptionId))
    .limit(1);
  if (!row) return null;
  const isActive = isActiveStripeSubscriptionStatus(row.status);
  if (row.scope === "team") {
    return row.stackTeamId
      ? { scope: "team", stackTeamId: row.stackTeamId, isActive, status: row.status }
      : null;
  }
  return { scope: "user", stackUserId: row.stackUserId, isActive, status: row.status };
}

type StripeEventOutcome = {
  processed?: string;
  skipped?: string;
  analytics?: () => Promise<void>;
};

async function processStripeEvent(
  event: Stripe.Event,
  dependencies: StripeWebhookDependencies,
): Promise<StripeEventOutcome> {
  switch (event.type) {
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded":
      return processCheckoutCompleted(event, event.data.object, dependencies);
    case "checkout.session.expired":
      return processExpiredCheckout(event, event.data.object, dependencies);
    case "checkout.session.async_payment_failed":
      return processFailedAsyncCheckout(event, event.data.object, dependencies);
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted":
    case "customer.subscription.paused":
    case "customer.subscription.resumed":
    case "customer.subscription.pending_update_applied":
    case "customer.subscription.pending_update_expired":
      // Stripe can deliver events late or out of order. Always reconcile the
      // provider's current object rather than allowing an older event payload
      // to overwrite a newer entitlement state.
      return reconcileSubscriptionEvent(event, event.data.object.id, "subscription_unmapped", dependencies);
    case "invoice.paid":
    case "invoice.payment_failed":
    case "invoice.payment_action_required":
    case "invoice.marked_uncollectible": {
      const subscriptionId = invoiceSubscriptionId(event.data.object);
      if (!subscriptionId) return { skipped: "invoice_without_subscription" };
      return reconcileSubscriptionEvent(event, subscriptionId, "invoice_subscription_unmapped", dependencies);
    }
    case "charge.refunded":
      return processRefund(event, event.data.object, dependencies);
    default:
      return { skipped: "event_type" };
  }
}

async function processCheckoutCompleted(
  event: Stripe.Event,
  session: Stripe.Checkout.Session,
  dependencies: StripeWebhookDependencies,
): Promise<StripeEventOutcome> {
  // Preserve an explicit foreign marker from the signed event payload.
  // Stripe's retrieve response is authoritative for expanded fields, but
  // a test or a delayed provider read must not turn an explicitly foreign
  // event into a cmux purchase.
  if (
    session.metadata?.app &&
    session.metadata.app !== "cmux" &&
    session.metadata.founders_edition !== "true"
  ) {
    return { skipped: "foreign_checkout" };
  }
  const expanded = await dependencies.stripe().checkout.sessions.retrieve(session.id, {
    expand: ["subscription", "customer"],
  });
  const subscription = expandedSubscription(expanded);
  if (!isCmuxCheckoutSession(expanded, subscription)) {
    return { skipped: "foreign_checkout" };
  }
  if (hasConflictingFounderMetadata(expanded, subscription, [session.metadata])) {
    return { skipped: "conflicting_checkout_metadata" };
  }
  if (!checkoutPaymentSettled(expanded)) {
    return { skipped: "checkout_payment_pending" };
  }
  const isFounderCheckout = isFoundersCheckout(session, expanded, subscription);
  const completion = { session: expanded, subscription, customer: expandedCustomer(expanded) };
  const result = isFounderCheckout
    ? await (dependencies.recordFoundersCheckoutCompletion ?? recordFoundersCheckoutCompletionDefault)(completion)
    : await dependencies.recordCheckoutCompletion(completion);
  if (result && "skipped" in result) return { skipped: result.skipped };
  await sendLegacyProWelcomeIfNeeded(result, expanded, subscription, dependencies);
  const subscriptionStatus = isFounderCheckout
    ? "active"
    : subscription?.status ?? "unknown";
  const subject = analyticsSubject(
    result,
    isActiveStripeSubscriptionStatus(subscriptionStatus),
    subscriptionStatus,
  );
  return {
    processed: event.type,
    analytics: () => dependencies.captureStripeBillingEvent(event, subject),
  };
}

// Personal Pro checkouts use the founders-welcome endpoint's canonical
// Austin/Lawrence message. Keep the older templated pro@cmux.com sender
// only as a fallback for deployments that have not configured the
// personal endpoint; when both endpoints are configured this gate avoids
// double-sending the customer.
// The personal endpoint's Pro message contains the TestFlight signup
// link. TestFlight enrollment remains an explicit signed-in user action
// in /api/testflight, so this webhook must not auto-enroll the buyer.
async function sendLegacyProWelcomeIfNeeded(
  result: { readonly scope: "user"; readonly stackUserId: string } | { readonly scope: "team" },
  expanded: Stripe.Checkout.Session,
  subscription: Stripe.Subscription | null,
  dependencies: StripeWebhookDependencies,
): Promise<void> {
  if (
    result.scope === "user" &&
    isPersonalProCheckout(expanded, subscription) &&
    !(dependencies.isPersonalWelcomeConfigured ?? isPersonalWelcomeConfigured)()
  ) {
    await dependencies.sendProSignupWelcome({
      session: expanded,
      stackUserId: result.stackUserId,
    });
  }
}

async function reconcileSubscriptionEvent(
  event: Stripe.Event,
  subscriptionId: string,
  unmappedSkip: string,
  dependencies: StripeWebhookDependencies,
): Promise<StripeEventOutcome> {
  const subscription = await dependencies.stripe().subscriptions.retrieve(subscriptionId);
  const marksTeamSeats = TEAM_SEAT_EVENT_TYPES.has(event.type);
  const result = await applySubscriptionEntitlementUpdate(subscription, dependencies, marksTeamSeats);
  return "skipped" in result
    ? { skipped: unmappedSkip }
    : {
        processed: event.type,
        analytics: () => dependencies.captureStripeBillingEvent(
          event,
          analyticsSubject(result, result.isActive, subscription.status),
        ),
      };
}

// Events whose subscription may have changed its quantity, so a Team's seats
// are reconciled after the entitlement update.
const TEAM_SEAT_EVENT_TYPES: ReadonlySet<Stripe.Event.Type> = new Set([
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.pending_update_applied",
]);

// A delayed payment method (ACH, SEPA, Boleto) failed after the checkout
// completed unpaid. Nothing was fulfilled, but the subscription Checkout
// created is now incomplete or canceled, so its current state is applied.
async function processFailedAsyncCheckout(
  event: Stripe.Event,
  session: Stripe.Checkout.Session,
  dependencies: StripeWebhookDependencies,
): Promise<StripeEventOutcome> {
  const subscriptionId = stringId(session.subscription);
  if (!subscriptionId) return { skipped: "checkout_without_subscription" };
  return reconcileSubscriptionEvent(event, subscriptionId, "checkout_subscription_unmapped", dependencies);
}

async function processRefund(
  event: Stripe.Event,
  charge: Stripe.Charge & { invoice?: string | Stripe.Invoice | null },
  dependencies: StripeWebhookDependencies,
): Promise<StripeEventOutcome> {
  const invoiceId = stringId(charge.invoice);
  if (!invoiceId) return { skipped: "refund_without_invoice" };
  const invoice = await dependencies.stripe().invoices.retrieve(invoiceId);
  const subscriptionId = invoiceSubscriptionId(invoice);
  if (!subscriptionId) return { skipped: "refund_without_subscription" };
  // Refunds do not inherently revoke a subscription. Re-applying Stripe's
  // current subscription state preserves that policy while mapping the
  // event to the correct privacy-safe analytics principal.
  return reconcileSubscriptionEvent(event, subscriptionId, "refund_subscription_unmapped", dependencies);
}

function isFoundersCheckout(
  session: Stripe.Checkout.Session,
  expanded: Stripe.Checkout.Session,
  subscription: Stripe.Subscription | null | undefined,
): boolean {
  return (
    session.metadata?.founders_edition === "true" ||
    expanded.metadata?.founders_edition === "true" ||
    subscription?.metadata?.founders_edition === "true"
  );
}

// Nothing to fulfil: the buyer never paid. Report the abandoned checkout under
// the principal that started it so the funnel has a denominator.
function processExpiredCheckout(
  event: Stripe.Event,
  session: Stripe.Checkout.Session,
  dependencies: StripeWebhookDependencies,
): { processed?: string; skipped?: string; analytics?: () => Promise<void> } {
  if (session.metadata?.app !== "cmux") return { skipped: "foreign_checkout" };
  const subject = expiredCheckoutSubject(session.metadata);
  if (!subject) return { skipped: "checkout_unmapped" };
  return {
    processed: event.type,
    analytics: () => dependencies.captureStripeBillingEvent(event, subject),
  };
}

function expiredCheckoutSubject(
  metadata: Record<string, string> | null | undefined,
): StripeBillingAnalyticsSubject | null {
  const stackTeamId = metadata?.stackTeamId;
  if (typeof stackTeamId === "string" && stackTeamId.length > 0) {
    return { scope: "team", stackTeamId, isActive: false, status: "expired" };
  }
  const stackUserId = metadata?.stackUserId;
  if (typeof stackUserId === "string" && stackUserId.length > 0) {
    return { scope: "user", stackUserId, isActive: false, status: "expired" };
  }
  return null;
}

function analyticsSubject(
  result:
    | { readonly scope: "user"; readonly stackUserId: string }
    | { readonly scope: "team"; readonly stackTeamId: string },
  isActive: boolean,
  status: string,
): StripeBillingAnalyticsSubject {
  return result.scope === "user"
    ? { scope: "user", stackUserId: result.stackUserId, isActive, status }
    : { scope: "team", stackTeamId: result.stackTeamId, isActive, status };
}

async function applySubscriptionEntitlementUpdate(
  subscription: Stripe.Subscription,
  dependencies: StripeWebhookDependencies,
  marksTeamSeats: boolean,
) {
  const result = await dependencies.applySubscriptionUpdate(subscription, {
    markTeamSeatsDirty: marksTeamSeats ? dependencies.markTeamSeatsDirty ?? false : false,
  });
  if (
    !("skipped" in result)
    && !result.isActive
  ) {
    if (result.scope === "user") {
      await dependencies.revokeCoderouterRouteTokens(result.stackUserId);
    } else {
      await dependencies.revokeCoderouterTeamRouteTokens(result.stackTeamId);
    }
  }
  return result;
}

function isPersonalProCheckout(
  session: Stripe.Checkout.Session,
  subscription?: Stripe.Subscription | null,
): boolean {
  return (
    (session.metadata?.app === "cmux" && isPersonalPlanId(session.metadata?.plan)) ||
    (subscription?.metadata?.app === "cmux" &&
      isPersonalPlanId(subscription.metadata?.plan))
  );
}

function isPersonalWelcomeConfigured(): boolean {
  return personalProWelcomeOwnsDelivery({
    enabled: env.CMUX_PERSONAL_PRO_WELCOME_ENABLED,
    resendApiKey: env.RESEND_API_KEY,
    webhookSecret: env.STRIPE_FOUNDERS_WEBHOOK_SECRET,
    stripeSecretKey: env.STRIPE_SECRET_KEY,
  });
}

function checkoutPaymentSettled(session: Stripe.Checkout.Session): boolean {
  return session.payment_status === "paid"
    || session.payment_status === "no_payment_required";
}

function expandedSubscription(session: Stripe.Checkout.Session): Stripe.Subscription | null {
  return typeof session.subscription === "object" && session.subscription !== null
    ? session.subscription
    : null;
}

function expandedCustomer(
  session: Stripe.Checkout.Session,
): Stripe.Customer | Stripe.DeletedCustomer | null {
  return typeof session.customer === "object" && session.customer !== null
    ? session.customer
    : null;
}

function invoiceSubscriptionId(invoice: Stripe.Invoice): string | null {
  const invoiceWithSubscription = invoice as Stripe.Invoice & {
    subscription?: string | Stripe.Subscription | null;
  };
  if (invoiceWithSubscription.subscription) {
    return stringId(invoiceWithSubscription.subscription);
  }
  const parent = invoice.parent as
    | {
        subscription_details?: {
          subscription?: string | Stripe.Subscription | null;
        } | null;
      }
    | null
    | undefined;
  return stringId(parent?.subscription_details?.subscription);
}

function stringId(value: string | { id: string } | null | undefined): string | null {
  if (!value) return null;
  return typeof value === "string" ? value : value.id;
}

function payloadHash(rawBody: string): string {
  return createHash("sha256").update(rawBody).digest("hex");
}

function jsonError(message: string, status: number): Response {
  return NextResponse.json(
    { error: message },
    { status, headers: { "Cache-Control": "no-store" } },
  );
}
