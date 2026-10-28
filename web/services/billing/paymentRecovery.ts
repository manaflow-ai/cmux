import type Stripe from "stripe";

import { captureBillingError } from "../errors";
import { applySubscriptionUpdate as applySubscriptionUpdateDefault } from "./purchase";
import { stripe as stripeDefault } from "./stripe";

/**
 * Subscription states with an unpaid invoice a new payment method can settle:
 * a failed renewal (`past_due`, then `unpaid` once retries run out) or a
 * failed first payment (`incomplete`).
 */
export const PAYMENT_RECOVERY_STATUSES = ["past_due", "unpaid", "incomplete"] as const;

/**
 * - `recovered`: every failed subscription now charges the new payment method
 *   and its open invoice was paid.
 * - `payment_failed`: the new payment method was declined for an open invoice.
 * - `no_payment_method`: the customer has no default payment method to charge.
 * - `nothing_due`: no cmux subscription of this customer needs a payment.
 */
export type PaymentRecoveryOutcome = "recovered" | "payment_failed" | "no_payment_method" | "nothing_due";

export type PaymentRecoveryDependencies = {
  readonly stripe?: () => Pick<Stripe, "customers" | "subscriptions" | "invoices">;
  readonly applySubscriptionUpdate?: (subscription: Stripe.Subscription) => Promise<unknown>;
};

/**
 * Settles a customer's failed cmux subscriptions with the payment method they
 * just saved in the Stripe portal.
 *
 * The portal only sets the customer's default payment method. A subscription
 * from Checkout keeps its own `default_payment_method`, which outranks the
 * customer default, so Stripe would retry the declined card and the open
 * invoice would wait days for the next scheduled retry. This points each
 * failed subscription at the new payment method, pays its open invoice now,
 * and records the result without waiting for the webhook.
 */
export async function recoverFailedSubscriptionPayments(
  customerId: string,
  dependencies: PaymentRecoveryDependencies = {},
): Promise<PaymentRecoveryOutcome> {
  const client = (dependencies.stripe ?? stripeDefault)();
  const applySubscriptionUpdate = dependencies.applySubscriptionUpdate ?? applySubscriptionUpdateDefault;
  const customer = await client.customers.retrieve(customerId);
  const paymentMethodId = customer.deleted ? null : stripeId(customer.invoice_settings?.default_payment_method);
  const subscriptions = await client.subscriptions.list({ customer: customerId, status: "all", limit: 100 });
  const failed = subscriptions.data.filter(needsPaymentRecovery);
  if (failed.length === 0) return "nothing_due";
  if (!paymentMethodId) return "no_payment_method";

  let declined = false;
  for (const subscription of failed) {
    const override = stripeId(subscription.default_payment_method);
    if (override && override !== paymentMethodId) {
      await client.subscriptions.update(subscription.id, { default_payment_method: paymentMethodId });
    }
    const invoiceId = stripeId(subscription.latest_invoice);
    if (invoiceId && !(await payOpenInvoice(client, invoiceId, paymentMethodId))) declined = true;
    await recordSubscription(client, subscription.id, applySubscriptionUpdate);
  }
  return declined ? "payment_failed" : "recovered";
}

function needsPaymentRecovery(subscription: Stripe.Subscription): boolean {
  // Founder's Edition is a one-time purchase and foreign subscriptions are not
  // ours to charge; both stay untouched like the webhook leaves them.
  if (subscription.metadata?.app !== "cmux" || subscription.metadata?.founders_edition === "true") return false;
  return (PAYMENT_RECOVERY_STATUSES as readonly string[]).includes(subscription.status);
}

/** Pays an open invoice; false when the card was declined. */
async function payOpenInvoice(
  client: Pick<Stripe, "invoices">,
  invoiceId: string,
  paymentMethodId: string,
): Promise<boolean> {
  const invoice = await client.invoices.retrieve(invoiceId);
  if (invoice.status !== "open") return true;
  try {
    await client.invoices.pay(invoiceId, { payment_method: paymentMethodId });
    return true;
  } catch (error) {
    if (isStripeCardError(error)) return false;
    // A second return (a reload or double click) can lose the race to pay.
    if ((await client.invoices.retrieve(invoiceId)).status === "paid") return true;
    throw error;
  }
}

/** The payment already happened, so a database hiccup leaves the update to the webhook. */
async function recordSubscription(
  client: Pick<Stripe, "subscriptions">,
  subscriptionId: string,
  applySubscriptionUpdate: (subscription: Stripe.Subscription) => Promise<unknown>,
): Promise<void> {
  try {
    await applySubscriptionUpdate(await client.subscriptions.retrieve(subscriptionId));
  } catch (error) {
    captureBillingError(error, { operation: "payment_recovery_record", subscriptionId });
  }
}

function isStripeCardError(error: unknown): boolean {
  return typeof error === "object" && error !== null && (error as { type?: unknown }).type === "StripeCardError";
}

function stripeId(value: string | { readonly id: string } | null | undefined): string | null {
  if (!value) return null;
  return typeof value === "string" ? value : value.id;
}

/** The `flow` values `/api/billing/portal` serves for a payment method update. */
export const PAYMENT_METHOD_UPDATE_FLOW = "payment_method_update";
export const PAYMENT_METHOD_RETURN_FLOW = "payment_method_return";

/**
 * A portal session that opens straight on "Update payment method" and comes
 * back to `returnURL` (the portal route's return flow) when the customer saves
 * a card or leaves.
 */
export async function paymentMethodUpdatePortalSession(
  input: { readonly customerId: string; readonly returnURL: string },
  dependencies: { readonly stripe?: () => Pick<Stripe, "billingPortal"> } = {},
): Promise<{ readonly url: string }> {
  const session = await (dependencies.stripe ?? stripeDefault)().billingPortal.sessions.create({
    customer: input.customerId,
    return_url: input.returnURL,
    flow_data: {
      type: "payment_method_update",
      after_completion: { type: "redirect", redirect: { return_url: input.returnURL } },
    },
  });
  if (!session.url) throw new Error("Stripe Billing Portal Session did not include a URL");
  return { url: session.url };
}
