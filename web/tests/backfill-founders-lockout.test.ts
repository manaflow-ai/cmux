import { describe, expect, mock, test } from "bun:test";

import {
  runFoundersLockoutBackfill,
  type FoundersBackfillDependencies,
} from "../scripts/backfill-founders-lockout";
import { stripeCustomers } from "../db/schema";

function stackApp() {
  const user = {
    id: "target-user",
    primaryEmail: "billingfixture@gmail.com",
    primaryEmailVerified: false,
    clientReadOnlyMetadata: {},
    update: mock(async () => undefined),
  };
  return {
    user,
    value: {
      listUsers: mock(async () => [
        {
          id: user.id,
          primaryEmail: user.primaryEmail,
          primaryEmailVerified: user.primaryEmailVerified,
        },
      ]),
      getUser: mock(async () => user),
    } as never,
  };
}

function stripeClient() {
  const customer = {
    id: "cus_fixture",
    deleted: false,
    email: "billing.fixture@gmail.com",
    name: "Fixture Buyer",
  };
  const subscription = {
    id: "sub_fixture",
    customer: customer.id,
    status: "active",
    metadata: { founders_edition: "true" },
    cancel_at_period_end: false,
    items: { data: [] },
  };
  return {
    customer,
    subscription,
    value: {
      customers: { list: mock(async () => ({ data: [customer] })) },
      subscriptions: {
        list: mock(async () => ({ data: [subscription] })),
      },
      checkout: {
        sessions: {
          list: mock(async () => ({ data: [] })),
        },
      },
    } as never,
  };
}

describe("Founder's lockout backfill", () => {
  test("dry-run reports a plan without invoking mutations", async () => {
    const stack = stackApp();
    stack.user.primaryEmailVerified = true;
    const provider = stripeClient();
    const provision = mock(async () => undefined);
    const remap = mock(async () => undefined);
    const log = mock(() => undefined);
    const dependencies: FoundersBackfillDependencies = {
      stackApp: stack.value,
      stripeClient: provider.value,
      provision: provision as never,
      remap: remap as never,
      log,
    };

    const result = await runFoundersLockoutBackfill(
      {
        dryRun: true,
        cases: [{ email: "billingfixture@gmail.com", purchaseEmail: "billing.fixture@gmail.com" }],
      },
      dependencies,
    );

    expect(result.mode).toBe("dry-run");
    expect(result.customers[0]).toMatchObject({
      status: "skipped",
      reason: "dry_run_would_provision",
      targetUserId: "target-user",
    });
    expect(provision).not.toHaveBeenCalled();
    expect(remap).not.toHaveBeenCalled();
    const logged = (log as unknown as { mock: { calls: unknown[][] } }).mock.calls;
    expect(JSON.stringify(logged)).not.toContain("customerId");
    expect(JSON.stringify(logged)).not.toContain("subscriptionIds");
  });

  test("apply delegates provisioning to the shared recorder", async () => {
    const stack = stackApp();
    stack.user.primaryEmailVerified = true;
    const provider = stripeClient();
    const provision = mock(async () => undefined);
    const dependencies: FoundersBackfillDependencies = {
      stackApp: stack.value,
      stripeClient: provider.value,
      provision: provision as never,
      billingDependencies: { db: {} as never },
    };

    const result = await runFoundersLockoutBackfill(
      {
        dryRun: false,
        cases: [{ email: "billingfixture@gmail.com", purchaseEmail: "billing.fixture@gmail.com" }],
      },
      dependencies,
    );

    expect(result.customers[0]).toMatchObject({
      status: "did",
      reason: "provisioned",
    });
    expect(provision).toHaveBeenCalledTimes(1);
    const calls = (provision as unknown as { mock: { calls: unknown[][] } }).mock.calls;
    expect(calls[0]?.[0]).toMatchObject({
      enrollmentEmail: "billingfixture@gmail.com",
    });
  });

  test("does not create a replacement account when the target mailbox is absent", async () => {
    const provider = stripeClient();
    const createUser = mock(async () => {
      throw new Error("backfill must not create accounts");
    });
    const stack = {
      listUsers: mock(async () => []),
      getUser: mock(async () => null),
      createUser,
    } as never;

    const result = await runFoundersLockoutBackfill(
      {
        dryRun: false,
        cases: [{ email: "billingfixture@gmail.com" }],
      },
      { stackApp: stack, stripeClient: provider.value },
    );

    expect(result.customers[0]).toMatchObject({
      status: "skipped",
      reason: "target_stack_user_not_found",
    });
    expect(createUser).not.toHaveBeenCalled();
  });

  test("rejects a payment-intent customer whose email differs from the case", async () => {
    const stack = stackApp();
    const paymentCustomer = {
      id: "cus_other",
      deleted: false,
      email: "someone-else@example.com",
      name: "Other Buyer",
    };
    const provider = {
      customers: {
        list: mock(async () => ({ data: [paymentCustomer], has_more: false })),
      },
      paymentIntents: {
        retrieve: mock(async () => ({
          id: "pi_other",
          customer: paymentCustomer.id,
        })),
      },
      subscriptions: {
        list: mock(async () => ({
          data: [{
            id: "sub_other",
            customer: paymentCustomer.id,
            status: "active",
            metadata: { founders_edition: "true" },
            cancel_at_period_end: false,
            items: { data: [] },
          }],
        })),
      },
      checkout: {
        sessions: {
          list: mock(async () => ({ data: [] })),
        },
      },
    };

    const result = await runFoundersLockoutBackfill(
      {
        dryRun: true,
        cases: [{
          email: "billingfixture@gmail.com",
          paymentIntent: "pi_other",
        }],
      },
      {
        stackApp: stack.value,
        stripeClient: provider as never,
      },
    );

    expect(result.customers[0]).toMatchObject({
      status: "skipped",
      reason: "no_paid_cmux_purchase_found",
    });
    expect(provider.subscriptions.list).not.toHaveBeenCalled();
  });

  test("apply remaps a synthetic dotted alias before provisioning", async () => {
    const stack = stackApp();
    stack.user.primaryEmailVerified = true;
    const provider = stripeClient();
    const order: string[] = [];
    const fakeDb = {
      select: () => ({
        from: (table: unknown) => ({
          where: () => ({
            limit: async () =>
              table === stripeCustomers
                ? [{ stackUserId: stack.user.id, stackTeamId: null }]
                : [{
                    id: "sub_fixture",
                    stackUserId: stack.user.id,
                    stackTeamId: null,
                    plan: "pro",
                    scope: "user",
                  }],
          }),
        }),
      }),
    };

    const result = await runFoundersLockoutBackfill(
      {
        dryRun: false,
        cases: [
          {
            email: "billingfixture@gmail.com",
            purchaseEmail: "billing.fixture@gmail.com",
            realEmail: "billingfixture@gmail.com",
          },
        ],
      },
      {
        stackApp: stack.value,
        stripeClient: provider.value,
        billingDependencies: { db: fakeDb as never },
        remap: (async (...args: unknown[]) => {
          const input = args[0] as {
            customerId: string;
            subscriptionIds: readonly string[];
            targetStackUserId: string;
            email?: string | null;
          };
          order.push("remap");
          expect(input).toEqual({
            customerId: "cus_fixture",
            subscriptionIds: ["sub_fixture"],
            targetStackUserId: "target-user",
            email: "billing.fixture@gmail.com",
          });
        }) as never,
        provision: (async (...args: unknown[]) => {
          const input = args[0] as { enrollmentEmail?: string | null };
          order.push("provision");
          expect(input.enrollmentEmail).toBe("billingfixture@gmail.com");
        }) as never,
      },
    );

    expect(result.customers[0]).toMatchObject({
      status: "did",
      reason: "provisioned",
    });
    expect(order).toEqual(["remap", "provision"]);
  });

  test("does not remap a dotted alias to an unverified Stack account", async () => {
    const stack = stackApp();
    const provider = stripeClient();
    const remap = mock(async () => undefined);
    const provision = mock(async () => undefined);

    const result = await runFoundersLockoutBackfill(
      {
        dryRun: false,
        cases: [
          {
            email: "billingfixture@gmail.com",
            purchaseEmail: "billing.fixture@gmail.com",
            realEmail: "billingfixture@gmail.com",
          },
        ],
      },
      {
        stackApp: stack.value,
        stripeClient: provider.value,
        billingDependencies: { db: {} as never },
        remap: remap as never,
        provision: provision as never,
      },
    );

    expect(result.customers[0]).toMatchObject({
      status: "skipped",
      reason: "target_stack_user_not_verified",
    });
    expect(remap).not.toHaveBeenCalled();
    expect(provision).not.toHaveBeenCalled();
  });

  test("walks all Stripe subscription and session pages", async () => {
    const stack = stackApp();
    stack.user.primaryEmailVerified = true;
    const customer = {
      id: "cus_paginated",
      deleted: false,
      email: "billingfixture@gmail.com",
      name: "Fixture Buyer",
    };
    const unrelatedSubscription = {
      id: "sub_unrelated",
      customer: customer.id,
      status: "canceled",
      metadata: { app: "other", plan: "pro" },
      cancel_at_period_end: false,
      items: { data: [] },
    };
    const founderSubscription = {
      id: "sub_founder_page_two",
      customer: customer.id,
      status: "active",
      metadata: { founders_edition: "true" },
      cancel_at_period_end: false,
      items: { data: [] },
    };
    const founderSession = {
      id: "cs_founder_page_two",
      customer: customer.id,
      customer_details: { email: customer.email },
      payment_status: "paid",
      metadata: { founders_edition: "true" },
      subscription: founderSubscription.id,
    };
    const unrelatedSession = {
      id: "cs_unrelated_page_one",
      customer: customer.id,
      customer_details: { email: customer.email },
      payment_status: "paid",
      metadata: { app: "other" },
      subscription: unrelatedSubscription.id,
    };
    const subscriptionList = mock(async (...args: unknown[]) => {
      const options = args[0] as Record<string, unknown> | undefined;
      return options?.starting_after
        ? { data: [founderSubscription], has_more: false }
        : { data: [unrelatedSubscription], has_more: true };
    });
    const sessionList = mock(async (...args: unknown[]) => {
      const options = args[0] as Record<string, unknown> | undefined;
      return options?.starting_after
        ? { data: [founderSession], has_more: false }
        : { data: [unrelatedSession], has_more: true };
    });

    const result = await runFoundersLockoutBackfill(
      {
        dryRun: true,
        cases: [{ email: customer.email }],
      },
      {
        stackApp: stack.value,
        stripeClient: {
          customers: {
            list: async () => ({ data: [customer], has_more: false }),
          },
          subscriptions: { list: subscriptionList },
          checkout: { sessions: { list: sessionList } },
        } as never,
      },
    );

    expect(result.customers[0]).toMatchObject({
      status: "skipped",
      reason: "dry_run_would_provision",
    });
    expect(subscriptionList).toHaveBeenCalledWith(
      expect.objectContaining({ starting_after: "sub_unrelated" }),
    );
    expect(sessionList).toHaveBeenCalledWith(
      expect.objectContaining({ starting_after: "cs_unrelated_page_one" }),
    );
  });

  test("dry-run skips an unverified target instead of promising a mutation", async () => {
    const stack = stackApp();
    const provider = stripeClient();
    const provision = mock(async () => undefined);

    const result = await runFoundersLockoutBackfill(
      {
        dryRun: true,
        cases: [{ email: "billingfixture@gmail.com" }],
      },
      {
        stackApp: stack.value,
        stripeClient: provider.value,
        provision: provision as never,
      },
    );

    expect(result.customers[0]).toMatchObject({
      status: "skipped",
      reason: "target_stack_user_not_verified",
      targetUserId: "target-user",
    });
    expect(provision).not.toHaveBeenCalled();
  });

  test("skips an already-complete repeat run after the durable rows exist", async () => {
    const stack = stackApp();
    stack.user.primaryEmailVerified = true;
    stack.user.clientReadOnlyMetadata = { cmuxPlan: "pro" };
    const provider = stripeClient();
    const provision = mock(async () => undefined);
    const fakeDb = {
      select: () => ({
        from: (table: unknown) => ({
          where: () => ({
            limit: async () =>
              table === stripeCustomers
                ? [{ stackUserId: stack.user.id, stackTeamId: null }]
                : [{
                    id: "sub_fixture",
                    stackUserId: stack.user.id,
                    stackTeamId: null,
                    plan: "pro",
                    scope: "user",
                  }],
          }),
        }),
      }),
    };
    const result = await runFoundersLockoutBackfill(
      {
        dryRun: false,
        cases: [{ email: "billingfixture@gmail.com", purchaseEmail: "billing.fixture@gmail.com" }],
      },
      {
        stackApp: stack.value,
        stripeClient: provider.value,
        billingDependencies: { db: fakeDb as never },
        provision: provision as never,
      },
    );

    expect(result.customers[0]).toMatchObject({
      status: "skipped",
      reason: "already_provisioned",
    });
    expect(provision).not.toHaveBeenCalled();
  });
});
