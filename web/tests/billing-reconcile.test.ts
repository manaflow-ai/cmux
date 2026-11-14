import { describe, expect, test } from "bun:test";
import type Stripe from "stripe";

import { reconcileStripeSubscriptions } from "../services/billing/reconcile";

const claimAll = async () => true;

function subscription(
  id: string,
  status: Stripe.Subscription.Status = "active",
  overrides: Partial<Stripe.Subscription> = {},
): Stripe.Subscription {
  return {
    id,
    object: "subscription",
    status,
    cancel_at_period_end: false,
    items: {
      object: "list",
      data: [{
        id: "si_test",
        object: "subscription_item",
        current_period_end: 1_800_000_000,
        price: { id: "price_test" },
      }],
      has_more: false,
      url: "/v1/subscription_items",
    },
    metadata: { app: "cmux", stackUserId: "redacted", plan: "pro" },
    ...overrides,
  } as Stripe.Subscription;
}

describe("Stripe subscription reconciliation", () => {
  test("checks remote subscriptions concurrently and repairs only drift", async () => {
    let inFlight = 0;
    let peak = 0;
    let started = 0;
    let releaseBoth!: () => void;
    const bothStarted = new Promise<void>((resolve) => {
      releaseBoth = resolve;
    });
    const applied: string[] = [];
    const result = await reconcileStripeSubscriptions({}, {
      list: async () => [
        {
          id: "sub_equal",
          status: "active",
          cancelAtPeriodEnd: false,
          currentPeriodEnd: new Date(1_800_000_000_000),
          claimToken: null,
        },
        {
          id: "sub_drift",
          status: "active",
          cancelAtPeriodEnd: false,
          currentPeriodEnd: new Date(1_800_000_000_000),
          claimToken: null,
        },
      ],
      concurrency: 2,
      retrieve: async (id) => {
        inFlight += 1;
        peak = Math.max(peak, inFlight);
        started += 1;
        if (started === 2) releaseBoth();
        await bothStarted;
        inFlight -= 1;
        return id === "sub_drift"
          ? subscription(id, "canceled")
          : subscription(id);
      },
      apply: async (remote) => {
        applied.push(remote.id);
        return { scope: "user", stackUserId: "ignored", isActive: false };
      },
      claim: claimAll,
    });

    expect(peak).toBe(2);
    expect(applied).toEqual(["sub_drift"]);
    expect(result).toEqual({
      checked: 2,
      drifted: 1,
      repaired: 1,
      failed: 0,
      deferred: 0,
      truncated: false,
    });
  });

  test("dry-run reports drift without mutation", async () => {
    let applied = false;
    let marked = false;
    const result = await reconcileStripeSubscriptions({ dryRun: true }, {
      list: async () => [{
        id: "sub_drift",
        status: "active",
        cancelAtPeriodEnd: false,
        currentPeriodEnd: null,
        claimToken: null,
      }],
      retrieve: async () => subscription("sub_drift", "canceled"),
      apply: async () => {
        applied = true;
      },
      claim: async () => {
        marked = true;
        return true;
      },
    });
    expect(applied).toBe(false);
    expect(marked).toBe(false);
    expect(result.drifted).toBe(1);
    expect(result.repaired).toBe(0);
  });

  test("isolates failures and never includes identifiers in error context", async () => {
    const contexts: Record<string, unknown>[] = [];
    const result = await reconcileStripeSubscriptions({}, {
      list: async () => [{
        id: "sub_secret",
        status: "active",
        cancelAtPeriodEnd: false,
        currentPeriodEnd: null,
        claimToken: null,
      }],
      retrieve: async () => {
        throw new Error("provider unavailable");
      },
      captureError: (_error, context) => contexts.push(context),
      claim: claimAll,
    });
    expect(result.failed).toBe(1);
    expect(contexts).toEqual([{
      operation: "stripe_subscription_reconcile",
      recoverable: true,
    }]);
    expect(JSON.stringify(contexts)).not.toContain("sub_secret");
  });

  test("bounds each run and reports truncation", async () => {
    const result = await reconcileStripeSubscriptions({ limit: 1 }, {
      list: async () => [
        {
          id: "sub_one",
          status: "active",
          cancelAtPeriodEnd: false,
          currentPeriodEnd: new Date(1_800_000_000_000),
          claimToken: null,
        },
        {
          id: "sub_two",
          status: "active",
          cancelAtPeriodEnd: false,
          currentPeriodEnd: new Date(1_800_000_000_000),
          claimToken: null,
        },
      ],
      retrieve: async (id) => subscription(id),
      claim: claimAll,
    });
    expect(result.checked).toBe(1);
    expect(result.truncated).toBe(true);
  });

  test("advances every checked row so a later batch can rotate in", async () => {
    const remaining = ["sub_one", "sub_two"];
    const checked: string[] = [];
    const dependencies = {
      list: async (limit: number) => remaining.slice(0, limit).map(snapshot),
      retrieve: async (id: string) => subscription(id),
      claim: async (row: { readonly id: string }) => {
        checked.push(row.id);
        remaining.splice(remaining.indexOf(row.id), 1);
        return true;
      },
    };

    expect((await reconcileStripeSubscriptions({ limit: 1 }, dependencies)).truncated)
      .toBe(true);
    expect((await reconcileStripeSubscriptions({ limit: 1 }, dependencies)).truncated)
      .toBe(false);
    expect(checked).toEqual(["sub_one", "sub_two"]);
  });

  test("overlapping cron and operator runs split the rows instead of checking one twice", async () => {
    const claimedBy = new Map<string, number>();
    const retrieved: string[] = [];
    const run = (runId: number) => reconcileStripeSubscriptions({}, {
      list: async () => ["sub_a", "sub_b", "sub_c"].map(snapshot),
      concurrency: 1,
      claim: async (row: { readonly id: string }) => {
        await Promise.resolve();
        if (claimedBy.has(row.id)) return false;
        claimedBy.set(row.id, runId);
        return true;
      },
      retrieve: async (id: string) => {
        retrieved.push(id);
        return subscription(id);
      },
    });
    const [first, second] = await Promise.all([run(1), run(2)]);
    expect([...retrieved].sort()).toEqual(["sub_a", "sub_b", "sub_c"]);
    expect(first.checked + second.checked).toBe(3);
  });

  test("claims each row as it starts and stops starting rows once its time budget is spent", async () => {
    let clock = 0;
    const claimed: string[] = [];
    const result = await reconcileStripeSubscriptions({ budgetMs: 1_000 }, {
      list: async () => ["sub_a", "sub_b", "sub_c"].map(snapshot),
      concurrency: 1,
      now: () => clock,
      claim: async (row: { readonly id: string }) => {
        claimed.push(row.id);
        return true;
      },
      retrieve: async (id: string) => {
        clock += 600;
        return subscription(id);
      },
    });
    expect(claimed).toEqual(["sub_a", "sub_b"]);
    expect(result).toMatchObject({ checked: 2, deferred: 1, truncated: true, failed: 0 });
  });

  test("skips a row another run claimed first", async () => {
    const retrieved: string[] = [];
    const result = await reconcileStripeSubscriptions({}, {
      list: async () => [snapshot("sub_mine"), snapshot("sub_theirs")],
      claim: async (row: { readonly id: string }) => row.id === "sub_mine",
      retrieve: async (id: string) => {
        retrieved.push(id);
        return subscription(id);
      },
    });
    expect(retrieved).toEqual(["sub_mine"]);
    expect(result.checked).toBe(1);
  });
});

function snapshot(id: string) {
  return {
    id,
    status: "active",
    cancelAtPeriodEnd: false,
    currentPeriodEnd: new Date(1_800_000_000_000),
    claimToken: null,
  };
}
