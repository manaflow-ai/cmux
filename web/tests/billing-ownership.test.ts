import { describe, expect, mock, test } from "bun:test";

import {
  accountDeletionTombstones,
  accountMutationLeases,
  stripeSubscriptions,
} from "../db/schema";
import { claimPendingProBilling } from "../services/billing/purchase";

function metadataDb(founderRows: readonly unknown[] = []) {
  let operationId: string | null = null;
  const select = () => ({
    from: (table: unknown) => ({
      where: () => ({
        limit: async () => {
          if (table === accountMutationLeases && operationId) {
            return [{ operationId }];
          }
          if (table === accountDeletionTombstones) return [];
          if (table === stripeSubscriptions) return founderRows;
          return [];
        },
      }),
    }),
  });
  const tx = {
    execute: async () => undefined,
    select,
    delete: () => ({
      where: async () => {
        operationId = null;
      },
    }),
    insert: () => ({
      values: async (values: { operationId?: string }) => {
        operationId = values.operationId ?? null;
      },
    }),
    update: () => ({ set: () => ({ where: async () => undefined }) }),
  };
  return {
    ...tx,
    transaction: async <T>(callback: (transaction: typeof tx) => Promise<T>) =>
      await callback(tx),
  };
}

describe("billing email claim resolution", () => {
  test("consumes a claim when the anonymous source was promoted in place", async () => {
    const transfer = {
      kind: "claimed" as const,
      claimId: "claim-promoted-in-place",
      email: "billingfixture@example.com",
      customerId: "cus-promoted-in-place",
      subscriptionIds: ["sub-promoted-in-place"],
      sourceStackUserId: "promoted-user",
      targetStackUserId: "promoted-user",
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

    const result = await claimPendingProBilling(
      {
        id: transfer.targetStackUserId,
        primaryEmail: transfer.email,
        primaryEmailVerified: true,
        isAnonymous: false,
        isRestricted: false,
      },
      {
        db: metadataDb() as never,
        stackApp: {
          getUser: async () => ({
            id: transfer.sourceStackUserId,
            isAnonymous: false,
            primaryEmail: transfer.email,
            primaryEmailVerified: true,
            clientReadOnlyMetadata: {},
            update: mock(async () => undefined),
          }),
        } as never,
        ownershipRepository: { findClaims, transferClaim },
        stripeClient: () => ({
          customers: {
            retrieve: async () => ({
              id: transfer.customerId,
              deleted: false,
              email: transfer.email,
              metadata: {},
            }),
            update: async () => undefined,
          },
          subscriptions: {
            retrieve: async () => ({
              id: transfer.subscriptionIds[0],
              customer: transfer.customerId,
              metadata: {},
            }),
            update: async () => undefined,
          },
        }) as never,
      },
    );

    expect(result).toEqual({ claimed: 1 });
    expect(findClaims).toHaveBeenCalledWith(transfer.email, transfer.targetStackUserId);
    expect(transferClaim).toHaveBeenCalledTimes(1);
  });

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
    const targetUpdate = mock(async () => undefined);

    const result = await claimPendingProBilling(
      {
        id: "target-1",
        primaryEmail: "Billing.Fixture@Gmail.com",
        primaryEmailVerified: true,
        isAnonymous: false,
        isRestricted: false,
      },
      {
        db: metadataDb() as never,
        stackApp: {
          getUser: async (id: string) =>
            id === "target-1"
              ? {
                  id: "target-1",
                  isAnonymous: false,
                  isRestricted: false,
                  primaryEmail: "Billing.Fixture@Gmail.com",
                  primaryEmailVerified: true,
                  clientReadOnlyMetadata: {},
                  update: targetUpdate,
                }
              : {
                  id: "anonymous-1",
                  isAnonymous: true,
                  primaryEmail: null,
                  clientReadOnlyMetadata: {},
                  update: mock(async () => undefined),
                },
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
    expect(targetUpdate).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("enrolls a Founder claimant only after verification", async () => {
    const transfer = {
      kind: "claimed" as const,
      claimId: "founder-claim",
      email: "founder@example.com",
      customerId: "cus-founder",
      subscriptionIds: ["sub-founder"],
      founderSubscriptionIds: ["sub-founder"],
      sourceStackUserId: "anonymous-founder",
      targetStackUserId: "verified-founder",
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
    const enroll = mock(async () => undefined);
    const targetUpdate = mock(async () => undefined);

    const result = await claimPendingProBilling(
      {
        id: transfer.targetStackUserId,
        primaryEmail: transfer.email,
        primaryEmailVerified: true,
        isAnonymous: false,
        isRestricted: false,
      },
      {
        db: metadataDb() as never,
        stackApp: {
          getUser: async (id: string) =>
            id === transfer.targetStackUserId
              ? {
                  id,
                  isAnonymous: false,
                  isRestricted: false,
                  primaryEmail: transfer.email,
                  primaryEmailVerified: true,
                  clientReadOnlyMetadata: {},
                  update: targetUpdate,
                }
              : {
                  id,
                  isAnonymous: true,
                  primaryEmail: null,
                  primaryEmailVerified: false,
                  clientReadOnlyMetadata: {},
                  update: mock(async () => undefined),
                },
        } as never,
        ownershipRepository: { findClaims, transferClaim },
        testflight: { enrollTester: enroll },
        stripeClient: () => ({
          customers: {
            retrieve: async () => ({
              id: transfer.customerId,
              deleted: false,
              email: transfer.email,
              metadata: {},
            }),
            update: async () => undefined,
          },
          subscriptions: {
            retrieve: async () => ({
              id: transfer.subscriptionIds[0],
              customer: transfer.customerId,
              metadata: {},
            }),
            update: async () => undefined,
          },
        }) as never,
      },
    );

    expect(result).toEqual({ claimed: 1 });
    expect(enroll).toHaveBeenCalledWith("founder@example.com", undefined, undefined);
  });

  test("retries Founder enrollment from the durable row after a consumed claim", async () => {
    const enroll = mock(async () => undefined);
    const targetUpdate = mock(async () => undefined);
    const findClaims = mock(async () => []);

    const result = await claimPendingProBilling(
      {
        id: "verified-founder",
        primaryEmail: "founder@example.com",
        primaryEmailVerified: true,
        isAnonymous: false,
        isRestricted: false,
      },
      {
        db: metadataDb([
          { raw: { metadata: { founders_edition: "true" } } },
        ]) as never,
        stackApp: {
          getUser: async () => ({
            id: "verified-founder",
            primaryEmail: "founder@example.com",
            primaryEmailVerified: true,
            isAnonymous: false,
            isRestricted: false,
            clientReadOnlyMetadata: {},
            update: targetUpdate,
          }),
        } as never,
        ownershipRepository: {
          findClaims,
          transferClaim: async () => null,
        },
        testflight: { enrollTester: enroll },
      },
    );

    expect(result).toEqual({ claimed: 0 });
    expect(targetUpdate).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
    expect(enroll).toHaveBeenCalledWith("founder@example.com", undefined, undefined);
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

  test("does not transfer a claim whose email mismatches the verified account", async () => {
    const transferClaim = mock(async () => ({
      kind: "claimed" as const,
      claimId: "claim-mismatch",
      email: "other@example.com",
      customerId: "cus-mismatch",
      subscriptionIds: ["sub-mismatch"],
      sourceStackUserId: "anonymous-mismatch",
      targetStackUserId: "verified-target",
    }));

    const result = await claimPendingProBilling(
      {
        id: "verified-target",
        primaryEmail: "verified@example.com",
        primaryEmailVerified: true,
        isAnonymous: false,
        isRestricted: false,
      },
      {
        db: metadataDb() as never,
        stackApp: {
          getUser: async () => ({
            id: "anonymous-mismatch",
            isAnonymous: true,
            primaryEmail: null,
            clientReadOnlyMetadata: {},
            update: mock(async () => undefined),
          }),
        } as never,
        ownershipRepository: {
          findClaims: mock(async () => [{
            id: "claim-mismatch",
            email: "other@example.com",
            stripeCustomerId: "cus-mismatch",
            stackUserId: "anonymous-mismatch",
            claimedByUserId: null,
          }]),
          transferClaim,
        },
      },
    );

    expect(result).toEqual({ claimed: 0 });
    expect(transferClaim).not.toHaveBeenCalled();
  });

  test("redeems a claim only once when the sign-in callback is retried", async () => {
    let claimedByUserId: string | null = null;
    const transfer = {
      kind: "claimed" as const,
      claimId: "claim-retry",
      email: "retry@example.com",
      customerId: "cus-retry",
      subscriptionIds: ["sub-retry"],
      sourceStackUserId: "anonymous-retry",
      targetStackUserId: "verified-retry",
    };
    const findClaims = mock(async () => [{
      id: transfer.claimId,
      email: transfer.email,
      stripeCustomerId: transfer.customerId,
      stackUserId: transfer.sourceStackUserId,
      claimedByUserId,
    }]);
    const transferClaim = mock(async () => {
      if (claimedByUserId) return null;
      claimedByUserId = transfer.targetStackUserId;
      return transfer;
    });
    const dependencies = {
      db: metadataDb() as never,
      stackApp: {
        getUser: async (id: string) => id === transfer.targetStackUserId
          ? {
              id,
              isAnonymous: false,
              primaryEmail: transfer.email,
              primaryEmailVerified: true,
              clientReadOnlyMetadata: {},
              update: mock(async () => undefined),
            }
          : {
              id: transfer.sourceStackUserId,
              isAnonymous: true,
              primaryEmail: null,
              clientReadOnlyMetadata: {},
              update: mock(async () => undefined),
            },
      } as never,
      ownershipRepository: { findClaims, transferClaim },
    };
    const user = {
      id: transfer.targetStackUserId,
      primaryEmail: transfer.email,
      primaryEmailVerified: true,
      isAnonymous: false,
      isRestricted: false,
    };

    await expect(claimPendingProBilling(user, dependencies)).resolves.toEqual({
      claimed: 1,
    });
    await expect(claimPendingProBilling(user, dependencies)).resolves.toEqual({
      claimed: 0,
    });

    expect(transferClaim).toHaveBeenCalledTimes(1);
  });
});
