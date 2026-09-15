import { createHash } from "node:crypto";

import { eq, sql } from "drizzle-orm";
import { after, NextResponse } from "next/server";
import type Stripe from "stripe";

import { env } from "../../../env";
import { cloudDb } from "../../../../db/client";
import { stripeWebhookEvents } from "../../../../db/schema";
import { captureBillingError } from "../../../../services/errors";
import {
  captureStripeBillingEvent as captureStripeBillingEventDefault,
  type StripeBillingAnalyticsSubject,
} from "../../../../services/analytics/stripeBilling";
import {
  applySubscriptionUpdate as applySubscriptionUpdateDefault,
  hasConflictingFounderMetadata,
  isCmuxCheckoutSession,
  isActiveStripeSubscriptionStatus,
  recordCheckoutCompletion as recordCheckoutCompletionDefault,
  recordFoundersCheckoutCompletion as recordFoundersCheckoutCompletionDefault,
} from "../../../../services/billing/purchase";
import { sendProSignupWelcome as sendProSignupWelcomeDefault } from "../../../../services/billing/proFulfillment";
import {
  revokeRouteTokensForTeam as revokeRouteTokensForTeamDefault,
  revokeRouteTokensForUser as revokeRouteTokensForUserDefault,
} from "../../../../services/coderouter/repository";
import { isStripeBillingConfigured, stripe } from "../../../../services/billing/stripe";
import { personalProWelcomeOwnsDelivery } from "../../../../services/billing/personalProWelcome";
import {
  recordSpanError,
  setSpanAttributes,
  withApiRouteSpan,
} from "../../../../services/telemetry";


type StripeWebhookDependencies = {
  webhookSecret: () => string | undefined;
  isConfigured: () => boolean;
  stripe: typeof stripe;
  db: typeof cloudDb;
  recordCheckoutCompletion: typeof recordCheckoutCompletionDefault;
  recordFoundersCheckoutCompletion?: typeof recordFoundersCheckoutCompletionDefault;
  applySubscriptionUpdate: typeof applySubscriptionUpdateDefault;
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
  db: cloudDb,
  recordCheckoutCompletion: recordCheckoutCompletionDefault,
  recordFoundersCheckoutCompletion: recordFoundersCheckoutCompletionDefault,
  applySubscriptionUpdate: applySubscriptionUpdateDefault,
  sendProSignupWelcome: sendProSignupWelcomeDefault,
  isPersonalWelcomeConfigured,
  revokeCoderouterRouteTokens: revokeRouteTokensForUserDefault,
  revokeCoderouterTeamRouteTokens: revokeRouteTokensForTeamDefault,
  captureStripeBillingEvent: captureStripeBillingEventDefault,
  defer: (task) => after(task),
};

export const POST = makeStripeWebhookHandler();

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
      const db = dependencies.db();
      const [inserted] = await db
        .insert(stripeWebhookEvents)
        .values({
          id: event.id,
          type: event.type,
          payloadHash: payloadHash(rawBody),
        })
        .onConflictDoNothing({ target: stripeWebhookEvents.id })
        .returning({ id: stripeWebhookEvents.id });

      if (!inserted) {
        const [existing] = await db
          .select({
            processedAt: stripeWebhookEvents.processedAt,
            error: stripeWebhookEvents.error,
          })
          .from(stripeWebhookEvents)
          .where(eq(stripeWebhookEvents.id, event.id))
          .limit(1);
        if (existing?.processedAt && !existing.error) {
          return NextResponse.json({ ok: true, skipped: "duplicate" });
        }
      }

      try {
        const { analytics, ...result } = await processStripeEvent(event, dependencies);
        await db
          .update(stripeWebhookEvents)
          .set({ processedAt: sql`now()`, error: null })
          .where(eq(stripeWebhookEvents.id, event.id));
        if (analytics) dependencies.defer(analytics);
        return NextResponse.json({ ok: true, ...result });
      } catch (error) {
        recordSpanError(span, error);
        captureBillingError(error, {
          route: "/api/stripe/webhook",
          eventType: event.type,
        });
        await db
          .update(stripeWebhookEvents)
          .set({
            error: error instanceof Error ? error.message : String(error),
          })
          .where(eq(stripeWebhookEvents.id, event.id));
        return jsonError("Stripe webhook processing failed", 500);
      }
    },
  );
  };
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
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted":
      // Stripe can deliver events late or out of order. Always reconcile the
      // provider's current object rather than allowing an older event payload
      // to overwrite a newer entitlement state.
      return reconcileSubscriptionEvent(event, event.data.object.id, "subscription_unmapped", dependencies);
    case "invoice.paid":
    case "invoice.payment_failed": {
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
  const result = await applySubscriptionEntitlementUpdate(subscription, dependencies);
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
) {
  const result = await dependencies.applySubscriptionUpdate(subscription);
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
    (session.metadata?.app === "cmux" && session.metadata?.plan === "pro") ||
    (subscription?.metadata?.app === "cmux" &&
      subscription.metadata?.plan === "pro")
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
