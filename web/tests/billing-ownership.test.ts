import { describe, expect, mock, test } from "bun:test";

import {
  claimPendingProBilling,
  type BillingOwnershipTransfer,
} from "../services/billing/purchase";
import {
  billingEmailClaims,
  stripeCustomers,
  stripeSubscriptions,
} from "../db/schema";

const targetUser = {
  id: "user-verified",
  primaryEmail: "Buyer@Example.com",
  primaryEmailVerified: true,
  isAnonymous: false,
  isRestricted: false,
};

const claim = {
  id: "claim-1",
  email: "buyer@example.com",
  stripeCustomerId: "cus-1",
  stackUserId: "anonymous-1",
  claimedByUserId: null,
};
type TestClaim = Omit<typeof claim, "claimedByUserId"> & {
  claimedByUserId: string | null;
};

const transfer: BillingOwnershipTransfer = {
  kind: "claimed",
  claimId: claim.id,
  email: claim.email,
  customerId: claim.stripeCustomerId,
  subscriptionIds: ["sub-1"],
  sourceStackUserId: claim.stackUserId,
  targetStackUserId: targetUser.id,
};

function dependencies(options: {
  claims?: readonly TestClaim[];
  transfer?: BillingOwnershipTransfer | null;
  source?: unknown;
} = {}) {
  const findClaims = mock(async () => options.claims ?? [claim]);
  const transferClaim = mock(async () =>
    options.transfer === undefined ? transfer : options.transfer,
  );
  const getUser = mock(async () =>
    options.source ?? { id: claim.stackUserId, isAnonymous: true },
  );
  const customerUpdate = mock(async () => ({}));
  const subscriptionUpdate = mock(async () => ({}));
  return {
    dependencyValue: {
      db: {} as never,
      stackApp: { getUser },
      ownershipRepository: { findClaims, transferClaim },
      stripeClient: () => ({
        customers: {
          retrieve: async () => ({
            id: claim.stripeCustomerId,
            deleted: false,
            email: claim.email,
            metadata: {},
          }),
          update: customerUpdate,
        },
        subscriptions: {
          retrieve: async () => ({
            id: "sub-1",
            customer: claim.stripeCustomerId,
            metadata: { app: "cmux", plan: "pro" },
          }),
          update: subscriptionUpdate,
        },
      }),
    } as never,
    findClaims,
    transferClaim,
    getUser,
    customerUpdate,
    subscriptionUpdate,
  };
}

describe("verified Pro billing ownership claims", () => {
  test("moves an anonymous paid checkout to the verified Stack account", async () => {
    const deps = dependencies();

    await expect(
      claimPendingProBilling(targetUser, deps.dependencyValue),
    ).resolves.toEqual({ claimed: 1 });

    expect(deps.findClaims).toHaveBeenCalledWith(
      "buyer@example.com",
      targetUser.id,
    );
    expect(deps.getUser).toHaveBeenCalledWith(claim.stackUserId);
    expect(deps.transferClaim).toHaveBeenCalledWith(claim, targetUser.id);
    expect(deps.customerUpdate).toHaveBeenCalledWith(claim.stripeCustomerId, {
      metadata: { app: "cmux", stackUserId: targetUser.id },
    });
    expect(deps.subscriptionUpdate).toHaveBeenCalledWith("sub-1", {
      metadata: { app: "cmux", plan: "pro", stackUserId: targetUser.id },
    });
  });

  test("does not use an unverified email as billing ownership proof", async () => {
    const deps = dependencies();

    await expect(
      claimPendingProBilling(
        { ...targetUser, primaryEmailVerified: false },
        deps.dependencyValue,
      ),
    ).resolves.toEqual({ claimed: 0 });

    expect(deps.findClaims).not.toHaveBeenCalled();
    expect(deps.transferClaim).not.toHaveBeenCalled();
  });

  test("does not transfer a claim originating from a non-anonymous account", async () => {
    const deps = dependencies({ source: { id: claim.stackUserId, isAnonymous: false } });

    await expect(
      claimPendingProBilling(targetUser, deps.dependencyValue),
    ).resolves.toEqual({ claimed: 0 });

    expect(deps.transferClaim).not.toHaveBeenCalled();
    expect(deps.customerUpdate).not.toHaveBeenCalled();
  });

  test("does not grant Pro when the parked claim has no live subscription", async () => {
    const deps = dependencies({ transfer: null });

    await expect(
      claimPendingProBilling(targetUser, deps.dependencyValue),
    ).resolves.toEqual({ claimed: 0 });

    expect(deps.transferClaim).toHaveBeenCalledTimes(1);
    expect(deps.customerUpdate).not.toHaveBeenCalled();
  });

  test("does not replay an already-claimed billing row", async () => {
    const deps = dependencies({
      claims: [{ ...claim, claimedByUserId: targetUser.id }],
    });

    await expect(
      claimPendingProBilling(targetUser, deps.dependencyValue),
    ).resolves.toEqual({ claimed: 0 });

    expect(deps.transferClaim).not.toHaveBeenCalled();
    expect(deps.customerUpdate).not.toHaveBeenCalled();
  });

  test("transfers the exact customer and subscription rows atomically", async () => {
    const selectResults: unknown[][] = [
      [claim], // pending claims
      [claim], // locked claim re-read
      [], // source tombstone
      [], // target tombstone
      [], // target customer
      [{ id: claim.stripeCustomerId }], // source customer
      [{ id: "sub-1", status: "active" }], // source subscription
      [], // target subscriptions
    ];
    const updates: Array<{ table: unknown; values: Record<string, unknown> }> = [];
    const client = {
      select: () => ({
        from: () => ({
          where: () => {
            const result = {
              orderBy: () => result,
              limit: async () => selectResults.shift() ?? [],
            };
            return result;
          },
        }),
      }),
      update: (table: unknown) => ({
        set: (values: Record<string, unknown>) => ({
          where: async () => {
            updates.push({ table, values });
          },
        }),
      }),
      execute: async () => undefined,
    };
    const db = {
      ...client,
      transaction: async <Result>(operation: (tx: typeof client) => Promise<Result>) =>
        operation(client),
    };
    const deps = dependencies();
    const dependencyRecord = deps.dependencyValue as {
      stackApp: unknown;
      stripeClient: unknown;
    };
    const productionDeps = {
      db: db as never,
      stackApp: dependencyRecord.stackApp,
      stripeClient: dependencyRecord.stripeClient,
    } as never;

    await expect(
      claimPendingProBilling(targetUser, productionDeps),
    ).resolves.toEqual({ claimed: 1 });

    expect(
      updates.some(
        (entry) =>
          entry.table === stripeCustomers &&
          entry.values.stackUserId === targetUser.id,
      ),
    ).toBe(true);
    expect(
      updates.some(
        (entry) =>
          entry.table === stripeSubscriptions &&
          entry.values.stackUserId === targetUser.id,
      ),
    ).toBe(true);
    expect(
      updates.some(
        (entry) =>
          entry.table === billingEmailClaims &&
          entry.values.claimedByUserId === targetUser.id,
      ),
    ).toBe(true);
  });
});
