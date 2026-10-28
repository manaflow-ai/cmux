import { describe, expect, mock, test } from "bun:test";
import type Stripe from "stripe";

import { recoverFailedSubscriptionPayments } from "../services/billing/paymentRecovery";

type FakeSubscription = {
  id: string;
  status: string;
  metadata: Record<string, string>;
  default_payment_method: string | null;
  latest_invoice: string | null;
};

const DECLINED_CARD = "pm_declined";
const NEW_CARD = "pm_new";

/**
 * A Stripe double holding one customer. Paying an invoice charges the
 * payment method it was asked to charge; `declinedCards` raise Stripe's
 * card error the way the SDK does.
 */
function fakeStripe(input: {
  defaultPaymentMethod: string | null;
  subscriptions: FakeSubscription[];
  invoiceStatus?: Record<string, string>;
  declinedCards?: string[];
}) {
  const invoiceStatus = { ...input.invoiceStatus };
  const declined = new Set(input.declinedCards ?? [DECLINED_CARD]);
  const subscriptions = new Map(input.subscriptions.map((subscription) => [subscription.id, { ...subscription }]));
  const client = {
    customers: {
      retrieve: mock(async () => ({
        id: "cus_1",
        invoice_settings: { default_payment_method: input.defaultPaymentMethod },
      })),
    },
    subscriptions: {
      list: mock(async () => ({ data: [...subscriptions.values()].map((subscription) => ({ ...subscription })) })),
      retrieve: mock(async (id: string) => ({ ...subscriptions.get(id)! })),
      update: mock(async (id: string, params: { default_payment_method?: string }) => {
        const subscription = subscriptions.get(id)!;
        if (params.default_payment_method) subscription.default_payment_method = params.default_payment_method;
        return { ...subscription };
      }),
    },
    invoices: {
      retrieve: mock(async (id: string) => ({ id, status: invoiceStatus[id] ?? "open" })),
      pay: mock(async (id: string, params: { payment_method?: string }) => {
        if (declined.has(params.payment_method ?? "")) {
          throw Object.assign(new Error("Your card was declined."), { type: "StripeCardError", code: "card_declined" });
        }
        invoiceStatus[id] = "paid";
        for (const subscription of subscriptions.values()) {
          if (subscription.latest_invoice === id) subscription.status = "active";
        }
        return { id, status: "paid" };
      }),
    },
  };
  return client;
}

function recover(client: ReturnType<typeof fakeStripe>, applySubscriptionUpdate = mock(async (_: Stripe.Subscription) => undefined)) {
  return {
    applySubscriptionUpdate,
    outcome: recoverFailedSubscriptionPayments("cus_1", {
      stripe: () => client as unknown as Pick<Stripe, "customers" | "subscriptions" | "invoices">,
      applySubscriptionUpdate,
    }),
  };
}

function cmuxSubscription(overrides: Partial<FakeSubscription> = {}): FakeSubscription {
  return {
    id: "sub_1",
    status: "past_due",
    metadata: { app: "cmux", plan: "pro" },
    default_payment_method: DECLINED_CARD,
    latest_invoice: "in_1",
    ...overrides,
  };
}

describe("recoverFailedSubscriptionPayments", () => {
  // The bug: the portal saves the new card as the customer default, but the
  // subscription's own default (the declined card from Checkout) outranks it.
  test("moves a past-due subscription off its declined card and pays the open invoice with the new one", async () => {
    const client = fakeStripe({ defaultPaymentMethod: NEW_CARD, subscriptions: [cmuxSubscription()] });
    const { outcome, applySubscriptionUpdate } = recover(client);

    expect(await outcome).toBe("recovered");
    expect(client.subscriptions.update).toHaveBeenCalledWith("sub_1", { default_payment_method: NEW_CARD });
    expect(client.invoices.pay).toHaveBeenCalledWith("in_1", { payment_method: NEW_CARD });
    expect(applySubscriptionUpdate).toHaveBeenCalledTimes(1);
    expect(applySubscriptionUpdate.mock.calls[0]?.[0]).toMatchObject({ id: "sub_1", status: "active", default_payment_method: NEW_CARD });
  });

  test.each(["unpaid", "incomplete"])("settles a %s subscription the same way", async (status) => {
    const client = fakeStripe({ defaultPaymentMethod: NEW_CARD, subscriptions: [cmuxSubscription({ status })] });

    expect(await recover(client).outcome).toBe("recovered");
    expect(client.invoices.pay).toHaveBeenCalledWith("in_1", { payment_method: NEW_CARD });
  });

  test("covers every cmux plan, including Max and Team", async () => {
    const client = fakeStripe({
      defaultPaymentMethod: NEW_CARD,
      subscriptions: [
        cmuxSubscription({ id: "sub_max", metadata: { app: "cmux", plan: "max" }, latest_invoice: "in_max" }),
        cmuxSubscription({ id: "sub_team", metadata: { app: "cmux", plan: "team", scope: "team" }, latest_invoice: "in_team" }),
      ],
    });

    expect(await recover(client).outcome).toBe("recovered");
    expect(client.invoices.pay.mock.calls.map(([id]) => id)).toEqual(["in_max", "in_team"]);
  });

  test("reports a decline of the new card without throwing", async () => {
    const client = fakeStripe({
      defaultPaymentMethod: NEW_CARD,
      subscriptions: [cmuxSubscription()],
      declinedCards: [DECLINED_CARD, NEW_CARD],
    });

    expect(await recover(client).outcome).toBe("payment_failed");
  });

  test("leaves the subscription alone when it already uses the customer default", async () => {
    const client = fakeStripe({ defaultPaymentMethod: NEW_CARD, subscriptions: [cmuxSubscription({ default_payment_method: null })] });

    expect(await recover(client).outcome).toBe("recovered");
    expect(client.subscriptions.update).not.toHaveBeenCalled();
    expect(client.invoices.pay).toHaveBeenCalledWith("in_1", { payment_method: NEW_CARD });
  });

  test("does not charge an invoice that is no longer open", async () => {
    const client = fakeStripe({
      defaultPaymentMethod: NEW_CARD,
      subscriptions: [cmuxSubscription()],
      invoiceStatus: { in_1: "paid" },
    });

    expect(await recover(client).outcome).toBe("recovered");
    expect(client.invoices.pay).not.toHaveBeenCalled();
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

    expect(await recover(client).outcome).toBe("nothing_due");
    expect(client.subscriptions.update).not.toHaveBeenCalled();
    expect(client.invoices.pay).not.toHaveBeenCalled();
  });

  test("reports no payment method when the customer left the portal without saving one", async () => {
    const client = fakeStripe({ defaultPaymentMethod: null, subscriptions: [cmuxSubscription()] });

    expect(await recover(client).outcome).toBe("no_payment_method");
    expect(client.invoices.pay).not.toHaveBeenCalled();
  });

  test("keeps the paid result when recording the subscription fails", async () => {
    const client = fakeStripe({ defaultPaymentMethod: NEW_CARD, subscriptions: [cmuxSubscription()] });
    const applySubscriptionUpdate = mock(async () => {
      throw new Error("database unavailable");
    });

    expect(await recover(client, applySubscriptionUpdate).outcome).toBe("recovered");
  });

  test("propagates Stripe errors that are not card declines", async () => {
    const client = fakeStripe({ defaultPaymentMethod: NEW_CARD, subscriptions: [cmuxSubscription()] });
    client.invoices.pay.mockImplementation(async () => {
      throw Object.assign(new Error("Stripe is unavailable"), { type: "StripeAPIError" });
    });

    await expect(recover(client).outcome).rejects.toThrow("Stripe is unavailable");
  });
});
