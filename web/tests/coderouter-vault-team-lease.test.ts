import { beforeEach, describe, expect, mock, test } from "bun:test";

// The legacy coderouter vault lives in the team's Stack serverMetadata next to
// operator keys (a VM deal's label and price, admin grant and change records).
// A vault write is a read-modify-write of that whole object, so it must hold
// the same team lease as the other team metadata writers and read the team
// inside it; otherwise a deal saved meanwhile is overwritten with a stale copy.

let leaseHeld = false;
const leasedReads: boolean[] = [];
const updates: Array<{ serverMetadata?: Record<string, unknown> }> = [];
const dealTerms = { planLabel: "Team (custom)", monthlyPriceCents: 80_000 };
const vault = {
  version: 1,
  accounts: {
    "account-1": {
      revision: 1,
      credential: {
        provider: "opencode-go",
        accessToken: "access",
        refreshToken: "refresh",
        accountId: "account-1",
        email: "person@example.com",
        expiresAt: 1,
      },
    },
  },
};

function team() {
  // A read outside the lease predates the admin's deal save; a read under
  // the lease sees it, because the admin save held the lease and committed.
  const leased = leaseHeld;
  leasedReads.push(leased);
  return {
    id: "team-1",
    serverMetadata: leased
      ? { coderouterVaultV1: vault, cmuxEntitlementDealTerms: dealTerms }
      : { coderouterVaultV1: vault },
    update: async (update: { serverMetadata?: Record<string, unknown> }) => {
      updates.push(update);
    },
  };
}

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getTeam: async () => team() }),
  isStackConfigured: () => true,
}));
mock.module("../db/client", () => ({ cloudDb: () => ({}) }));
mock.module("../services/teams/mutationLease", () => ({
  teamMutationKey: (teamId: string) => `team:${teamId}`,
  withTeamMetadataMutation: async (
    _db: unknown,
    _teamId: string,
    operation: (lease: { refresh: () => Promise<void> }) => Promise<unknown>,
  ) => {
    leaseHeld = true;
    try {
      return await operation({ refresh: async () => undefined });
    } finally {
      leaseHeld = false;
    }
  },
}));

const { clearTeamVault, deleteVaultCredential } = await import("../services/coderouter/vault");

beforeEach(() => {
  leaseHeld = false;
  leasedReads.length = 0;
  updates.length = 0;
});

describe("coderouter vault writes hold the team lease", () => {
  test("deleting a legacy credential keeps a deal saved meanwhile", async () => {
    await deleteVaultCredential("team-1", "account-1");

    expect(leasedReads.length).toBeGreaterThan(0);
    expect(leasedReads.every(Boolean)).toBe(true);
    expect(updates).toHaveLength(1);
    expect(updates[0]?.serverMetadata?.cmuxEntitlementDealTerms).toEqual(dealTerms);
    expect(updates[0]?.serverMetadata?.coderouterVaultV1).toEqual({ version: 1, accounts: {} });
  });

  test("clearing the vault keeps a deal saved meanwhile", async () => {
    await clearTeamVault("team-1");

    expect(leasedReads.every(Boolean)).toBe(true);
    expect(updates).toHaveLength(1);
    expect(updates[0]?.serverMetadata).toEqual({ cmuxEntitlementDealTerms: dealTerms });
  });
});
