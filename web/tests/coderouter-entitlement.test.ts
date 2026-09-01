import { describe, expect, mock, test } from "bun:test";

import {
  CODEROUTER_FREE_ACCOUNT_LIMIT,
  createAccountAdditionGate,
  createCoderouterEntitlementCheck,
} from "../services/coderouter/entitlement";

describe("coderouter entitlement", () => {
  test("free limit is 3 connected accounts", () => {
    expect(CODEROUTER_FREE_ACCOUNT_LIMIT).toBe(3);
  });

  test("a team at or under the free limit routes without a subscription", async () => {
    for (const count of [0, 1, 2, 3]) {
      const hasActiveSubscription = mock(async () => false);
      const check = createCoderouterEntitlementCheck({
        countAccounts: async () => count,
        hasActiveSubscription,
      });
      const result = await check("user_1", "team_1");
      expect(result).toEqual({
        allowed: true,
        basis: "free_tier",
        accountCount: count,
      });
      // The Stripe read must not run for free-tier teams.
      expect(hasActiveSubscription).not.toHaveBeenCalled();
    }
  });

  test("a team over the free limit requires a subscription", async () => {
    const check = createCoderouterEntitlementCheck({
      countAccounts: async () => 4,
      hasActiveSubscription: async () => false,
    });
    await expect(check("user_1", "team_1")).resolves.toEqual({
      allowed: false,
      basis: "pro_required",
      accountCount: 4,
    });
  });

  test("a subscription covers a team over the free limit", async () => {
    const check = createCoderouterEntitlementCheck({
      countAccounts: async () => 7,
      hasActiveSubscription: async (userId, teamId) =>
        userId === "user_1" && teamId === "team_1",
    });
    await expect(check("user_1", "team_1")).resolves.toEqual({
      allowed: true,
      basis: "subscription",
      accountCount: 7,
    });
  });
});

describe("coderouter account addition gate", () => {
  const input = {
    stackUserId: "user_1",
    teamId: "team_1",
    provider: "codex" as const,
    providerAccountId: "acct-openai-1",
  };

  test("allows a new account while the team stays within the free limit", async () => {
    const gate = createAccountAdditionGate({
      countAccounts: async () => 2,
      hasActiveSubscription: async () => false,
      findExisting: async () => null,
    });
    await expect(gate(input)).resolves.toEqual({
      allowed: true,
      accountCount: 2,
    });
  });

  test("blocks the fourth account without a subscription", async () => {
    const gate = createAccountAdditionGate({
      countAccounts: async () => 3,
      hasActiveSubscription: async () => false,
      findExisting: async () => null,
    });
    await expect(gate(input)).resolves.toEqual({
      allowed: false,
      accountCount: 3,
    });
  });

  test("allows the fourth account with a subscription", async () => {
    const gate = createAccountAdditionGate({
      countAccounts: async () => 3,
      hasActiveSubscription: async () => true,
      findExisting: async () => null,
    });
    await expect(gate(input)).resolves.toEqual({
      allowed: true,
      accountCount: 3,
    });
  });

  test("always allows re-importing an existing account", async () => {
    const hasActiveSubscription = mock(async () => false);
    const gate = createAccountAdditionGate({
      countAccounts: async () => 5,
      hasActiveSubscription,
      findExisting: async () => ({ id: "acct-1", state: "broken", vaultRevision: 2 }),
    });
    await expect(gate(input)).resolves.toEqual({
      allowed: true,
      accountCount: 5,
    });
    expect(hasActiveSubscription).not.toHaveBeenCalled();
  });
});
