import { describe, expect, test } from "bun:test";
import {
  PRO_PLAN_ID,
  PRO_PRODUCT_ID,
  hasActiveProSubscription,
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
