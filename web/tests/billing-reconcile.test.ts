import { describe, expect, test } from "bun:test";
import type Stripe from "stripe";

import { reconcileStripeSubscriptions } from "../services/billing/reconcile";

const withoutLease = async <T>(task: () => Promise<T>): Promise<T> => task();

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

function teamItems(
  id: string,
  quantity: number,
): Stripe.Subscription["items"] {
  return {
    object: "list",
    data: [{
      id,
      object: "subscription_item",
      current_period_end: 1_800_000_000,
      quantity,
      price: { id: "price_team" },
    }],
    has_more: false,
    url: "/v1/subscription_items",
  } as Stripe.Subscription["items"];
}

describe("Stripe subscription reconciliation", () => {
  test("reports team seat drift with current member, Stripe, and stored counts", async () => {
    let stripeUpdateCalls = 0;
    let seatWriteCalls = 0;
    const analytics: Array<Record<string, unknown>> = [];
    const updateSubscriptionQuantity = async () => {
      stripeUpdateCalls += 1;
    };
    const updateSeats = async () => {
      seatWriteCalls += 1;
    };
    const dependencies = {
      withLease: withoutLease,
      list: async () => [{
        id: "sub_team_growth",
        status: "active",
        cancelAtPeriodEnd: false,
        currentPeriodEnd: new Date(1_800_000_000_000),
        scope: "team",
        stackTeamId: "team_growth",
        seats: 1,
      }],
      retrieve: async () => subscription("sub_team_growth", "active", {
        metadata: { app: "cmux", plan: "team", stackTeamId: "team_growth" },
        items: teamItems("si_team_growth", 1),
      }),
      getTeam: async () => ({
        listUsers: async () => [{ id: "member-1" }, { id: "member-2" }, { id: "member-3" }],
      }),
      updateSubscriptionQuantity,
      updateSeats,
      captureTeamSeatDrift: async (input: Record<string, unknown>) => {
        analytics.push(input);
      },
      markChecked: async () => {},
    };
    const result = await reconcileStripeSubscriptions({}, dependencies);

    expect(stripeUpdateCalls).toBe(0);
    expect(seatWriteCalls).toBe(0);
    expect(analytics).toEqual([{
      subscriptionId: "sub_team_growth",
      teamId: "team_growth",
      memberCount: 3,
      stripeQuantity: 1,
      storedSeats: 1,
    }]);
    expect(result).toMatchObject({ checked: 1, drifted: 1, repaired: 0, failed: 0 });
  });

  test("reports an empty roster as one desired seat without mutating billing", async () => {
    let stripeUpdateCalls = 0;
    let seatWriteCalls = 0;
    const analytics: Array<Record<string, unknown>> = [];
    const updateSubscriptionQuantity = async () => {
      stripeUpdateCalls += 1;
    };
    const updateSeats = async () => {
      seatWriteCalls += 1;
    };
    const dependencies = {
      withLease: withoutLease,
      list: async () => [{
        id: "sub_team_shrink",
        status: "active",
        cancelAtPeriodEnd: false,
        currentPeriodEnd: new Date(1_800_000_000_000),
        scope: "team",
        stackTeamId: "team_shrink",
        seats: 5,
      }],
      retrieve: async () => subscription("sub_team_shrink", "active", {
        metadata: { app: "cmux", plan: "team", stackTeamId: "team_shrink" },
        items: teamItems("si_team_shrink", 5),
      }),
      getTeam: async () => ({ listUsers: async () => [] }),
      updateSubscriptionQuantity,
      updateSeats,
      captureTeamSeatDrift: async (input: Record<string, unknown>) => {
        analytics.push(input);
      },
      markChecked: async () => {},
    };
    const result = await reconcileStripeSubscriptions({}, dependencies);

    expect(stripeUpdateCalls).toBe(0);
    expect(seatWriteCalls).toBe(0);
    expect(analytics).toEqual([{
      subscriptionId: "sub_team_shrink",
      teamId: "team_shrink",
      memberCount: 0,
      stripeQuantity: 5,
      storedSeats: 5,
    }]);
    expect(result).toMatchObject({ checked: 1, drifted: 1, repaired: 0, failed: 0 });
  });

  test("emits nothing when team quantities already match", async () => {
    let stripeUpdateCalls = 0;
    let seatWriteCalls = 0;
    let analyticsCalls = 0;
    const updateSubscriptionQuantity = async () => {
      stripeUpdateCalls += 1;
    };
    const updateSeats = async () => {
      seatWriteCalls += 1;
    };
    const dependencies = {
      withLease: withoutLease,
      list: async () => [{
        id: "sub_team_equal",
        status: "active",
        cancelAtPeriodEnd: false,
        currentPeriodEnd: new Date(1_800_000_000_000),
        scope: "team",
        stackTeamId: "team_equal",
        seats: 2,
      }],
      retrieve: async () => subscription("sub_team_equal", "active", {
        metadata: { app: "cmux", plan: "team", stackTeamId: "team_equal" },
        items: teamItems("si_team_equal", 2),
      }),
      getTeam: async () => ({ listUsers: async () => [{ id: "member-1" }, { id: "member-2" }] }),
      updateSubscriptionQuantity,
      updateSeats,
      captureTeamSeatDrift: async () => {
        analyticsCalls += 1;
      },
      markChecked: async () => {},
    };
    const result = await reconcileStripeSubscriptions({}, dependencies);

    expect(stripeUpdateCalls).toBe(0);
    expect(seatWriteCalls).toBe(0);
    expect(analyticsCalls).toBe(0);
    expect(result).toMatchObject({ checked: 1, drifted: 0, repaired: 0, failed: 0 });
  });

  test("checks every team in the bounded batch without a reservation quota", async () => {
    const rows = Array.from({ length: 51 }, (_, index) => ({
      id: `sub_team_${index}`,
      status: "active",
      cancelAtPeriodEnd: false,
      currentPeriodEnd: new Date(1_800_000_000_000),
      scope: "team",
      stackTeamId: `team_${index}`,
      seats: 1,
    }));
    const visitedTeams: string[] = [];
    const analytics: Array<Record<string, unknown>> = [];
    const dependencies = {
      withLease: withoutLease,
      list: async () => rows,
      retrieve: async (id: string) => subscription(id, "active", {
        metadata: { app: "cmux", plan: "team", stackTeamId: id.replace("sub_", "") },
        items: teamItems(`si_${id}`, 1),
      }),
      getTeam: async (teamId: string) => {
        visitedTeams.push(teamId);
        return { listUsers: async () => [{ id: "member-1" }, { id: "member-2" }] };
      },
      captureTeamSeatDrift: async (input: Record<string, unknown>) => {
        analytics.push(input);
      },
      markChecked: async () => {},
    };
    await reconcileStripeSubscriptions({}, dependencies);

    expect(visitedTeams).toHaveLength(51);
    expect(new Set(visitedTeams)).toEqual(
      new Set(rows.map((row) => row.stackTeamId)),
    );
    expect(analytics).toHaveLength(51);
  });

  test("isolates a team seat drift failure and continues with other teams", async () => {
    let stripeUpdateCalls = 0;
    let seatWriteCalls = 0;
    const analytics: Array<Record<string, unknown>> = [];
    const contexts: Record<string, unknown>[] = [];
    const updateSubscriptionQuantity = async () => {
      stripeUpdateCalls += 1;
    };
    const updateSeats = async () => {
      seatWriteCalls += 1;
    };
    const dependencies = {
      withLease: withoutLease,
      concurrency: 1,
      list: async () => [
        {
          id: "sub_team_failed",
          status: "active",
          cancelAtPeriodEnd: false,
          currentPeriodEnd: new Date(1_800_000_000_000),
          scope: "team",
          stackTeamId: "team_failed",
          seats: 1,
        },
        {
          id: "sub_team_ok",
          status: "active",
          cancelAtPeriodEnd: false,
          currentPeriodEnd: new Date(1_800_000_000_000),
          scope: "team",
          stackTeamId: "team_ok",
          seats: 1,
        },
      ],
      retrieve: async (id: string) => subscription(id, "active", {
        metadata: {
          app: "cmux",
          plan: "team",
          stackTeamId: id === "sub_team_failed" ? "team_failed" : "team_ok",
        },
        items: teamItems(`si_${id}`, 1),
      }),
      getTeam: async (teamId: string) => {
        if (teamId === "team_failed") throw new Error("Stack unavailable");
        return { listUsers: async () => [{ id: "member-1" }, { id: "member-2" }] };
      },
      updateSubscriptionQuantity,
      updateSeats,
      captureTeamSeatDrift: async (input: Record<string, unknown>) => {
        analytics.push(input);
      },
      captureError: (_error: unknown, context: Record<string, string | number | boolean>) => {
        contexts.push(context);
      },
      markChecked: async () => {},
    };
    const result = await reconcileStripeSubscriptions({}, dependencies);

    expect(stripeUpdateCalls).toBe(0);
    expect(seatWriteCalls).toBe(0);
    expect(analytics).toEqual([{
      subscriptionId: "sub_team_ok",
      teamId: "team_ok",
      memberCount: 2,
      stripeQuantity: 1,
      storedSeats: 1,
    }]);
    expect(result).toMatchObject({ checked: 2, drifted: 1, repaired: 0, failed: 1 });
    expect(contexts).toEqual([{
      operation: "stripe_subscription_reconcile",
      recoverable: true,
    }]);
  });

  test("fails closed when remote team identity disagrees with the local row", async () => {
    let rosterReads = 0;
    let analyticsCalls = 0;
    const errors: unknown[] = [];
    const dependencies = {
      withLease: withoutLease,
      list: async () => [{
        id: "sub_team_identity",
        status: "active",
        cancelAtPeriodEnd: false,
        currentPeriodEnd: new Date(1_800_000_000_000),
        scope: "team",
        stackTeamId: "team_local",
        seats: 1,
      }],
      retrieve: async () => subscription("sub_team_identity", "active", {
        metadata: { app: "cmux", plan: "team", stackTeamId: "team_remote" },
        items: teamItems("si_team_identity", 1),
      }),
      getTeam: async () => {
        rosterReads += 1;
        return { listUsers: async () => [{ id: "member-1" }, { id: "member-2" }] };
      },
      captureTeamSeatDrift: async () => {
        analyticsCalls += 1;
      },
      captureError: (error: unknown) => {
        errors.push(error);
      },
      markChecked: async () => {},
    };
    const result = await reconcileStripeSubscriptions({}, dependencies);

    expect(result).toMatchObject({ checked: 1, drifted: 0, repaired: 0, failed: 1 });
    expect(errors).toHaveLength(1);
    expect(String(errors[0])).toContain("remote=team_remote local=team_local");
    expect(rosterReads).toBe(0);
    expect(analyticsCalls).toBe(0);
  });

  test("records a recoverable failure when the roster misses the 15-second deadline", async () => {
    const errors: unknown[] = [];
    const result = await reconcileStripeSubscriptions({}, {
      withLease: withoutLease,
      list: async () => [{
        id: "sub_team_timeout",
        status: "active",
        cancelAtPeriodEnd: false,
        currentPeriodEnd: new Date(1_800_000_000_000),
        scope: "team",
        stackTeamId: "team_timeout",
        seats: 1,
      }],
      retrieve: async () => subscription("sub_team_timeout", "active", {
        metadata: { app: "cmux", plan: "team", stackTeamId: "team_timeout" },
        items: teamItems("si_team_timeout", 1),
      }),
      getTeam: async () => ({
        listUsers: () => new Promise<readonly unknown[]>(() => {}),
      }),
      captureError: (error: unknown) => {
        errors.push(error);
      },
      markChecked: async () => {},
    });

    expect(result).toMatchObject({ checked: 1, drifted: 0, repaired: 0, failed: 1 });
    expect(errors).toHaveLength(1);
    expect(String(errors[0])).toContain("Stack team interaction exceeded the per-team deadline");
  }, 20_000);

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
      withLease: withoutLease,
      list: async () => [
        {
          id: "sub_equal",
          status: "active",
          cancelAtPeriodEnd: false,
          currentPeriodEnd: new Date(1_800_000_000_000),
        },
        {
          id: "sub_drift",
          status: "active",
          cancelAtPeriodEnd: false,
          currentPeriodEnd: new Date(1_800_000_000_000),
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
      markChecked: async () => {},
    });

    expect(peak).toBe(2);
    expect(applied).toEqual(["sub_drift"]);
    expect(result).toEqual({
      checked: 2,
      drifted: 1,
      repaired: 1,
      failed: 0,
      truncated: false,
    });
  });

  test("dry-run reports drift without mutation", async () => {
    let applied = false;
    let marked = false;
    const result = await reconcileStripeSubscriptions({ dryRun: true }, {
      withLease: withoutLease,
      list: async () => [{
        id: "sub_drift",
        status: "active",
        cancelAtPeriodEnd: false,
        currentPeriodEnd: null,
      }],
      retrieve: async () => subscription("sub_drift", "canceled"),
      apply: async () => {
        applied = true;
      },
      markChecked: async () => {
        marked = true;
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
      withLease: withoutLease,
      list: async () => [{
        id: "sub_secret",
        status: "active",
        cancelAtPeriodEnd: false,
        currentPeriodEnd: null,
      }],
      retrieve: async () => {
        throw new Error("provider unavailable");
      },
      captureError: (_error, context) => contexts.push(context),
      markChecked: async () => {},
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
      withLease: withoutLease,
      list: async () => [
        {
          id: "sub_one",
          status: "active",
          cancelAtPeriodEnd: false,
          currentPeriodEnd: new Date(1_800_000_000_000),
        },
        {
          id: "sub_two",
          status: "active",
          cancelAtPeriodEnd: false,
          currentPeriodEnd: new Date(1_800_000_000_000),
        },
      ],
      retrieve: async (id) => subscription(id),
      markChecked: async () => {},
    });
    expect(result.checked).toBe(1);
    expect(result.truncated).toBe(true);
  });

  test("advances every checked row so a later batch can rotate in", async () => {
    const remaining = ["sub_one", "sub_two"];
    const checked: string[] = [];
    const list = async (limit: number) =>
      remaining.slice(0, limit).map((id) => ({
        id,
        status: "active",
        cancelAtPeriodEnd: false,
        currentPeriodEnd: new Date(1_800_000_000_000),
      }));
    const markChecked = async (ids: readonly string[]) => {
      checked.push(...ids);
      for (const id of ids) remaining.splice(remaining.indexOf(id), 1);
    };
    const dependencies = {
      withLease: withoutLease,
      list,
      retrieve: async (id: string) => subscription(id),
      markChecked,
    };

    expect((await reconcileStripeSubscriptions({ limit: 1 }, dependencies)).truncated)
      .toBe(true);
    expect((await reconcileStripeSubscriptions({ limit: 1 }, dependencies)).truncated)
      .toBe(false);
    expect(checked).toEqual(["sub_one", "sub_two"]);
  });

  test("serializes concurrent cron and operator runs with one shared lease", async () => {
    let releaseFirst!: () => void;
    let signalFirstStarted!: () => void;
    const firstMayFinish = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    const firstStarted = new Promise<void>((resolve) => {
      signalFirstStarted = resolve;
    });
    let leaseTail = Promise.resolve();
    let activeLeases = 0;
    let peakLeases = 0;
    const withLease = async <T>(task: () => Promise<T>): Promise<T> => {
      const previous = leaseTail;
      let release!: () => void;
      leaseTail = new Promise<void>((resolve) => {
        release = resolve;
      });
      await previous;
      activeLeases += 1;
      peakLeases = Math.max(peakLeases, activeLeases);
      try {
        return await task();
      } finally {
        activeLeases -= 1;
        release();
      }
    };
    let listCalls = 0;
    const dependencies = {
      withLease,
      list: async () => {
        listCalls += 1;
        if (listCalls === 1) {
          signalFirstStarted();
          await firstMayFinish;
        }
        return [];
      },
      markChecked: async () => {},
    };
    const first = reconcileStripeSubscriptions({}, dependencies);
    const second = reconcileStripeSubscriptions({}, dependencies);
    await firstStarted;
    expect(listCalls).toBe(1);
    releaseFirst();
    await Promise.all([first, second]);
    expect(listCalls).toBe(2);
    expect(peakLeases).toBe(1);
  });
});
