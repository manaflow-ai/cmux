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

  test("apply remaps a synthetic dotted alias before provisioning", async () => {
    const stack = stackApp();
    const provider = stripeClient();
    const order: string[] = [];
    const fakeDb = {
      select: () => ({
        from: (table: unknown) => ({
          where: () => ({
            limit: async () =>
              table === stripeCustomers
                ? [{ stackUserId: stack.user.id, stackTeamId: null }]
                : [{ id: "sub_fixture", stackUserId: stack.user.id, stackTeamId: null }],
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
                : [{ id: "sub_fixture", stackUserId: stack.user.id, stackTeamId: null }],
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
