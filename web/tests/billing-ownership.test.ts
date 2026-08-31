import { describe, expect, mock, test } from "bun:test";

import { claimPendingProBilling } from "../services/billing/purchase";

describe("billing email claim resolution", () => {
  test("moves an anonymous paid claim to a verified canonical account", async () => {
    const transfer = {
      kind: "claimed" as const,
      claimId: "claim-1",
      email: "billingfixture@gmail.com",
      customerId: "cus-1",
      subscriptionIds: ["sub-1"],
      sourceStackUserId: "anonymous-1",
      targetStackUserId: "target-1",
    };
    const findClaims = mock(async () => [
      {
        id: transfer.claimId,
        email: transfer.email,
        stripeCustomerId: transfer.customerId,
        stackUserId: transfer.sourceStackUserId,
        claimedByUserId: null,
      },
    ]);
    const transferClaim = mock(async () => transfer);
    const customerUpdate = mock(async () => ({}));
    const subscriptionUpdate = mock(async () => ({}));

    const result = await claimPendingProBilling(
      {
        id: "target-1",
        primaryEmail: "Billing.Fixture@Gmail.com",
        primaryEmailVerified: true,
        isAnonymous: false,
        isRestricted: false,
      },
      {
        db: {} as never,
        stackApp: {
          getUser: async () => ({
            id: "anonymous-1",
            isAnonymous: true,
            primaryEmail: null,
            clientReadOnlyMetadata: {},
            update: mock(async () => undefined),
          }),
        } as never,
        ownershipRepository: { findClaims, transferClaim },
        stripeClient: () => ({
          customers: {
            retrieve: async () => ({
              id: "cus-1",
              deleted: false,
              email: transfer.email,
              metadata: {},
            }),
            update: customerUpdate,
          },
          subscriptions: {
            retrieve: async () => ({
              id: "sub-1",
              customer: "cus-1",
              metadata: {},
            }),
            update: subscriptionUpdate,
          },
        }) as never,
      },
    );

    expect(result).toEqual({ claimed: 1 });
    expect(findClaims).toHaveBeenCalledWith("billingfixture@gmail.com", "target-1");
    expect(transferClaim).toHaveBeenCalledTimes(1);
    expect(customerUpdate).toHaveBeenCalledWith("cus-1", {
      metadata: { app: "cmux", plan: "pro", stackUserId: "target-1" },
    });
    expect(subscriptionUpdate).toHaveBeenCalledWith("sub-1", {
      metadata: { app: "cmux", plan: "pro", stackUserId: "target-1" },
    });
  });

  test("does not resolve claims from an unverified email", async () => {
    const findClaims = mock(async () => []);
    const result = await claimPendingProBilling(
      {
        id: "target-1",
        primaryEmail: "buyer@example.com",
        primaryEmailVerified: false,
        isAnonymous: false,
      },
      {
        db: {} as never,
        stackApp: { getUser: async () => null } as never,
        ownershipRepository: {
          findClaims,
          transferClaim: async () => null,
        },
      },
    );

    expect(result).toEqual({ claimed: 0 });
    expect(findClaims).not.toHaveBeenCalled();
  });
});
