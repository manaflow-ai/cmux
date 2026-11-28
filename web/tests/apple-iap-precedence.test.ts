// Stripe and Apple grant through one `cmuxPlan` mirror. The higher plan
// wins, and neither source's lapse may erase the other's grant.

import { describe, expect, test } from "bun:test";

import type { AccountDeletionUserMutationLease } from "../services/account/deletionLock";
import {
  reconcileProPlanMetadata,
  resolveProPlanStatus,
  syncProPlanMetadata,
  type FreshProMetadataUserMutation,
  type PersonalPlanId,
  type ProMetadataJson,
} from "../services/billing/pro";

type MetadataUser = {
  id: string;
  clientReadOnlyMetadata: unknown;
  updates: ProMetadataJson[];
  update(options: { clientReadOnlyMetadata: ProMetadataJson }): Promise<void>;
};

function metadataUser(metadata: Record<string, unknown>): MetadataUser {
  const user: MetadataUser = {
    id: "user-a",
    clientReadOnlyMetadata: metadata,
    updates: [],
    update: async ({ clientReadOnlyMetadata }) => {
      user.updates.push(clientReadOnlyMetadata);
      user.clientReadOnlyMetadata = clientReadOnlyMetadata;
    },
  };
  return user;
}

const lease: AccountDeletionUserMutationLease = { refresh: async () => undefined };

function fresh(user: MetadataUser): FreshProMetadataUserMutation {
  return async (_id, operation) => await operation(user, lease);
}

function sources(stripe: PersonalPlanId | null, apple: PersonalPlanId | null, user: MetadataUser) {
  return {
    activePersonalPlan: async () => stripe,
    hasStripeCustomer: async () => stripe !== null,
    activeApplePlan: async () => apple,
    withFreshMetadataUser: fresh(user),
  };
}

describe("Stripe and Apple entitlement precedence", () => {
  test("an Apple-only subscriber reports source apple, external management, and the App Store manage URL", async () => {
    const user = metadataUser({});
    const status = await resolveProPlanStatus(user, sources(null, "pro", user));
    expect(status).toMatchObject({
      planId: "pro",
      isPro: true,
      billingSource: "apple",
      billingManagement: "external",
      manageUrl: "https://apps.apple.com/account/subscriptions",
    });
    expect(user.clientReadOnlyMetadata).toEqual({ cmuxPlan: "pro" });
  });

  test("the higher plan wins in either direction", async () => {
    const appleHigher = metadataUser({});
    expect(await resolveProPlanStatus(appleHigher, sources("go", "max", appleHigher)))
      .toMatchObject({ planId: "max", billingSource: "apple", billingManagement: "stripe" });
    expect(appleHigher.clientReadOnlyMetadata).toEqual({ cmuxPlan: "max" });

    const stripeHigher = metadataUser({});
    expect(await resolveProPlanStatus(stripeHigher, sources("max", "pro", stripeHigher)))
      .toMatchObject({ planId: "max", billingSource: "stripe", manageUrl: null });

    const tie = metadataUser({});
    expect(await resolveProPlanStatus(tie, sources("pro", "pro", tie))).toMatchObject({ billingSource: "stripe" });
  });

  test("a Stripe lapse keeps an Apple grant", async () => {
    const user = metadataUser({ cmuxPlan: "pro" });
    await syncProPlanMetadata(user, false, lease, "pro", "pro");
    expect(user.updates).toEqual([]);
    expect(user.clientReadOnlyMetadata).toEqual({ cmuxPlan: "pro" });
  });

  test("a Stripe Go purchase never downgrades an Apple Max mirror", async () => {
    const user = metadataUser({ cmuxPlan: "max" });
    await syncProPlanMetadata(user, true, lease, "go", "max");
    expect(user.clientReadOnlyMetadata).toEqual({ cmuxPlan: "max" });
  });

  test("an Apple lapse falls back to the Stripe plan instead of clearing it", async () => {
    const user = metadataUser({ cmuxPlan: "max" });
    const changed = await reconcileProPlanMetadata(user, sources("pro", null, user));
    expect(changed).toBe(true);
    expect(user.clientReadOnlyMetadata).toEqual({ cmuxPlan: "pro" });
  });

  test("Apple expiry, refund or revoke with no Stripe plan removes the grant", async () => {
    const user = metadataUser({ cmuxPlan: "pro", theme: "dark" });
    await reconcileProPlanMetadata(user, sources(null, null, user));
    expect(user.clientReadOnlyMetadata).toEqual({ theme: "dark" });
    const status = await resolveProPlanStatus(user, sources(null, null, user));
    expect(status).toMatchObject({ planId: "free", billingSource: "none", billingManagement: "none" });
  });

  test("an operator override is left alone, as for Stripe", async () => {
    const user = metadataUser({ cmuxVmPlan: "pro" });
    expect(await reconcileProPlanMetadata(user, sources(null, "max", user))).toBe(false);
    expect(user.updates).toEqual([]);
  });
});
