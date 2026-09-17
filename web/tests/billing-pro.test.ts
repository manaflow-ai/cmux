import { describe, expect, test } from "bun:test";
import {
  FREE_PLAN_ID,
  hasActiveCoderouterSubscription,
  isDevelopmentProAccessEnabled,
  isTestflightEligible,
  hasFounderEditionEntitlement,
  isFounderPlanId,
  normalizePersonalPlan,
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
import { billingPlanIdFromMetadata } from "../services/billing/teamResolution";
import type {
  FreshProMetadataUserMutation,
  ProMetadataJson,
} from "../services/billing/pro";

type MetadataUser = {
  id?: string;
  primaryEmail?: string | null;
  primaryEmailVerified?: boolean;
  isAnonymous?: boolean;
  isRestricted?: boolean;
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

  test("clears a lapsed Stripe mirror without changing an operator Founder grant", async () => {
    const user = metadataUser({ cmuxVmPlan: "founders", cmuxPlan: PRO_PLAN_ID, theme: "dark" });
    await syncProPlanMetadata(user, true, mutationLease());
    expect(user.updates).toEqual([]);
    const metadata = await syncProPlanMetadata(user, false, mutationLease());
    expect(user.updates).toEqual([{ cmuxVmPlan: "founders", theme: "dark" }]);
    expect(normalizePersonalPlan(metadata, false).isPro).toBe(true);
    expect(billingPlanIdFromMetadata({ ...user.updates[0] as object, cmuxVmPlan: null })).toBeNull();
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

describe("normalizePersonalPlan", () => {
  test("accepts the verified Founder marker without trusting an email", () => {
    expect(hasFounderEditionEntitlement({ cmuxVmPlan: " Founders " })).toBe(true);
    expect(
      normalizePersonalPlan({ cmuxVmPlan: "founders" }, false),
    ).toEqual({
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "none",
    });
  });

  test("honors an explicit VM-plan override over a lower-priority Founder marker", () => {
    expect(
      normalizePersonalPlan(
        { cmuxVmPlan: "free", cmuxPlan: "founders" },
        false,
      ),
    ).toEqual({
      planId: FREE_PLAN_ID,
      isPro: false,
      billingManagement: "none",
    });
  });

  test("recognizes a normalized Pro mirror when a Founder grant remains", () => {
    expect(
      normalizePersonalPlan(
        { cmuxVmPlan: "founders", cmuxPlan: PRO_PLAN_ID },
        false,
      ),
    ).toEqual({
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "none",
    });
  });

  test("normalizes Founder plan ids for shared entitlement gates", () => {
    expect(isFounderPlanId(" Founders ")).toBe(true);
    expect(isFounderPlanId("pro")).toBe(false);
  });

  test("lets hosted CodeRouter recognize an operator Founder grant without Stripe", async () => {
    await expect(
      hasActiveCoderouterSubscription("founder-user", "team-1", "founders", true),
    ).resolves.toBe(true);
  });

  test("does not trust a bare mirrored Founder id without the manual-override bit", async () => {
    await expect(
      hasActiveCoderouterSubscription("mirrored-founder", "team-1", "founders", false),
    ).resolves.toBe(false);
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

  test("does not write when neither a billing row nor a stale mirror exists", async () => {
    const user = metadataUser({ cmuxVmPlan: "enterprise" }, "user-free");
    expect(
      await reconcileProPlanMetadata(user, {
        hasActiveStripeSubscription: async () => false,
      }),
    ).toBe(false);
    expect(user.updates).toEqual([]);
  });

  for (const override of ["pro", "team", " Founders ", "free", "enterprise"]) {
    test(`clears a stale billing mirror beneath the ${override} override`, async () => {
      const user = metadataUser({ cmuxVmPlan: override, cmuxPlan: PRO_PLAN_ID, theme: "dark" }, "user-granted");
      expect(await reconcileProPlanMetadata(user, {
        hasActiveStripeSubscription: async () => false,
        hasActiveFounderSubscription: async () => false,
        withFreshMetadataUser: withFreshMetadataUser(user),
      })).toBe(true);
      expect(user.updates).toEqual([{ cmuxVmPlan: override, theme: "dark" }]);
      expect(billingPlanIdFromMetadata({ ...user.updates[0] as object, cmuxVmPlan: null })).toBeNull();
    });
  }

  test("clears the stale mirror using fresh metadata when a Founder grant races the read", async () => {
    const user = metadataUser({ cmuxPlan: PRO_PLAN_ID }, "user-granted");
    const freshUser = metadataUser({ cmuxPlan: PRO_PLAN_ID, cmuxVmPlan: "founders", theme: "dark" }, "user-granted");
    expect(await reconcileProPlanMetadata(user, {
      hasActiveStripeSubscription: async () => false,
      hasActiveFounderSubscription: async () => false,
      withFreshMetadataUser: withFreshMetadataUser(freshUser),
    })).toBe(true);
    expect(user.updates).toEqual([]);
    expect(freshUser.updates).toEqual([{ cmuxVmPlan: "founders", theme: "dark" }]);
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
  test("runs the pending ownership claim only for a verified account", async () => {
    const user = metadataUser({}, "user-verified");
    user.primaryEmail = "buyer@example.com";
    user.primaryEmailVerified = true;
    user.isAnonymous = false;
    user.isRestricted = false;
    let claimed = false;
    const claimPendingBilling = async (candidate: { id: string }) => {
      claimed = candidate.id === "user-verified";
    };

    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => false,
        claimPendingBilling,
      }),
    ).resolves.toMatchObject({
      planId: FREE_PLAN_ID,
      isPro: false,
    });
    expect(claimed).toBe(true);
  });

  test("does not claim billing from an unverified account", async () => {
    const user = metadataUser({}, "user-unverified");
    user.primaryEmail = "buyer@example.com";
    user.primaryEmailVerified = false;
    let claimed = false;
    const claimPendingBilling = async () => {
      claimed = true;
    };

    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => false,
        claimPendingBilling,
      }),
    ).resolves.toMatchObject({
      planId: FREE_PLAN_ID,
      isPro: false,
    });
    expect(claimed).toBe(false);
  });

  test("normalizes a verified Founder entitlement to Pro without Stripe management", async () => {
    const user = metadataUser({ cmuxVmPlan: "founders" }, "user-founder");

    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => false,
        withFreshMetadataUser: withFreshMetadataUser(user),
      }),
    ).resolves.toMatchObject({
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "none",
      hasManualVmPlanOverride: true,
      metadataChanged: false,
    });
    expect(user.updates).toEqual([]);
  });

  test("keeps Stripe management when a Founder also has a Stripe subscription", async () => {
    const user = metadataUser({ cmuxVmPlan: "founders" }, "user-founder-pro");

    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => true,
        withFreshMetadataUser: withFreshMetadataUser(user),
      }),
    ).resolves.toMatchObject({
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "stripe",
      hasManualVmPlanOverride: true,
      metadataChanged: true,
    });
    expect(user.updates).toEqual([{ cmuxVmPlan: "founders", cmuxPlan: PRO_PLAN_ID }]);
  });

  test("clears the lapsed Pro mirror while an operator Founder grant remains", async () => {
    const user = metadataUser(
      { cmuxVmPlan: "founders", cmuxPlan: PRO_PLAN_ID },
      "user-founder-normalized",
    );

    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => true,
        withFreshMetadataUser: withFreshMetadataUser(user),
      }),
    ).resolves.toMatchObject({
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "stripe",
      hasManualVmPlanOverride: true,
      metadataChanged: false,
    });
    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => false,
        withFreshMetadataUser: withFreshMetadataUser(user),
      }),
    ).resolves.toMatchObject({
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "none",
      hasManualVmPlanOverride: true,
      metadataChanged: true,
    });
    expect(user.updates).toEqual([{ cmuxVmPlan: "founders" }]);
    expect(billingPlanIdFromMetadata({ ...user.updates[0] as object, cmuxVmPlan: null })).toBeNull();
  });

  for (const override of ["founders", "pro", "team", "free"]) {
    test(`keeps durable Founder backing independent of the ${override} override`, async () => {
      const user = metadataUser({ cmuxVmPlan: override }, "user-founder-row");
      let founderReads = 0;
      const status = await resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => false,
        hasActiveFounderSubscription: async () => {
          founderReads += 1;
          return true;
        },
        withFreshMetadataUser: withFreshMetadataUser(user),
      });
      expect(founderReads).toBe(1);
      expect(status).toMatchObject({
        isPro: override !== "free",
        billingManagement: "none",
        metadataChanged: true,
      });
      expect(user.updates).toEqual([{ cmuxVmPlan: override, cmuxPlan: PRO_PLAN_ID }]);
      expect(billingPlanIdFromMetadata({ ...user.updates[0] as object, cmuxVmPlan: null })).toBe(PRO_PLAN_ID);
    });
  }

  test("recognizes a durable Founder subscription without enabling Stripe management", async () => {
    const user = metadataUser({}, "user-founder-row");

    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => false,
        hasActiveFounderSubscription: async () => true,
        withFreshMetadataUser: withFreshMetadataUser(user),
      }),
    ).resolves.toMatchObject({
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "none",
      hasManualVmPlanOverride: false,
      metadataChanged: true,
    });
    expect(user.updates).toEqual([{ cmuxPlan: PRO_PLAN_ID }]);
  });

  test("local development Stack accounts receive Pro without a billing grant", async () => {
    expect(isDevelopmentProAccessEnabled({
      NODE_ENV: "development",
      CMUX_LOCAL_DEV_PRO: "1",
      NEXT_PUBLIC_STACK_PROJECT_ID: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
    })).toBe(true);
    expect(isDevelopmentProAccessEnabled({
      NODE_ENV: "development",
      NEXT_PUBLIC_STACK_PROJECT_ID: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
    })).toBe(false);
    expect(isDevelopmentProAccessEnabled({
      NODE_ENV: "production",
      NEXT_PUBLIC_STACK_PROJECT_ID: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
    })).toBe(false);
    expect(isDevelopmentProAccessEnabled({
      NODE_ENV: "development",
      NEXT_PUBLIC_STACK_PROJECT_ID: "9790718f-14cd-4f7e-824d-eaf527a82b82",
    })).toBe(false);

    const user = metadataUser({}, "user-local-dev");
    await expect(resolveProPlanStatus(user, {
      environment: {
        NODE_ENV: "development",
        CMUX_LOCAL_DEV_PRO: "1",
        NEXT_PUBLIC_STACK_PROJECT_ID: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
      },
    })).resolves.toEqual({
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "none",
      metadataPlanId: null,
      hasManualVmPlanOverride: false,
      metadataChanged: false,
    });

    await expect(resolveProPlanStatus({ ...user, isAnonymous: true }, {
      environment: {
        NODE_ENV: "development",
        CMUX_LOCAL_DEV_PRO: "1",
        NEXT_PUBLIC_STACK_PROJECT_ID: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
      },
      hasActiveStripeSubscription: async () => false,
    })).resolves.toMatchObject({
      planId: FREE_PLAN_ID,
      isPro: false,
    });
  });

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

  test("syncs only the billing mirror when a manual VM plan override exists", async () => {
    const user = metadataUser({ cmuxVmPlan: "enterprise" }, "user-stripe-pro");
    await expect(
      resolveProPlanStatus(user, {
        hasActiveStripeSubscription: async () => true,
        withFreshMetadataUser: withFreshMetadataUser(user),
      }),
    ).resolves.toEqual({
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "stripe",
      metadataPlanId: null,
      hasManualVmPlanOverride: true,
      metadataChanged: true,
    });
    expect(user.updates).toEqual([{ cmuxVmPlan: "enterprise", cmuxPlan: PRO_PLAN_ID }]);
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
  for (const plan of ["pro", "team", " PRO "]) {
    test(`includes the personal operator grant ${plan} without requiring Stripe`, async () => {
      const user = metadataUser({ cmuxVmPlan: plan }, "operator-granted-testflight");

      await expect(isTestflightEligible(user, {
        hasActiveStripeSubscription: async () => false,
      })).resolves.toBe(true);
      await expect(isTestflightEligible(user, {
        hasActiveStripeSubscription: async () => false,
        hasActiveFounderSubscription: async () => true,
      })).resolves.toBe(true);
      expect(user.updates).toEqual([]);
    });
  }

  for (const plan of ["pro", "team", "founders"]) {
    test(`does not turn an unbacked ${plan} mirror into a TestFlight grant`, async () => {
      const user = metadataUser({ cmuxPlan: plan }, "unbacked-testflight-mirror");

      await expect(isTestflightEligible(user, {
        hasActiveStripeSubscription: async () => false,
      })).resolves.toBe(false);
      expect(user.updates).toEqual([]);
    });
  }

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

  test("includes a Founder metadata entitlement", async () => {
    const user = metadataUser({ cmuxVmPlan: "founders" }, "founder-testflight");

    await expect(
      isTestflightEligible(user, {
        hasActiveStripeSubscription: async () => false,
      }),
    ).resolves.toBe(true);
  });

  test("includes a durable Founder row when the mailbox is otherwise Pro-eligible", async () => {
    const user = metadataUser({}, "founder-row-testflight");

    await expect(
      isTestflightEligible(user, {
        hasActiveStripeSubscription: async () => false,
        hasActiveFounderSubscription: async () => true,
      }),
    ).resolves.toBe(true);
  });

  test("honors a non-Founder VM override over a Founder row", async () => {
    const user = metadataUser({ cmuxVmPlan: "free" }, "founder-row-overridden");

    await expect(
      isTestflightEligible(user, {
        hasActiveStripeSubscription: async () => false,
        hasActiveFounderSubscription: async () => true,
      }),
    ).resolves.toBe(false);
  });
});
