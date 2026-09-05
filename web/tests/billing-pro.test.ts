import { describe, expect, test } from "bun:test";
import {
  FREE_PLAN_ID,
  isTestflightEligible,
  PRO_PLAN_ID,
  reconcileProPlanMetadata,
  resolveProPlanStatus,
  syncProPlanMetadata,
} from "../services/billing/pro";
import {
  AccountDeletionMutationBlockedError,
  AccountDeletionUserMutationInProgressError,
  type AccountDeletionUserMutationLease,
} from "../services/account/deletionLock";
import { AccountMetadataUserUnavailableError } from
  "../services/account/metadataMutation";
import type {
  FreshProMetadataUserMutation,
  ProMetadataJson,
} from "../services/billing/pro";

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

function mutationLease(): AccountDeletionUserMutationLease {
  return { refresh: async () => undefined };
}

function withFreshMetadataUser(
  user: MetadataUser,
): FreshProMetadataUserMutation {
  return async (_userId, operation) =>
    await operation(user, mutationLease());
}

describe("syncProPlanMetadata", () => {
  test("sets cmuxPlan on upgrade and keeps other keys", async () => {
    const user = metadataUser({ theme: "dark" });
    await syncProPlanMetadata(user, true, mutationLease());
    expect(user.updates).toEqual([{ theme: "dark", cmuxPlan: PRO_PLAN_ID }]);
  });

  test("no-op when already pro", async () => {
    const user = metadataUser({ cmuxPlan: PRO_PLAN_ID });
    await syncProPlanMetadata(user, true, mutationLease());
    expect(user.updates).toEqual([]);
  });

  test("removes cmuxPlan when pro lapsed", async () => {
    const user = metadataUser({ cmuxPlan: PRO_PLAN_ID, theme: "dark" });
    await syncProPlanMetadata(user, false, mutationLease());
    expect(user.updates).toEqual([{ theme: "dark" }]);
  });

  test("does not write pro metadata while account deletion is in progress", async () => {
    const user = metadataUser({ cmuxAccountDeleting: true });
    await syncProPlanMetadata(user, true, mutationLease());
    expect(user.updates).toEqual([]);
  });

  test("does not clear pro metadata while account deletion is in progress", async () => {
    const user = metadataUser({ cmuxAccountDeleting: true, cmuxPlan: PRO_PLAN_ID });
    await syncProPlanMetadata(user, false, mutationLease());
    expect(user.updates).toEqual([]);
  });

  test("leaves cmuxVmPlan override untouched", async () => {
    const user = metadataUser({ cmuxVmPlan: "enterprise" });
    await syncProPlanMetadata(user, true, mutationLease());
    expect(user.updates).toEqual([
      { cmuxVmPlan: "enterprise", cmuxPlan: PRO_PLAN_ID },
    ]);
  });

  test("no-op when not pro and metadata has no plan", async () => {
    const user = metadataUser(undefined);
    await syncProPlanMetadata(user, false, mutationLease());
    expect(user.updates).toEqual([]);
  });

  test("tolerates non-object metadata", async () => {
    const user = metadataUser("bogus");
    await syncProPlanMetadata(user, true, mutationLease());
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
        withFreshMetadataUser: withFreshMetadataUser(user),
      }),
    ).toBe(true);
    expect(user.updates).toEqual([{ cmuxPlan: PRO_PLAN_ID }]);
  });

  test("clears metadata when no Stripe subscription row is active", async () => {
    const user = metadataUser({ cmuxPlan: PRO_PLAN_ID }, "user-free");
    expect(
      await reconcileProPlanMetadata(user, {
        hasActiveStripeSubscription: async () => false,
        withFreshMetadataUser: withFreshMetadataUser(user),
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

  test("defers reconciliation while account deletion blocks metadata mutation", async () => {
    const user = metadataUser({}, "user-deleting");

    await expect(
      reconcileProPlanMetadata(user, {
        hasActiveStripeSubscription: async () => true,
        withFreshMetadataUser: async () => {
          throw new AccountDeletionMutationBlockedError("user-deleting");
        },
      }),
    ).resolves.toBe(false);
    expect(user.updates).toEqual([]);
  });
});

describe("resolveProPlanStatus", () => {
  test("reloads metadata inside the account mutation lease before reconciling Pro", async () => {
    const staleUser = metadataUser({}, "user-racing-testflight");
    const freshUser = metadataUser({
      cmuxProTestflightEnrollmentEmails: ["owner@example.com"],
      cmuxProTestflightGrants: [
        { email: "owner@example.com", source: "user" },
      ],
    }, "user-racing-testflight");
    let refreshedLeaseCount = 0;
    const withFreshMetadataUser: FreshProMetadataUserMutation = async (
      _userId,
      operation,
    ) => await operation(freshUser, {
      refresh: async () => {
        refreshedLeaseCount += 1;
      },
    });

    await resolveProPlanStatus(staleUser, {
      hasActiveStripeSubscription: async () => true,
      withFreshMetadataUser,
    });

    expect(staleUser.updates).toEqual([]);
    expect(freshUser.updates).toEqual([{
      cmuxProTestflightEnrollmentEmails: ["owner@example.com"],
      cmuxProTestflightGrants: [
        { email: "owner@example.com", source: "user" },
      ],
      cmuxPlan: PRO_PLAN_ID,
    }]);
    expect(refreshedLeaseCount).toBeGreaterThan(0);
  });

  test("returns pro and syncs metadata only for an active Stripe subscription row", async () => {
    const user = metadataUser({}, "user-stripe-pro");
    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async (stackUserId) =>
          stackUserId === "user-stripe-pro",
        withFreshMetadataUser: withFreshMetadataUser(user),
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
        withFreshMetadataUser: withFreshMetadataUser(user),
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
        withFreshMetadataUser: withFreshMetadataUser(user),
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

  test("keeps Stripe billing management for a lapsed customer", async () => {
    const user = metadataUser({}, "user-lapsed-customer");
    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => false,
        hasStripeCustomer: async () => true,
      }),
    ).resolves.toMatchObject({
      planId: FREE_PLAN_ID,
      isPro: false,
      billingManagement: "stripe",
    });
  });

  test("clears a stale non-pro paid mirror when no Stripe Pro row backs it", async () => {
    for (const stale of ["founders", "team", "PRO"]) {
      const user = metadataUser({ cmuxPlan: stale }, "user-stale");
      const status = await resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => false,
        hasStripeCustomer: async () => false,
        withFreshMetadataUser: async (_userId, operation) => operation(user, mutationLease()),
      });
      expect(status.isPro).toBe(false);
      expect(status.metadataChanged).toBe(true);
      expect(user.updates).toEqual([{}]);
    }
  });

  test("reports Pro from a paid manual override without a Stripe subscription", async () => {
    for (const override of ["pro", "founders", "Team"]) {
      const user = metadataUser({ cmuxVmPlan: override }, "user-granted");
      await expect(
        resolveProPlanStatus(user, {
          hasActiveStripeSubscription: async () => false,
          hasStripeCustomer: async () => false,
        }),
      ).resolves.toEqual({
        planId: PRO_PLAN_ID,
        isPro: true,
        billingManagement: "none",
        metadataPlanId: null,
        hasManualVmPlanOverride: true,
        metadataChanged: false,
      });
      expect(user.updates).toEqual([]);
    }
  });

  test("a free or unknown manual override does not grant Pro", async () => {
    for (const override of ["free", "enterprise"]) {
      const user = metadataUser({ cmuxVmPlan: override }, "user-not-granted");
      const status = await resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => false,
        hasStripeCustomer: async () => false,
      });
      expect(status.isPro).toBe(false);
      expect(status.planId).toBe(FREE_PLAN_ID);
    }
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

  test("still resolves the Stripe plan while another metadata mutation owns the lease", async () => {
    const user = metadataUser({}, "user-checkout-race");

    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => true,
        withFreshMetadataUser: async () => {
          throw new AccountDeletionUserMutationInProgressError(
            "user-checkout-race",
          );
        },
      }),
    ).resolves.toEqual({
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "stripe",
      metadataPlanId: null,
      hasManualVmPlanOverride: false,
      metadataChanged: false,
    });
    expect(user.updates).toEqual([]);
  });

  test("still resolves the Stripe plan when the fresh Stack user disappears", async () => {
    const user = metadataUser({}, "user-disappeared");

    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => true,
        withFreshMetadataUser: async () => {
          throw new AccountMetadataUserUnavailableError("user-disappeared");
        },
      }),
    ).resolves.toMatchObject({
      planId: PRO_PLAN_ID,
      isPro: true,
      metadataChanged: false,
    });
  });

  test("does not hide unexpected metadata reconciliation failures", async () => {
    const user = metadataUser({}, "user-database-error");

    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => true,
        withFreshMetadataUser: async () => {
          throw new Error("metadata database unavailable");
        },
      }),
    ).rejects.toThrow("metadata database unavailable");
  });
});

describe("isTestflightEligible", () => {
  test("requires personal Pro without mutating Stack metadata or granting Team access", async () => {
    const user = metadataUser({ cmuxPlan: PRO_PLAN_ID }, "team-member") as MetadataUser & {
      selectedTeam: { id: string; clientReadOnlyMetadata: unknown };
    };
    user.selectedTeam = {
      id: "team-paid",
      clientReadOnlyMetadata: { cmuxPlan: "team" },
    };

    await expect(isTestflightEligible(user, {
      hasActiveStripeSubscription: async () => false,
    })).resolves.toBe(false);
    expect(user.updates).toEqual([]);
  });
});
