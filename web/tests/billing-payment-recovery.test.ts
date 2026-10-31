import { describe, expect, mock, test } from "bun:test";
import type Stripe from "stripe";

import {
  isValidPaymentReturnToken,
  paymentReturnToken,
  recoverFailedSubscriptionPayments,
} from "../services/billing/paymentRecovery";

type FakeSubscription = {
  id: string;
  status: string;
  metadata: Record<string, string>;
  default_payment_method: string | null;
};

type FakeInvoice = {
  id: string;
  subscription: string;
  status: string;
  created: number;
  hosted_invoice_url?: string;
};

// The return token is signed with the Stripe secret.
process.env.STRIPE_SECRET_KEY ||= "sk_test_unit";

const DECLINED_CARD = "pm_declined";
const NEW_CARD = "pm_new";

/**
 * A Stripe double holding one customer. Paying an invoice charges the
 * payment method it was asked to charge: `declinedCards` raise Stripe's card
 * error the way the SDK does, `authenticationCards` raise the 3D Secure one.
 * A subscription becomes active once none of its invoices is open.
 */
function fakeStripe(input: {
  defaultPaymentMethod: string | null;
  subscriptions: FakeSubscription[];
  invoices?: FakeInvoice[];
  declinedCards?: string[];
  authenticationCards?: string[];
  /** Another request pays the invoice first, so this pay call fails. */
  lostPayRace?: boolean;
}) {
  const declined = new Set(input.declinedCards ?? [DECLINED_CARD]);
  const authentication = new Set(input.authenticationCards ?? []);
  const subscriptions = new Map(input.subscriptions.map((subscription) => [subscription.id, { ...subscription }]));
  const invoices = new Map((input.invoices ?? input.subscriptions.map((subscription, index) => ({
    id: `in_${subscription.id}`, subscription: subscription.id, status: "open", created: index,
  }))).map((invoice) => [invoice.id, { ...invoice }]));
  const client = {
    customers: {
      retrieve: mock(async () => ({
        id: "cus_1",
        invoice_settings: { default_payment_method: input.defaultPaymentMethod },
      })),
    },
    subscriptions: {
      list: mock(async (params: { status: string }) => ({
        data: [...subscriptions.values()].filter((subscription) => subscription.status === params.status).map((subscription) => ({ ...subscription })),
      })),
      retrieve: mock(async (id: string) => ({ ...subscriptions.get(id)! })),
      update: mock(async (id: string, params: { default_payment_method?: string }) => {
        const subscription = subscriptions.get(id)!;
        if (params.default_payment_method) subscription.default_payment_method = params.default_payment_method;
        return { ...subscription };
      }),
    },
    invoices: {
      list: mock(async (params: { subscription: string; status: string }) => ({
        data: [...invoices.values()].filter((invoice) => invoice.subscription === params.subscription && invoice.status === params.status),
      })),
      retrieve: mock(async (id: string) => ({ ...invoices.get(id)! })),
      pay: mock(async (id: string, params: { payment_method?: string }) => {
        const card = params.payment_method ?? "";
        if (authentication.has(card)) {
          // The code Stripe's test mode returns from invoices.pay for a 3DS card.
          throw Object.assign(new Error("The invoice payment requires additional action."), {
            type: "StripeCardError", code: "invoice_payment_intent_requires_action",
          });
        }
        if (declined.has(card)) {
          throw Object.assign(new Error("Your card was declined."), { type: "StripeCardError", code: "card_declined" });
        }
        const invoice = invoices.get(id)!;
        invoice.status = "paid";
        const subscription = subscriptions.get(invoice.subscription)!;
        if (![...invoices.values()].some((other) => other.subscription === subscription.id && other.status === "open")) {
          subscription.status = "active";
        }
        if (input.lostPayRace) {
          throw Object.assign(new Error("Invoice is already paid"), { type: "StripeInvalidRequestError" });
        }
        return { ...invoice };
      }),
    },
  };
  return client;
}

function recover(
  client: ReturnType<typeof fakeStripe>,
  applySubscriptionUpdate: (subscription: Stripe.Subscription) => Promise<unknown> = async () => undefined,
) {
  return recoverFailedSubscriptionPayments("cus_1", {
    stripe: () => client as unknown as Pick<Stripe, "customers" | "subscriptions" | "invoices">,
    applySubscriptionUpdate,
  });
}

function cmuxSubscription(overrides: Partial<FakeSubscription> = {}): FakeSubscription {
  return {
    id: "sub_1",
    status: "past_due",
    metadata: { app: "cmux", plan: "pro" },
    default_payment_method: DECLINED_CARD,
    ...overrides,
  };
}

describe("recoverFailedSubscriptionPayments", () => {
  // The bug: the portal saves the new card as the customer default, but the
  // subscription's own default (the declined card from Checkout) outranks it.
  test("moves a past-due subscription off its declined card and pays the open invoice with the new one", async () => {
    const client = fakeStripe({ defaultPaymentMethod: NEW_CARD, subscriptions: [cmuxSubscription()] });
    const recorded: Stripe.Subscription[] = [];

    expect(await recover(client, async (subscription) => recorded.push(subscription))).toEqual({ outcome: "recovered" });
    expect(client.subscriptions.update).toHaveBeenCalledWith("sub_1", { default_payment_method: NEW_CARD });
    expect(client.invoices.pay).toHaveBeenCalledWith("in_sub_1", { payment_method: NEW_CARD });
    expect(recorded).toHaveLength(1);
    expect(recorded[0]).toMatchObject({ id: "sub_1", status: "active", default_payment_method: NEW_CARD });
  });

  test.each(["unpaid", "incomplete"])("settles a %s subscription the same way", async (status) => {
    const client = fakeStripe({ defaultPaymentMethod: NEW_CARD, subscriptions: [cmuxSubscription({ status })] });

    expect(await recover(client)).toEqual({ outcome: "recovered" });
    expect(client.invoices.pay).toHaveBeenCalledWith("in_sub_1", { payment_method: NEW_CARD });
  });

  // An unpaid subscription closes the renewals it creates, so the debt sits on
  // an older invoice than the latest one.
  test("pays every open invoice of an unpaid subscription, oldest first", async () => {
    const client = fakeStripe({
      defaultPaymentMethod: NEW_CARD,
      subscriptions: [cmuxSubscription({ status: "unpaid" })],
      invoices: [
        { id: "in_closed_renewal", subscription: "sub_1", status: "draft", created: 3 },
        { id: "in_second", subscription: "sub_1", status: "open", created: 2 },
        { id: "in_first", subscription: "sub_1", status: "open", created: 1 },
      ],
    });

    expect(await recover(client)).toEqual({ outcome: "recovered" });
    expect(client.invoices.pay.mock.calls.map(([id]) => id)).toEqual(["in_first", "in_second"]);
  });

  test("pays the debt dunning marked uncollectible on an unpaid subscription", async () => {
    const client = fakeStripe({
      defaultPaymentMethod: NEW_CARD,
      subscriptions: [cmuxSubscription({ status: "unpaid" })],
      invoices: [
        { id: "in_open_renewal", subscription: "sub_1", status: "open", created: 2 },
        { id: "in_uncollectible", subscription: "sub_1", status: "uncollectible", created: 1 },
      ],
    });

    expect(await recover(client)).toEqual({ outcome: "recovered" });
    expect(client.invoices.pay.mock.calls.map(([id]) => id)).toEqual(["in_uncollectible", "in_open_renewal"]);
  });

  test("reports failure when a subscription is still not active after paying", async () => {
    const client = fakeStripe({
      defaultPaymentMethod: NEW_CARD,
      subscriptions: [cmuxSubscription({ status: "unpaid" })],
      invoices: [{ id: "in_closed_renewal", subscription: "sub_1", status: "draft", created: 1 }],
    });

    expect(await recover(client)).toEqual({ outcome: "payment_failed" });
  });

  test("covers every cmux plan, including Max and Team", async () => {
    const client = fakeStripe({
      defaultPaymentMethod: NEW_CARD,
      subscriptions: [
        cmuxSubscription({ id: "sub_max", metadata: { app: "cmux", plan: "max" } }),
        cmuxSubscription({ id: "sub_team", metadata: { app: "cmux", plan: "team", scope: "team" } }),
      ],
    });

    expect(await recover(client)).toEqual({ outcome: "recovered" });
    expect(client.invoices.pay.mock.calls.map(([id]) => id)).toEqual(["in_sub_max", "in_sub_team"]);
  });

  test("reports a decline of the new card without throwing", async () => {
    const client = fakeStripe({
      defaultPaymentMethod: NEW_CARD,
      subscriptions: [cmuxSubscription()],
      declinedCards: [DECLINED_CARD, NEW_CARD],
    });

    expect(await recover(client)).toEqual({ outcome: "payment_failed" });
  });

  test("sends a card that needs 3D Secure to Stripe's hosted invoice page", async () => {
    const client = fakeStripe({
      defaultPaymentMethod: NEW_CARD,
      subscriptions: [cmuxSubscription()],
      invoices: [{ id: "in_1", subscription: "sub_1", status: "open", created: 1, hosted_invoice_url: "https://invoice.stripe.com/i/in_1" }],
      authenticationCards: [NEW_CARD],
    });

    expect(await recover(client)).toEqual({ outcome: "action_required", hostedInvoiceURL: "https://invoice.stripe.com/i/in_1" });
  });

  test("leaves the subscription alone when it already uses the customer default", async () => {
    const client = fakeStripe({ defaultPaymentMethod: NEW_CARD, subscriptions: [cmuxSubscription({ default_payment_method: null })] });

    expect(await recover(client)).toEqual({ outcome: "recovered" });
    expect(client.subscriptions.update).not.toHaveBeenCalled();
    expect(client.invoices.pay).toHaveBeenCalledWith("in_sub_1", { payment_method: NEW_CARD });
  });

  test("never touches healthy, foreign, or Founder's Edition subscriptions", async () => {
    const client = fakeStripe({
      defaultPaymentMethod: NEW_CARD,
      subscriptions: [
        cmuxSubscription({ id: "sub_active", status: "active" }),
        cmuxSubscription({ id: "sub_foreign", metadata: { app: "other" } }),
        cmuxSubscription({ id: "sub_founder", metadata: { app: "cmux", founders_edition: "true" } }),
      ],
    });

    expect(await recover(client)).toEqual({ outcome: "nothing_due" });
    expect(client.subscriptions.update).not.toHaveBeenCalled();
    expect(client.invoices.pay).not.toHaveBeenCalled();
  });

  test("reports no payment method when the customer has no default card", async () => {
    const client = fakeStripe({ defaultPaymentMethod: null, subscriptions: [cmuxSubscription()] });

    expect(await recover(client)).toEqual({ outcome: "no_payment_method" });
    expect(client.invoices.pay).not.toHaveBeenCalled();
  });

  test("keeps the paid result when recording the subscription fails", async () => {
    const client = fakeStripe({ defaultPaymentMethod: NEW_CARD, subscriptions: [cmuxSubscription()] });
    const failingRecord = async () => {
      throw new Error("database unavailable");
    };

    expect(await recover(client, failingRecord)).toEqual({ outcome: "recovered" });
  });

  test("treats an invoice a concurrent return already paid as recovered", async () => {
    const client = fakeStripe({ defaultPaymentMethod: NEW_CARD, subscriptions: [cmuxSubscription()], lostPayRace: true });

    expect(await recover(client)).toEqual({ outcome: "recovered" });
  });

  test("keeps Stripe's payment error when the follow-up invoice read fails too", async () => {
    const client = fakeStripe({ defaultPaymentMethod: NEW_CARD, subscriptions: [cmuxSubscription()] });
    client.invoices.pay.mockImplementation(async () => {
      throw Object.assign(new Error("Stripe is unavailable"), { type: "StripeAPIError" });
    });
    client.invoices.retrieve.mockImplementation(async () => {
      throw new Error("read failed");
    });

    await expect(recover(client)).rejects.toThrow("Stripe is unavailable");
  });

  test("propagates Stripe errors that are not card declines", async () => {
    const client = fakeStripe({ defaultPaymentMethod: NEW_CARD, subscriptions: [cmuxSubscription()] });
    client.invoices.pay.mockImplementation(async () => {
      throw Object.assign(new Error("Stripe is unavailable"), { type: "StripeAPIError" });
    });

    await expect(recover(client)).rejects.toThrow("Stripe is unavailable");
  });
});

describe("payment return token", () => {
  const now = new Date("2026-10-27T12:00:00Z");

  test("accepts its own token for the same customer before it expires", () => {
    const token = paymentReturnToken("cus_1", now);

    expect(isValidPaymentReturnToken(token, "cus_1", now)).toBe(true);
    expect(isValidPaymentReturnToken(token, "cus_1", new Date(now.getTime() + 23 * 60 * 60 * 1000))).toBe(true);
  });

  test("refuses another customer's, an expired, a tampered, or a missing token", () => {
    const token = paymentReturnToken("cus_1", now)!;
    const [expires, signature] = token.split(".");

    expect(isValidPaymentReturnToken(token, "cus_2", now)).toBe(false);
    expect(isValidPaymentReturnToken(token, "cus_1", new Date(now.getTime() + 25 * 60 * 60 * 1000))).toBe(false);
    expect(isValidPaymentReturnToken(`${Number(expires) + 1}.${signature}`, "cus_1", now)).toBe(false);
    expect(isValidPaymentReturnToken(null, "cus_1", now)).toBe(false);
    expect(isValidPaymentReturnToken("garbage", "cus_1", now)).toBe(false);
  });
});
