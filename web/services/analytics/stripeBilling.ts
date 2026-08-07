import type Stripe from "stripe";

import {
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
  postHogFetch: typeof fetch = fetch,
): Promise<void> {
  const mapped = mappedBillingEvent(event, subject);
  if (!mapped) return;

  try {
    await postHogFetch(`${POSTHOG_HOST}/capture/`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        api_key: POSTHOG_PROJECT_KEY,
        event: mapped.name,
        properties: {
          distinct_id: subjectDistinctId(subject),
          // Stripe redeliveries and route retries keep one PostHog event.
          $insert_id: event.id,
          ...mapped.properties,
        },
      }),
      signal: AbortSignal.timeout(CAPTURE_TIMEOUT_MS),
    });
  } catch {
    // Analytics is deliberately non-authoritative.
  }
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
    default:
      return null;
  }
}

function subjectDistinctId(subject: StripeBillingAnalyticsSubject): string {
  return subject.scope === "user"
    ? subject.stackUserId
    : `stack-team:${subject.stackTeamId}`;
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
