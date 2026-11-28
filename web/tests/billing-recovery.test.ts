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

  test("treats googlemail.com as the same mailbox as gmail.com", async () => {
    const customer = {
      id: "cus_googlemail_fixture",
      deleted: false,
      email: "billingfixture@googlemail.com",
      metadata: { app: "cmux" },
    };
    const subscription = {
      id: "sub_googlemail_fixture",
      customer: customer.id,
      status: "active",
      metadata: { app: "cmux", plan: "pro" },
      cancel_at_period_end: false,
      items: { data: [] },
    };
    const result = await findPaidBillingPurchaseByEmail(
      "billing.fixture@gmail.com",
      {
        db: {
          select: () => {
            throw new Error("no local database in this test");
          },
        } as never,
        stripeClient: () => ({
          customers: {
            list: mock(async (...args: unknown[]) => {
              const options = (args[0] ?? {}) as Record<string, unknown>;
              return {
                data:
                  options.email === "billingfixture@googlemail.com"
                    ? [customer]
                    : [],
              };
            }),
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
    expect(result?.input.customer).toMatchObject({
      email: "billingfixture@googlemail.com",
    });
  });

  test("fails closed after a bounded Stripe subscription history scan", async () => {
    const customer = {
      id: "cus_history_limit_fixture",
      deleted: false,
      email: "history-limit@example.com",
      metadata: {},
    };
    let subscriptionCalls = 0;
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
            list: mock(async () => {
              subscriptionCalls += 1;
              return {
                data: [
                  {
                    id: `sub_history_${subscriptionCalls}`,
                    customer: customer.id,
                    status: "canceled",
                    metadata: {},
                  },
                ],
                has_more: subscriptionCalls < 25,
              };
            }),
          },
          checkout: {
            sessions: {
              list: mock(async () => ({ data: [] })),
            },
          },
        }) as never,
      },
    );

    expect(result).toBeNull();
    expect(subscriptionCalls).toBeLessThan(25);
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

  test("does not recover foreign billing history with Founder metadata", async () => {
    const customer = {
      id: "cus_foreign_founder_fixture",
      deleted: false,
      email: "foreign-founder@example.com",
      metadata: {},
    };
    const subscription = {
      id: "sub_foreign_founder_fixture",
      customer: customer.id,
      status: "active",
      metadata: { app: "other", founders_edition: "true" },
      cancel_at_period_end: false,
      items: { data: [] },
    };
    const session = {
      id: "cs_foreign_founder_fixture",
      customer: customer.id,
      customer_details: { email: customer.email },
      payment_status: "paid",
      metadata: { app: "other", founders_edition: "true" },
      subscription: subscription.id,
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
            list: mock(async () => ({ data: [subscription] })),
          },
          checkout: {
            sessions: {
              list: mock(async () => ({ data: [session] })),
            },
          },
        }) as never,
      },
    );

    expect(result).toBeNull();
  });

  test("does not recover a Pro purchase as Founder when metadata conflicts", async () => {
    const customer = {
      id: "cus_conflicting_founder_pro_fixture",
      deleted: false,
      email: "conflicting-founder-pro@example.com",
      metadata: {},
    };
    const subscription = {
      id: "sub_conflicting_founder_pro_fixture",
      customer: customer.id,
      status: "active",
      metadata: {
        app: "cmux",
        plan: "pro",
        founders_edition: "true",
      },
      cancel_at_period_end: false,
      items: { data: [] },
    };
    const session = {
      id: "cs_conflicting_founder_pro_fixture",
      customer: customer.id,
      customer_details: { email: customer.email },
      payment_status: "paid",
      metadata: {
        app: "cmux",
        plan: "pro",
        founders_edition: "true",
      },
      subscription: subscription.id,
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
            list: mock(async () => ({ data: [subscription] })),
          },
          checkout: {
            sessions: {
              list: mock(async () => ({ data: [session] })),
            },
          },
        }) as never,
      },
    );

    expect(result).toBeNull();
  });

  test("paginates the bounded payment-link fallback", async () => {
    const subscription = {
      id: "sub_recent_payment_link_fixture",
      customer: "cus_recent_payment_link_fixture",
      status: "active",
      metadata: { founders_edition: "true" },
      cancel_at_period_end: false,
      items: { data: [] },
    };
    const session = {
      id: "cs_older_payment_link_fixture",
      customer: null,
      customer_details: { email: "payment-link@example.com" },
      payment_status: "paid",
      metadata: { founders_edition: "true" },
      subscription,
    };
    let sessionCalls = 0;
    const result = await findPaidBillingPurchaseByEmail(
      "payment-link@example.com",
      {
        db: {
          select: () => {
            throw new Error("no local database in this test");
          },
        } as never,
        stripeClient: () => ({
          customers: {
            list: mock(async () => ({ data: [] })),
          },
          subscriptions: {
            list: mock(async () => ({ data: [] })),
          },
          checkout: {
            sessions: {
              list: mock(async (...args: unknown[]) => {
                sessionCalls += 1;
                const options = (args[0] ?? {}) as Record<string, unknown>;
                if (options.starting_after) {
                  return { data: [session], has_more: false };
                }
                return {
                  data: [
                    {
                      id: "cs_newer_unrelated_fixture",
                      customer: null,
                      customer_details: { email: "other@example.com" },
                      payment_status: "paid",
                      metadata: { app: "other" },
                      subscription: null,
                    },
                  ],
                  has_more: true,
                };
              }),
            },
          },
        }) as never,
      },
    );

    expect(result?.kind).toBe("founders_edition");
    expect(sessionCalls).toBe(2);
  });
});
