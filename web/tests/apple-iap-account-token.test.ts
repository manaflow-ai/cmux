import { describe, expect, test } from "bun:test";

import * as accountToken from "../services/billing/apple/accountToken";
import {
  appleAccountTokenResponse,
  requestedAppleBundleId,
  type AppleAccountTokenDependencies,
} from "../services/billing/apple/accountToken";

describe("account token eligibility", () => {
  function deps(overrides: Partial<AppleAccountTokenDependencies> = {}): AppleAccountTokenDependencies {
    return {
      store: { accountTokenForUser: async () => "3f1b0a8e-7f6c-4d6e-9b1a-0c2d3e4f5a6b" },
      goPlanEnabled: async () => true,
      hasActiveStripeSubscription: async () => false,
      billedThroughTeam: async () => false,
      planStatus: (async () => ({
        planId: "free", isPro: false, billingManagement: "none", billingSource: "none", manageUrl: null,
        metadataPlanId: null, hasManualVmPlanOverride: false, metadataChanged: false,
      })) as AppleAccountTokenDependencies["planStatus"],
      env: {},
      ...overrides,
    };
  }
  const app = (bundleId: string | null, storeKitEnvironment: "Production" | "Sandbox" | null = null) =>
    ({ bundleId, storeKitEnvironment });
  const user = { id: "user-a", clientReadOnlyMetadata: {}, update: async () => undefined };

  test("lists the products for the requested app, Go only when its flag is on", async () => {
    const response = await appleAccountTokenResponse(user, app("com.cmux.app"), deps());
    expect(response).toMatchObject({ eligible: true, reason: null, currentPlan: { planId: "free", source: "none" } });
    expect(response.products).toEqual([
      { productId: "com.cmux.app.go.monthly", planId: "go" },
      { productId: "com.cmux.app.pro.monthly", planId: "pro" },
      { productId: "com.cmux.app.max.monthly", planId: "max" },
    ]);
    const noGo = await appleAccountTokenResponse(user, app("dev.cmux.app.beta"), deps({ goPlanEnabled: async () => false }));
    expect(noGo.products.map((product) => product.productId)).toEqual(["dev.cmux.app.beta.pro.monthly", "dev.cmux.app.beta.max.monthly"]);
  });

  test("a Stripe subscriber or a team-billed user is not eligible", async () => {
    expect(await appleAccountTokenResponse(user, app("com.cmux.app"), deps({ hasActiveStripeSubscription: async () => true })))
      .toMatchObject({ eligible: false, reason: "stripe_subscription_active" });
    expect(await appleAccountTokenResponse(user, app("com.cmux.app"), deps({ billedThroughTeam: async () => true })))
      .toMatchObject({ eligible: false, reason: "team_billing" });
  });

  test("an Apple subscriber gets the App Store manage URL", async () => {
    const response = await appleAccountTokenResponse(user, app("com.cmux.app"), deps({
      planStatus: (async () => ({
        planId: "pro", isPro: true, billingManagement: "external", billingSource: "apple",
        manageUrl: "https://apps.apple.com/account/subscriptions",
        metadataPlanId: "pro", hasManualVmPlanOverride: false, metadataChanged: false,
      })) as AppleAccountTokenDependencies["planStatus"],
    }));
    expect(response.currentPlan).toEqual({ planId: "pro", source: "apple", manageUrl: "https://apps.apple.com/account/subscriptions" });
  });

  describe("purchases that would grant nothing", () => {
    const production = { VERCEL_ENV: "production" };
    const unavailable = { eligible: false, reason: "purchases_unavailable", products: [] };

    test("production hides products from a TestFlight (Sandbox) build of the beta app", async () => {
      expect(await appleAccountTokenResponse(user, app("dev.cmux.app.beta", "Sandbox"), deps({ env: production })))
        .toMatchObject(unavailable);
    });

    test("without the environment header, production treats the beta app as Sandbox", async () => {
      expect(await appleAccountTokenResponse(user, app("dev.cmux.app.beta"), deps({ env: production })))
        .toMatchObject(unavailable);
    });

    test("APPLE_IAP_SANDBOX_ENTITLEMENTS that includes the beta app sells to it", async () => {
      const response = await appleAccountTokenResponse(user, app("dev.cmux.app.beta", "Sandbox"), deps({
        env: { ...production, APPLE_IAP_SANDBOX_ENTITLEMENTS: "com.cmux.app,dev.cmux.app.beta" },
      }));
      expect(response).toMatchObject({ eligible: true, reason: null });
      expect(response.products).toHaveLength(3);
    });

    test("the App Store app sells in Production and to App Review in the Sandbox", async () => {
      for (const environment of ["Production", "Sandbox", null] as const) {
        const response = await appleAccountTokenResponse(user, app("com.cmux.app", environment), deps({ env: production }));
        expect(response).toMatchObject({ eligible: true, reason: null });
        expect(response.products).toHaveLength(3);
      }
    });

    test("other deployments sell to every Sandbox build", async () => {
      const response = await appleAccountTokenResponse(user, app("dev.cmux.app.beta", "Sandbox"), deps({ env: {} }));
      expect(response.eligible).toBe(true);
      expect(response.products).toHaveLength(3);
    });

    test("an account reason still wins over purchases_unavailable", async () => {
      expect(await appleAccountTokenResponse(user, app("dev.cmux.app.beta", "Sandbox"), deps({
        env: production, hasActiveStripeSubscription: async () => true,
      }))).toMatchObject({ eligible: false, reason: "stripe_subscription_active" });
    });

    test("the environment header accepts only Sandbox and Production", () => {
      const { requestedStoreKitEnvironment } = accountToken;
      expect(requestedStoreKitEnvironment("Sandbox")).toBe("Sandbox");
      expect(requestedStoreKitEnvironment(" Production ")).toBe("Production");
      expect(requestedStoreKitEnvironment("Xcode")).toBeNull();
      expect(requestedStoreKitEnvironment(null)).toBeNull();
    });
  });

  test("unknown bundle IDs get no products; a missing header means the App Store app", () => {
    expect(requestedAppleBundleId("com.example.other")).toBeNull();
    expect(requestedAppleBundleId(null)).toBe("com.cmux.app");
  });
});
