import { createHmac, timingSafeEqual } from "node:crypto";

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
 * - `recovered`: every failed subscription was paid with the new payment
 *   method and is active again.
 * - `action_required`: the bank asks the customer to authenticate (3D Secure)
 *   on Stripe's hosted invoice page, `hostedInvoiceURL`.
 * - `payment_failed`: the new payment method was declined, or a subscription
 *   is still not active after its open invoices were paid.
 * - `no_payment_method`: the customer has no default payment method to charge.
 * - `nothing_due`: no cmux subscription of this customer needs a payment.
 */
export type PaymentRecoveryResult =
  | { readonly outcome: "recovered" | "payment_failed" | "no_payment_method" | "nothing_due" }
  | { readonly outcome: "action_required"; readonly hostedInvoiceURL: string };
export type PaymentRecoveryOutcome = PaymentRecoveryResult["outcome"];

export type PaymentRecoveryDependencies = {
  readonly stripe?: () => Pick<Stripe, "customers" | "subscriptions" | "invoices">;
  readonly applySubscriptionUpdate?: (subscription: Stripe.Subscription) => Promise<unknown>;
};

type StripeClient = Pick<Stripe, "customers" | "subscriptions" | "invoices">;
type InvoicePayment = { readonly kind: "paid" } | { readonly kind: "declined" } | { readonly kind: "action"; readonly url: string };

/**
 * Settles a customer's failed cmux subscriptions with the payment method they
 * just saved in the Stripe portal.
 *
 * The portal only sets the customer's default payment method. A subscription
 * from Checkout keeps its own `default_payment_method`, which outranks the
 * customer default, so Stripe would retry the declined card and the open
 * invoice would wait days for the next scheduled retry. This points each
 * failed subscription at the new payment method, pays its open invoices now,
 * and records the result without waiting for the webhook.
 */
export async function recoverFailedSubscriptionPayments(
  customerId: string,
  dependencies: PaymentRecoveryDependencies = {},
): Promise<PaymentRecoveryResult> {
  const client = (dependencies.stripe ?? stripeDefault)();
  const applySubscriptionUpdate = dependencies.applySubscriptionUpdate ?? applySubscriptionUpdateDefault;
  const customer = await client.customers.retrieve(customerId);
  const paymentMethodId = customer.deleted ? null : stripeId(customer.invoice_settings?.default_payment_method);
  const failed = await failedSubscriptions(client, customerId);
  if (failed.length === 0) return { outcome: "nothing_due" };
  if (!paymentMethodId) return { outcome: "no_payment_method" };

  let declined = false;
  let actionURL: string | null = null;
  for (const subscription of failed) {
    const override = stripeId(subscription.default_payment_method);
    if (override && override !== paymentMethodId) {
      await client.subscriptions.update(subscription.id, { default_payment_method: paymentMethodId });
    }
    for (const payment of await payOutstandingInvoices(client, subscription, paymentMethodId)) {
      if (payment.kind === "declined") declined = true;
      if (payment.kind === "action") actionURL ??= payment.url;
    }
    const current = await recordSubscription(client, subscription.id, applySubscriptionUpdate);
    if (current && current.status !== "active" && current.status !== "trialing") declined = true;
  }
  // Authentication comes first: the hosted invoice page is the only step that
  // can finish it, and the dashboard still shows any other failed plan after.
  if (actionURL) return { outcome: "action_required", hostedInvoiceURL: actionURL };
  return { outcome: declined ? "payment_failed" : "recovered" };
}

/** Every failed cmux subscription of the customer, one list per status so none hides behind old canceled ones. */
async function failedSubscriptions(client: StripeClient, customerId: string): Promise<Stripe.Subscription[]> {
  const lists = await Promise.all(PAYMENT_RECOVERY_STATUSES.map((status) =>
    client.subscriptions.list({ customer: customerId, status, limit: 100 })
  ));
  return lists.flatMap((list) => list.data).filter(isCmuxSubscription);
}

function isCmuxSubscription(subscription: Stripe.Subscription): boolean {
  // Founder's Edition is a one-time purchase and foreign subscriptions are not
  // ours to charge; both stay untouched like the webhook leaves them.
  return subscription.metadata?.app === "cmux" && subscription.metadata?.founders_edition !== "true";
}

/**
 * Pays every outstanding invoice of the subscription, oldest first. An
 * `unpaid` subscription closes the renewals it creates, so the debt can sit
 * on an older invoice than `latest_invoice`; and when the account's dunning
 * marks invoices uncollectible after the last retry, that debt is
 * `uncollectible`, not `open`, and still payable.
 */
async function payOutstandingInvoices(
  client: StripeClient,
  subscription: Stripe.Subscription,
  paymentMethodId: string,
): Promise<InvoicePayment[]> {
  const statuses: Stripe.InvoiceListParams.Status[] = subscription.status === "unpaid" ? ["open", "uncollectible"] : ["open"];
  const lists = await Promise.all(statuses.map((status) =>
    client.invoices.list({ subscription: subscription.id, status, limit: 100 })
  ));
  const invoices = lists.flatMap((list) => list.data).sort((a, b) => a.created - b.created);
  const payments: InvoicePayment[] = [];
  for (const invoice of invoices) {
    if (!invoice.id) continue;
    const payment = await payInvoice(client, invoice.id, paymentMethodId);
    payments.push(payment);
    if (payment.kind !== "paid") break;
  }
  return payments;
}

async function payInvoice(client: StripeClient, invoiceId: string, paymentMethodId: string): Promise<InvoicePayment> {
  try {
    await client.invoices.pay(invoiceId, { payment_method: paymentMethodId });
    return { kind: "paid" };
  } catch (error) {
    // Keep Stripe's original error if the follow-up read fails too.
    const invoice = await client.invoices.retrieve(invoiceId).catch(() => {
      throw error;
    });
    // A second return (a reload or double click) can lose the race to pay.
    if (invoice.status === "paid") return { kind: "paid" };
    if (!isStripeCardError(error)) throw error;
    // The bank wants 3D Secure: off-session payment cannot finish, the hosted
    // invoice page can.
    if (AUTHENTICATION_ERROR_CODES.has(stripeErrorCode(error) ?? "") && invoice.hosted_invoice_url) {
      return { kind: "action", url: invoice.hosted_invoice_url };
    }
    return { kind: "declined" };
  }
}

/** The payment already happened, so a database hiccup leaves the update to the webhook. */
async function recordSubscription(
  client: Pick<Stripe, "subscriptions">,
  subscriptionId: string,
  applySubscriptionUpdate: (subscription: Stripe.Subscription) => Promise<unknown>,
): Promise<Stripe.Subscription | null> {
  let current: Stripe.Subscription | null = null;
  try {
    current = await client.subscriptions.retrieve(subscriptionId);
    await applySubscriptionUpdate(current);
  } catch (error) {
    captureBillingError(error, { operation: "payment_recovery_record", subscriptionId });
  }
  return current;
}

/**
 * Card errors that mean "authenticate", not "declined". Stripe answers
 * `invoices.pay` with the first; `authentication_required` is the plain
 * PaymentIntent form.
 */
const AUTHENTICATION_ERROR_CODES = new Set(["invoice_payment_intent_requires_action", "authentication_required"]);

function isStripeCardError(error: unknown): boolean {
  return typeof error === "object" && error !== null && (error as { type?: unknown }).type === "StripeCardError";
}

function stripeErrorCode(error: unknown): string | null {
  const code = typeof error === "object" && error !== null ? (error as { code?: unknown }).code : null;
  return typeof code === "string" ? code : null;
}

function stripeId(value: string | { readonly id?: string } | null | undefined): string | null {
  if (!value) return null;
  return typeof value === "string" ? value : value.id ?? null;
}

/** The `flow` values `/api/billing/portal` serves for a payment method update. */
export const PAYMENT_METHOD_UPDATE_FLOW = "payment_method_update";
export const PAYMENT_METHOD_RETURN_FLOW = "payment_method_return";

/** How long a portal's completion link may settle payments; portal sessions live about an hour past activity. */
const PAYMENT_RETURN_TOKEN_TTL_SECONDS = 24 * 60 * 60;

/**
 * Proof that a return came from the portal session this route created for
 * `customerId`, so a link from elsewhere never makes a charge. Bound to the
 * customer and an expiry, signed with the Stripe secret this deployment
 * already holds.
 */
export function paymentReturnToken(customerId: string, now: Date = new Date()): string | null {
  const expires = Math.floor(now.getTime() / 1000) + PAYMENT_RETURN_TOKEN_TTL_SECONDS;
  const signature = paymentReturnSignature(customerId, String(expires));
  return signature ? `${expires}.${signature}` : null;
}

export function isValidPaymentReturnToken(token: string | null, customerId: string, now: Date = new Date()): boolean {
  const [expires, signature, ...rest] = (token ?? "").split(".");
  if (!expires || !signature || rest.length > 0 || !/^\d+$/.test(expires) || !/^[a-f0-9]{64}$/.test(signature)) return false;
  if (Number(expires) < Math.floor(now.getTime() / 1000)) return false;
  const expected = paymentReturnSignature(customerId, expires);
  return expected !== null && timingSafeEqual(Buffer.from(signature, "hex"), Buffer.from(expected, "hex"));
}

function paymentReturnSignature(customerId: string, expires: string): string | null {
  // Read at call time, like the Stripe client, so tests and rotations apply.
  const secret = process.env.STRIPE_SECRET_KEY?.trim();
  if (!secret) return null;
  return createHmac("sha256", secret)
    .update(["cmux-payment-method-return-v1", customerId, expires].join("\n"))
    .digest("hex");
}

/**
 * A portal session that opens straight on "Update payment method". Saving a
 * card goes to `completedURL`, the portal route's settling return; leaving
 * without saving goes to `cancelURL` and charges nothing.
 */
export async function paymentMethodUpdatePortalSession(
  input: { readonly customerId: string; readonly completedURL: string; readonly cancelURL: string },
  dependencies: { readonly stripe?: () => Pick<Stripe, "billingPortal"> } = {},
): Promise<{ readonly url: string }> {
  const session = await (dependencies.stripe ?? stripeDefault)().billingPortal.sessions.create({
    customer: input.customerId,
    return_url: input.cancelURL,
    flow_data: {
      type: "payment_method_update",
      after_completion: { type: "redirect", redirect: { return_url: input.completedURL } },
    },
  });
  if (!session.url) throw new Error("Stripe Billing Portal Session did not include a URL");
  return { url: session.url };
}
