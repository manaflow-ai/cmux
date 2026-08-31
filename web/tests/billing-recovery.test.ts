import { describe, expect, mock, test } from "bun:test";

import {
  findPaidBillingPurchaseByEmail,
  provisionPaidBillingPurchase,
} from "../services/billing/recovery";

describe("billing purchase recovery", () => {
  test("finds a paid Pro subscription through a dotted Gmail alias", async () => {
    const customer = {
      id: "cus_fixture",
      deleted: false,
      email: "billingfixture@gmail.com",
      metadata: { app: "cmux" },
    };
    const subscription = {
      id: "sub_fixture",
      customer: customer.id,
      status: "active",
      metadata: { app: "cmux", plan: "pro", stackUserId: "anonymous" },
      cancel_at_period_end: false,
      items: { data: [] },
    };
    const result = await findPaidBillingPurchaseByEmail(
      " Billing.Fixture@Gmail.com ",
      {
        db: {
          select: () => {
            throw new Error("no local database in this test");
          },
        } as never,
        stripeClient: () => ({
          customers: {
            list: mock(async () => ({ data: [customer] })),
          },
          subscriptions: {
            list: mock(async () => ({ data: [subscription] })),
          },
          checkout: {
            sessions: {
              list: mock(async () => ({ data: [] })),
            },
          },
        }) as never,
      },
    );

    expect(result?.kind).toBe("pro");
    expect(result?.input.subscription).toMatchObject({ id: "sub_fixture" });
  });

  test("provisioning delegates founders and Pro records to shared paths", async () => {
    const founders = mock(async () => undefined);
    const pro = mock(async () => undefined);
    const input = {
      session: { id: "cs_fixture" },
      subscription: null,
      customer: null,
    } as never;

    await provisionPaidBillingPurchase(
      { kind: "founders_edition", input },
      { recordFounders: founders as never },
    );
    await provisionPaidBillingPurchase(
      { kind: "pro", input },
      { recordPro: pro as never },
    );
    expect(founders).toHaveBeenCalledTimes(1);
    expect(pro).toHaveBeenCalledTimes(1);
  });

  test("does not recover a canceled Pro session from the Stripe fallback", async () => {
    const customer = {
      id: "cus_canceled_fixture",
      deleted: false,
      email: "canceled@example.com",
      metadata: {},
    };
    const canceledSubscription = {
      id: "sub_canceled_fixture",
      customer: customer.id,
      status: "canceled",
      metadata: { app: "cmux", plan: "pro" },
      cancel_at_period_end: false,
      items: { data: [] },
    };
    const result = await findPaidBillingPurchaseByEmail(
      customer.email,
      {
        db: {
          select: () => {
            throw new Error("no local database in this test");
          },
        } as never,
        stripeClient: () => ({
          customers: {
            list: mock(async () => ({ data: [customer] })),
          },
          subscriptions: {
            list: mock(async () => ({ data: [canceledSubscription] })),
          },
          checkout: {
            sessions: {
              list: mock(async () => ({
                data: [
                  {
                    id: "cs_canceled_fixture",
                    customer: customer.id,
                    customer_details: { email: customer.email },
                    payment_status: "paid",
                    metadata: { app: "cmux", plan: "pro" },
                    subscription: canceledSubscription,
                  },
                ],
              })),
            },
          },
        }) as never,
      },
    );

    expect(result).toBeNull();
  });

  test("classifies a Founder session from expanded subscription metadata", async () => {
    const customer = {
      id: "cus_founder_subscription_fixture",
      deleted: false,
      email: "founder@example.com",
      metadata: {},
    };
    const subscription = {
      id: "sub_founder_subscription_fixture",
      customer: customer.id,
      status: "canceled",
      metadata: { founders_edition: "true" },
      cancel_at_period_end: false,
      items: { data: [] },
    };
    const result = await findPaidBillingPurchaseByEmail(
      customer.email,
      {
        db: {
          select: () => {
            throw new Error("no local database in this test");
          },
        } as never,
        stripeClient: () => ({
          customers: {
            list: mock(async () => ({ data: [customer] })),
          },
          subscriptions: {
            list: mock(async () => ({ data: [] })),
          },
          checkout: {
            sessions: {
              list: mock(async () => ({
                data: [
                  {
                    id: "cs_founder_subscription_fixture",
                    customer: customer.id,
                    customer_details: { email: customer.email },
                    payment_status: "paid",
                    metadata: {},
                    subscription,
                  },
                ],
              })),
            },
          },
        }) as never,
      },
    );

    expect(result?.kind).toBe("founders_edition");
  });

  test("does not recover a Founder subscription without settled payment evidence", async () => {
    const customer = {
      id: "cus_unpaid_founder_fixture",
      deleted: false,
      email: "unpaid-founder@example.com",
      metadata: {},
    };
    const subscription = {
      id: "sub_unpaid_founder_fixture",
      customer: customer.id,
      status: "incomplete",
      metadata: { founders_edition: "true" },
      cancel_at_period_end: false,
      items: { data: [] },
    };
    const sessionsList = mock(async (...args: unknown[]) => {
      const options = (args[0] ?? {}) as Record<string, unknown>;
      return {
        data: [
          {
            id: options?.customer
              ? "cs_unpaid_founder_customer_fixture"
              : "cs_unpaid_founder_recent_fixture",
            customer: customer.id,
            customer_details: { email: customer.email },
            payment_status: "unpaid",
            metadata: { founders_edition: "true" },
            subscription: subscription.id,
          },
        ],
      };
    });
    const result = await findPaidBillingPurchaseByEmail(
      customer.email,
      {
        db: {
          select: () => {
            throw new Error("no local database in this test");
          },
        } as never,
        stripeClient: () => ({
          customers: {
            list: mock(async () => ({ data: [customer] })),
          },
          subscriptions: {
            list: mock(async () => ({ data: [subscription] })),
          },
          checkout: {
            sessions: {
              list: sessionsList,
            },
          },
        }) as never,
      },
    );

    expect(result).toBeNull();
    expect(sessionsList).toHaveBeenCalledTimes(2);
  });
});
