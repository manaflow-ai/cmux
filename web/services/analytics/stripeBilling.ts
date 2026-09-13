import type Stripe from "stripe";

import {
  isAnalyticsTestRun,
  POSTHOG_HOST,
  POSTHOG_PROJECT_KEY,
} from "./iosEventPolicy";
import {
  checkoutAttributionFromMetadata,
  checkoutAttributionProperties,
  firstPaidCheckoutPersonProperties,
  type CheckoutAttribution,
} from "./checkoutAttribution";

const CAPTURE_TIMEOUT_MS = 2_000;

export type StripeBillingAnalyticsSubject =
  | {
      readonly scope: "user";
      readonly stackUserId: string;
      readonly isActive?: boolean;
      readonly status?: string;
    }
  | {
      readonly scope: "team";
      readonly stackTeamId: string;
      readonly isActive?: boolean;
      readonly status?: string;
    };

/**
 * Best-effort analytics after the billing mutation succeeds. Billing remains
 * authoritative in Stripe, Postgres, and Stack; an analytics outage must never
 * make Stripe retry an already-applied entitlement mutation.
 */
export async function captureStripeBillingEvent(
  event: Stripe.Event,
  subject: StripeBillingAnalyticsSubject,
  postHogFetch?: typeof fetch,
): Promise<void> {
  const mapped = mappedBillingEvent(event, subject);
  if (!mapped) return;

  await captureBillingPayload({
    name: mapped.name,
    insertId: event.id,
    subject,
    properties: mapped.properties,
  }, postHogFetch);
}

export async function captureBillingCheckoutStarted(
  input: {
    readonly sessionId: string;
    readonly subject: StripeBillingAnalyticsSubject;
    readonly plan: "pro" | "team";
    readonly billingInterval: "month" | "year";
    /** Where the checkout link was opened from (page, app button, channel). */
    readonly attribution: CheckoutAttribution;
    /** False when checkout minted an anonymous Stack user for a signed-out visitor. */
    readonly signedIn: boolean;
    /** True when the principal already had a Stripe customer (lapsed or canceled). */
    readonly existingStripeCustomer: boolean;
  },
  postHogFetch?: typeof fetch,
): Promise<void> {
  await captureBillingPayload({
    name: "cmux_billing_checkout_started",
    insertId: `checkout-started:${input.sessionId}`,
    subject: input.subject,
    properties: {
      source: "checkout_route",
      billing_scope: input.subject.scope,
      plan: input.plan,
      billing_interval: input.billingInterval,
      stripe_checkout_session_id: input.sessionId,
      signed_in: input.signedIn,
      existing_stripe_customer: input.existingStripeCustomer,
      ...checkoutAttributionProperties(input.attribution),
    },
  }, postHogFetch);
}

type MappedBillingEvent = {
  readonly name: string;
  readonly properties: Record<string, unknown>;
};

function mappedBillingEvent(
  event: Stripe.Event,
  subject: StripeBillingAnalyticsSubject,
): MappedBillingEvent | null {
  const common = commonBillingProperties(event, subject);
  switch (event.type) {
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded":
      return checkoutCompletedEvent(event.data.object, event.created, subject, common);
    case "checkout.session.expired":
      return checkoutExpiredEvent(event.data.object, common);
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted":
      return subscriptionEvent(event.data.object, subscriptionEventAction(event.type), common);
    case "invoice.paid":
    case "invoice.payment_failed":
      return invoiceEvent(event.data.object, event.type, common);
    case "charge.refunded":
      return refundEvent(event.data.object, common);
    default:
      return null;
  }
}

function commonBillingProperties(
  event: Stripe.Event,
  subject: StripeBillingAnalyticsSubject,
): Record<string, unknown> {
  const common: Record<string, unknown> = {
    source: "stripe_webhook",
    stripe_event_type: event.type,
    billing_scope: subject.scope,
    is_active: subject.isActive,
    billing_status: subject.status,
  };
  if (subject.scope === "user") {
    common.stack_user_id = subject.stackUserId;
  } else {
    common.stack_team_id = subject.stackTeamId;
    common.$groups = { stack_team: subject.stackTeamId };
  }
  return common;
}

function metadataString(
  metadata: Record<string, string | null | undefined> | null | undefined,
  key: string,
): string | null {
  const value = metadata?.[key];
  return typeof value === "string" && value.length > 0 ? value : null;
}

function checkoutCompletedEvent(
  session: Stripe.Checkout.Session,
  eventCreated: number | undefined,
  subject: StripeBillingAnalyticsSubject,
  common: Record<string, unknown>,
): MappedBillingEvent {
  const attribution = checkoutAttributionFromMetadata(session.metadata);
  const paidAt = typeof eventCreated === "number" ? new Date(eventCreated * 1000) : new Date();
  const plan = metadataString(session.metadata, "plan");
  const amountDiscount = session.total_details?.amount_discount ?? null;
  return {
    name: "cmux_billing_checkout_completed",
    properties: {
      ...common,
      plan,
      billing_interval: metadataString(session.metadata, "billingInterval"),
      amount_total: session.amount_total,
      amount_discount: amountDiscount,
      promotion_applied: (amountDiscount ?? 0) > 0,
      currency: session.currency,
      payment_status: session.payment_status,
      payment_method_types: session.payment_method_types ?? null,
      customer_country: session.customer_details?.address?.country ?? null,
      // Seconds between Stripe creating the session and the payment
      // settling: how long the Stripe form itself took.
      checkout_duration_seconds: checkoutDurationSeconds(session.created, eventCreated),
      stripe_checkout_session_id: session.id,
      stripe_subscription_id: stringId(session.subscription),
      stripe_customer_id: stringId(session.customer),
      ...checkoutAttributionProperties(attribution),
      $set: { billing_plan: plan, billing_customer_type: subject.scope },
      $set_once: firstPaidCheckoutPersonProperties(attribution, paidAt),
    },
  };
}

// Stripe expires a Checkout Session ~24h after creation when the buyer never
// paid. Attribution tells which surface loses people at the form.
function checkoutExpiredEvent(
  session: Stripe.Checkout.Session,
  common: Record<string, unknown>,
): MappedBillingEvent {
  const attribution = checkoutAttributionFromMetadata(session.metadata);
  return {
    name: "cmux_billing_checkout_expired",
    properties: {
      ...common,
      plan: metadataString(session.metadata, "plan"),
      billing_interval: metadataString(session.metadata, "billingInterval"),
      amount_total: session.amount_total,
      currency: session.currency,
      stripe_checkout_session_id: session.id,
      stripe_customer_id: stringId(session.customer),
      ...checkoutAttributionProperties(attribution),
    },
  };
}

function subscriptionEvent(
  subscription: Stripe.Subscription,
  action: "created" | "updated" | "deleted",
  common: Record<string, unknown>,
): MappedBillingEvent {
  const attribution = checkoutAttributionFromMetadata(subscription.metadata);
  return {
    name: `cmux_billing_subscription_${action}`,
    properties: {
      ...common,
      plan: metadataString(subscription.metadata, "plan"),
      billing_interval: metadataString(subscription.metadata, "billingInterval"),
      subscription_status: subscription.status,
      cancel_at_period_end: subscription.cancel_at_period_end,
      cancellation_reason: subscription.cancellation_details?.reason ?? null,
      cancellation_feedback: subscription.cancellation_details?.feedback ?? null,
      stripe_subscription_id: subscription.id,
      stripe_customer_id: stringId(subscription.customer),
      ...checkoutAttributionProperties(attribution),
    },
  };
}

function invoiceEvent(
  invoice: Stripe.Invoice,
  type: "invoice.paid" | "invoice.payment_failed",
  common: Record<string, unknown>,
): MappedBillingEvent {
  return {
    name: type === "invoice.paid"
      ? "cmux_billing_invoice_paid"
      : "cmux_billing_invoice_payment_failed",
    properties: {
      ...common,
      amount_due: invoice.amount_due,
      amount_paid: invoice.amount_paid,
      currency: invoice.currency,
      billing_reason: invoice.billing_reason,
      stripe_invoice_id: invoice.id,
      stripe_customer_id: stringId(invoice.customer),
    },
  };
}

function refundEvent(
  charge: Stripe.Charge,
  common: Record<string, unknown>,
): MappedBillingEvent {
  return {
    name: "cmux_billing_charge_refunded",
    properties: {
      ...common,
      amount: charge.amount,
      amount_refunded: charge.amount_refunded,
      currency: charge.currency,
      fully_refunded: charge.refunded,
      stripe_charge_id: charge.id,
      stripe_customer_id: stringId(charge.customer),
    },
  };
}

function subjectDistinctId(subject: StripeBillingAnalyticsSubject): string | null {
  const principalId = subject.scope === "user"
    ? subject.stackUserId
    : subject.stackTeamId;
  if (typeof principalId !== "string" || principalId.trim().length === 0) return null;
  return subject.scope === "user" ? principalId : `stack-team:${principalId}`;
}

async function captureBillingPayload(
  input: {
    readonly name: string;
    readonly insertId: string;
    readonly subject: StripeBillingAnalyticsSubject;
    readonly properties: Record<string, unknown>;
  },
  postHogFetch?: typeof fetch,
): Promise<void> {
  // The production transport is unavailable in test runs. An explicitly
  // injected fetch remains a deliberate unit-test seam for payload mapping;
  // normal callers omit it and fail closed here.
  if (isAnalyticsTestRun() && !postHogFetch) return;
  const fetchImpl = postHogFetch ?? fetch;
  const distinctId = subjectDistinctId(input.subject);
  if (!distinctId) return;

  const body = JSON.stringify({
    api_key: POSTHOG_PROJECT_KEY,
    event: input.name,
    properties: {
      distinct_id: distinctId,
      $insert_id: input.insertId,
      ...(input.subject.scope === "team"
        ? { $groups: { stack_team: input.subject.stackTeamId } }
        : {}),
      ...input.properties,
    },
  });
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const response = await fetchImpl(`${POSTHOG_HOST}/capture/`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body,
        signal: AbortSignal.timeout(CAPTURE_TIMEOUT_MS),
      });
      if (response.ok || response.status < 500) return;
    } catch {
      // Retry once with the same insert id; never fail billing traffic.
    }
  }
}

function subscriptionEventAction(
  type:
    | "customer.subscription.created"
    | "customer.subscription.updated"
    | "customer.subscription.deleted",
): "created" | "updated" | "deleted" {
  return type.slice("customer.subscription.".length) as
    | "created"
    | "updated"
    | "deleted";
}

function checkoutDurationSeconds(
  sessionCreated: number | null | undefined,
  eventCreated: number | null | undefined,
): number | null {
  if (typeof sessionCreated !== "number" || typeof eventCreated !== "number") return null;
  const seconds = eventCreated - sessionCreated;
  return seconds >= 0 ? seconds : null;
}

function stringId(
  value: string | { readonly id: string } | null | undefined,
): string | null {
  if (!value) return null;
  return typeof value === "string" ? value : value.id;
}
