import type Stripe from "stripe";

import {
  isAnalyticsTestRun,
  POSTHOG_HOST,
  POSTHOG_PROJECT_KEY,
} from "./iosEventPolicy";

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
    },
  }, postHogFetch);
}

function mappedBillingEvent(
  event: Stripe.Event,
  subject: StripeBillingAnalyticsSubject,
): { readonly name: string; readonly properties: Record<string, unknown> } | null {
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

  switch (event.type) {
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded": {
      const session = event.data.object;
      const customerId = stringId(session.customer);
      return {
        name: "cmux_billing_checkout_completed",
        properties: {
          ...common,
          plan: session.metadata?.plan ?? null,
          billing_interval: session.metadata?.billingInterval ?? null,
          amount_total: session.amount_total,
          currency: session.currency,
          payment_status: session.payment_status,
          stripe_checkout_session_id: session.id,
          stripe_subscription_id: stringId(session.subscription),
          stripe_customer_id: customerId,
        },
      };
    }
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted": {
      const subscription = event.data.object;
      const customerId = stringId(subscription.customer);
      return {
        name: `cmux_billing_subscription_${subscriptionEventAction(event.type)}`,
        properties: {
          ...common,
          plan: subscription.metadata?.plan ?? null,
          billing_interval: subscription.metadata?.billingInterval ?? null,
          subscription_status: subscription.status,
          cancel_at_period_end: subscription.cancel_at_period_end,
          stripe_subscription_id: subscription.id,
          stripe_customer_id: customerId,
        },
      };
    }
    case "invoice.paid":
    case "invoice.payment_failed": {
      const invoice = event.data.object;
      const customerId = stringId(invoice.customer);
      return {
        name: event.type === "invoice.paid"
          ? "cmux_billing_invoice_paid"
          : "cmux_billing_invoice_payment_failed",
        properties: {
          ...common,
          amount_due: invoice.amount_due,
          amount_paid: invoice.amount_paid,
          currency: invoice.currency,
          billing_reason: invoice.billing_reason,
          stripe_invoice_id: invoice.id,
          stripe_customer_id: customerId,
        },
      };
    }
    case "charge.refunded": {
      const charge = event.data.object;
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
    default:
      return null;
  }
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

function stringId(
  value: string | { readonly id: string } | null | undefined,
): string | null {
  if (!value) return null;
  return typeof value === "string" ? value : value.id;
}
