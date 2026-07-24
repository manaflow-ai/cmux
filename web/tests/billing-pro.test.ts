import { describe, expect, test } from "bun:test";
import {
  FREE_PLAN_ID,
  PRO_PLAN_ID,
  reconcileProPlanMetadata,
  resolveProPlanStatus,
  syncProPlanMetadata,
} from "../services/billing/pro";
import type { ProMetadataJson } from "../services/billing/pro";

type MetadataUser = {
  id?: string;
  clientReadOnlyMetadata?: unknown;
  update: (options: {
    clientReadOnlyMetadata: ProMetadataJson;
  }) => Promise<void>;
  updates: ProMetadataJson[];
  stackProductGrant?: boolean;
};

function metadataUser(metadata: unknown, id?: string): MetadataUser {
  const updates: ProMetadataJson[] = [];
  return {
    id,
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

  test("does not write pro metadata while account deletion is in progress", async () => {
    const user = metadataUser({ cmuxAccountDeleting: true });
    await syncProPlanMetadata(user, true);
    expect(user.updates).toEqual([]);
  });

  test("does not clear pro metadata while account deletion is in progress", async () => {
    const user = metadataUser({ cmuxAccountDeleting: true, cmuxPlan: PRO_PLAN_ID });
    await syncProPlanMetadata(user, false);
    expect(user.updates).toEqual([]);
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
  test("upgrades metadata when a Stripe subscription row is active", async () => {
    const user = metadataUser({}, "user-stripe-pro");
    expect(
      await reconcileProPlanMetadata(user, {
        hasActiveStripeSubscription: async (stackUserId) =>
          stackUserId === "user-stripe-pro",
      }),
    ).toBe(true);
    expect(user.updates).toEqual([{ cmuxPlan: PRO_PLAN_ID }]);
  });

  test("clears metadata when no Stripe subscription row is active", async () => {
    const user = metadataUser({ cmuxPlan: PRO_PLAN_ID }, "user-free");
    expect(
      await reconcileProPlanMetadata(user, {
        hasActiveStripeSubscription: async () => false,
      }),
    ).toBe(true);
    expect(user.updates).toEqual([{}]);
  });

  test("ignores Stack product subscriptions when reconciling", async () => {
    const user = metadataUser({}, "user-stack-only");
    user.stackProductGrant = true;

    expect(
      await reconcileProPlanMetadata(user, {
        hasActiveStripeSubscription: async () => false,
      }),
    ).toBe(false);
    expect(user.updates).toEqual([]);
  });

  test("skips when manual cmuxVmPlan override is set", async () => {
    const user = metadataUser({ cmuxVmPlan: "enterprise" }, "user-free");
    expect(
      await reconcileProPlanMetadata(user, {
        hasActiveStripeSubscription: async () => false,
      }),
    ).toBe(false);
    expect(user.updates).toEqual([]);
  });
});

describe("resolveProPlanStatus", () => {
  test("returns pro and syncs metadata only for an active Stripe subscription row", async () => {
    const user = metadataUser({}, "user-stripe-pro");
    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async (stackUserId) =>
          stackUserId === "user-stripe-pro",
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

  test("Stack product subscriptions do not grant Pro", async () => {
    const user = metadataUser({}, "user-stack-only");
    user.stackProductGrant = true;

    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => false,
      }),
    ).resolves.toEqual({
      planId: FREE_PLAN_ID,
      isPro: false,
      billingManagement: "none",
      metadataPlanId: null,
      hasManualVmPlanOverride: false,
      metadataChanged: false,
    });
    expect(user.updates).toEqual([]);
  });

  test("returns free and clears stale pro metadata after Stripe lapse", async () => {
    const user = metadataUser({ cmuxPlan: PRO_PLAN_ID }, "user-lapsed");
    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => false,
      }),
    ).resolves.toEqual({
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
    const user = metadataUser({ cmuxVmPlan: "enterprise" }, "user-stripe-pro");
    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => true,
      }),
    ).resolves.toEqual({
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "stripe",
      metadataPlanId: null,
      hasManualVmPlanOverride: true,
      metadataChanged: false,
    });
    expect(user.updates).toEqual([]);
  });
});
