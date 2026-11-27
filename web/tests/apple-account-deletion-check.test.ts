import { describe, expect, test } from "bun:test";

import { accountDeletionCheckFor, appleSubscriptionWillRenew } from "../services/billing/apple/accountDeletion";

const renewing = { status: "active", environment: "Production", autoRenewEnabled: true } as const;

describe("account deletion App Store check", () => {
  test("warns for a subscription Apple will charge again", () => {
    for (const status of ["active", "grace_period", "billing_retry"]) {
      expect(appleSubscriptionWillRenew({ ...renewing, status })).toBe(true);
    }
    // App Review subscribes in the Sandbox against production.
    expect(appleSubscriptionWillRenew({ ...renewing, environment: "Sandbox" })).toBe(true);
  });

  test("does not warn once auto-renew is off, the subscription ended, or nothing bills", () => {
    expect(appleSubscriptionWillRenew({ ...renewing, autoRenewEnabled: false })).toBe(false);
    expect(appleSubscriptionWillRenew({ ...renewing, autoRenewEnabled: null })).toBe(false);
    expect(appleSubscriptionWillRenew({ ...renewing, status: "expired" })).toBe(false);
    expect(appleSubscriptionWillRenew({ ...renewing, status: "revoked" })).toBe(false);
    expect(appleSubscriptionWillRenew({ ...renewing, environment: "Xcode" })).toBe(false);
  });

  test("links to Apple's subscription management only when one renews", () => {
    expect(accountDeletionCheckFor([])).toEqual({ appStoreSubscriptionRenews: false, manageSubscriptionsUrl: null });
    expect(accountDeletionCheckFor([{ ...renewing, status: "expired" }, renewing])).toEqual({
      appStoreSubscriptionRenews: true,
      manageSubscriptionsUrl: "https://apps.apple.com/account/subscriptions",
    });
  });
});
