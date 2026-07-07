import { describe, expect, test } from "bun:test";
import {
  PRO_PLAN_ID,
  PRO_PRODUCT_ID,
  FREE_PLAN_ID,
  hasActiveProSubscription,
  reconcileProPlanMetadata,
  resolveProPlanStatus,
  syncProPlanMetadata,
} from "../services/billing/pro";
import type { ProMetadataJson } from "../services/billing/pro";

type ProductInput = {
  id: string | null;
  quantity?: number;
  subscription?: {
    cancelAtPeriodEnd: boolean;
    currentPeriodEnd: Date | null;
  } | null;
};

function productsPage(items: ProductInput[], nextCursor: string | null = null) {
  const page = items.map((item) => ({
    id: item.id,
    quantity: item.quantity ?? 0,
    subscription: item.subscription ?? null,
  })) as Array<{
    id: string | null;
    quantity: number;
    subscription: null | {
      cancelAtPeriodEnd: boolean;
      currentPeriodEnd: Date | null;
    };
  }> & { nextCursor: string | null };
  page.nextCursor = nextCursor;
  return page;
}

function customerWithPages(
  pages: ReturnType<typeof productsPage>[],
): {
  listProducts: (options?: { cursor?: string }) => Promise<
    ReturnType<typeof productsPage>
  >;
  requestedCursors: (string | undefined)[];
} {
  const requestedCursors: (string | undefined)[] = [];
  return {
    requestedCursors,
    listProducts: async (options?: { cursor?: string }) => {
      requestedCursors.push(options?.cursor);
      return pages[requestedCursors.length - 1] ?? productsPage([]);
    },
  };
}

describe("hasActiveProSubscription", () => {
  test("active subscription counts", async () => {
    const customer = customerWithPages([
      productsPage([
        {
          id: PRO_PRODUCT_ID,
          subscription: { cancelAtPeriodEnd: false, currentPeriodEnd: null },
        },
      ]),
    ]);
    expect(await hasActiveProSubscription(customer)).toBe(true);
  });

  test("subscription set to cancel at period end still counts", async () => {
    const customer = customerWithPages([
      productsPage([
        {
          id: PRO_PRODUCT_ID,
          subscription: { cancelAtPeriodEnd: true, currentPeriodEnd: null },
        },
      ]),
    ]);
    expect(await hasActiveProSubscription(customer)).toBe(true);
  });

  test("manual grant (quantity, no subscription) counts", async () => {
    const customer = customerWithPages([
      productsPage([{ id: PRO_PRODUCT_ID, quantity: 1 }]),
    ]);
    expect(await hasActiveProSubscription(customer)).toBe(true);
  });

  test("subscription past its period end does not count", async () => {
    const customer = customerWithPages([
      productsPage([
        {
          id: PRO_PRODUCT_ID,
          subscription: {
            cancelAtPeriodEnd: true,
            currentPeriodEnd: new Date(Date.now() - 60_000),
          },
        },
      ]),
    ]);
    expect(await hasActiveProSubscription(customer)).toBe(false);
  });

  test("subscription with future period end counts", async () => {
    const customer = customerWithPages([
      productsPage([
        {
          id: PRO_PRODUCT_ID,
          subscription: {
            cancelAtPeriodEnd: true,
            currentPeriodEnd: new Date(Date.now() + 60_000),
          },
        },
      ]),
    ]);
    expect(await hasActiveProSubscription(customer)).toBe(true);
  });

  test("other products do not count", async () => {
    const customer = customerWithPages([
      productsPage([
        {
          id: "team",
          subscription: { cancelAtPeriodEnd: false, currentPeriodEnd: null },
        },
        { id: PRO_PRODUCT_ID, quantity: 0 },
      ]),
    ]);
    expect(await hasActiveProSubscription(customer)).toBe(false);
  });

  test("walks pagination cursors until pro is found", async () => {
    const customer = customerWithPages([
      productsPage([{ id: "team", quantity: 1 }], "cursor-2"),
      productsPage([
        {
          id: PRO_PRODUCT_ID,
          subscription: { cancelAtPeriodEnd: false, currentPeriodEnd: null },
        },
      ]),
    ]);
    expect(await hasActiveProSubscription(customer)).toBe(true);
    expect(customer.requestedCursors).toEqual([undefined, "cursor-2"]);
  });
});

type MetadataUser = {
  clientReadOnlyMetadata?: unknown;
  update: (options: {
    clientReadOnlyMetadata: ProMetadataJson;
  }) => Promise<void>;
  updates: ProMetadataJson[];
};

function metadataUser(metadata: unknown): MetadataUser {
  const updates: ProMetadataJson[] = [];
  return {
    clientReadOnlyMetadata: metadata,
    updates,
    update: async (options) => {
      updates.push(options.clientReadOnlyMetadata);
    },
  };
}

describe("syncProPlanMetadata", () => {
  test("sets cmuxPlan on upgrade and keeps other keys", async () => {
    const user = metadataUser({ theme: "dark" });
    await syncProPlanMetadata(user, true);
    expect(user.updates).toEqual([{ theme: "dark", cmuxPlan: PRO_PLAN_ID }]);
  });

  test("no-op when already pro", async () => {
    const user = metadataUser({ cmuxPlan: PRO_PLAN_ID });
    await syncProPlanMetadata(user, true);
    expect(user.updates).toEqual([]);
  });

  test("removes cmuxPlan when pro lapsed", async () => {
    const user = metadataUser({ cmuxPlan: PRO_PLAN_ID, theme: "dark" });
    await syncProPlanMetadata(user, false);
    expect(user.updates).toEqual([{ theme: "dark" }]);
  });

  test("leaves cmuxVmPlan override untouched", async () => {
    const user = metadataUser({ cmuxVmPlan: "enterprise" });
    await syncProPlanMetadata(user, true);
    expect(user.updates).toEqual([
      { cmuxVmPlan: "enterprise", cmuxPlan: PRO_PLAN_ID },
    ]);
  });

  test("no-op when not pro and metadata has no plan", async () => {
    const user = metadataUser(undefined);
    await syncProPlanMetadata(user, false);
    expect(user.updates).toEqual([]);
  });

  test("tolerates non-object metadata", async () => {
    const user = metadataUser("bogus");
    await syncProPlanMetadata(user, true);
    expect(user.updates).toEqual([{ cmuxPlan: PRO_PLAN_ID }]);
  });
});

describe("reconcileProPlanMetadata", () => {
  function reconcileUser(metadata: unknown, products: ProductInput[]) {
    const base = metadataUser(metadata);
    const pages = customerWithPages([productsPage(products)]);
    return { ...base, listProducts: pages.listProducts };
  }

  const activePro: ProductInput = {
    id: PRO_PRODUCT_ID,
    subscription: { cancelAtPeriodEnd: false, currentPeriodEnd: null },
  };

  test("upgrades metadata when subscribed but unsynced", async () => {
    const user = reconcileUser({}, [activePro]);
    expect(await reconcileProPlanMetadata(user)).toBe(true);
    expect(user.updates).toEqual([{ cmuxPlan: PRO_PLAN_ID }]);
  });

  test("clears metadata when subscription lapsed", async () => {
    const user = reconcileUser({ cmuxPlan: PRO_PLAN_ID }, []);
    expect(await reconcileProPlanMetadata(user)).toBe(true);
    expect(user.updates).toEqual([{}]);
  });

  test("no-op when already in sync", async () => {
    const user = reconcileUser({ cmuxPlan: PRO_PLAN_ID }, [activePro]);
    expect(await reconcileProPlanMetadata(user)).toBe(false);
    expect(user.updates).toEqual([]);
  });

  test("skips when manual cmuxVmPlan override is set", async () => {
    const user = reconcileUser({ cmuxVmPlan: "enterprise" }, []);
    expect(await reconcileProPlanMetadata(user)).toBe(false);
    expect(user.updates).toEqual([]);
  });
});

describe("resolveProPlanStatus", () => {
  function statusUser(metadata: unknown, products: ProductInput[], id?: string) {
    const base = metadataUser(metadata);
    const pages = customerWithPages([productsPage(products)]);
    return { ...base, id, listProducts: pages.listProducts };
  }

  const activePro: ProductInput = {
    id: PRO_PRODUCT_ID,
    subscription: { cancelAtPeriodEnd: false, currentPeriodEnd: null },
  };

  test("returns pro and syncs metadata for an active subscription", async () => {
    const user = statusUser({}, [activePro]);
    await expect(resolveProPlanStatus(user)).resolves.toEqual({
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "external",
      metadataPlanId: null,
      hasManualVmPlanOverride: false,
      metadataChanged: true,
    });
    expect(user.updates).toEqual([{ cmuxPlan: PRO_PLAN_ID }]);
  });

  test("returns free and clears stale pro metadata after lapse", async () => {
    const user = statusUser({ cmuxPlan: PRO_PLAN_ID }, []);
    await expect(resolveProPlanStatus(user)).resolves.toEqual({
      planId: FREE_PLAN_ID,
      isPro: false,
      billingManagement: "none",
      metadataPlanId: PRO_PLAN_ID,
      hasManualVmPlanOverride: false,
      metadataChanged: true,
    });
    expect(user.updates).toEqual([{}]);
  });

  test("does not mutate metadata when a manual VM plan override exists", async () => {
    const user = statusUser({ cmuxVmPlan: "enterprise" }, [activePro]);
    await expect(resolveProPlanStatus(user)).resolves.toEqual({
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "external",
      metadataPlanId: null,
      hasManualVmPlanOverride: true,
      metadataChanged: false,
    });
    expect(user.updates).toEqual([]);
  });

  test("returns pro when Stripe has an active subscription row", async () => {
    const user = statusUser({}, [], "user-stripe-pro");
    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async (stackUserId) => stackUserId === "user-stripe-pro",
      }),
    ).resolves.toEqual({
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "stripe",
      metadataPlanId: null,
      hasManualVmPlanOverride: false,
      metadataChanged: true,
    });
    expect(user.updates).toEqual([{ cmuxPlan: PRO_PLAN_ID }]);
  });
});
