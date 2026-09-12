import { describe, expect, test } from "bun:test";

import {
  listTeamAccounts,
  removeTeamAccount,
  type TeamAccountsDependencies,
  type VaultAccess,
} from "../services/coderouter/teamAccounts";

const vault: VaultAccess = {
  kind: "session",
  accessToken: "stack-access",
  team: {
    teamId: "team_1",
    teamName: "Team",
    use: true,
    manageAccounts: true,
  },
};

const nativeAccount = {
  id: "00000000-0000-4000-8000-000000000001",
  provider: "codex" as const,
  providerAccountId: "acct-1",
  label: "codex@example.com",
  state: "active" as const,
  credentialExpiresAt: null,
  lastFailureCode: null,
  cooldownUntil: null,
  activeSessions: 2,
};

const claudeAccount = {
  id: "00000000-0000-4000-8000-000000000002",
  kind: "anthropic_oauth" as const,
  label: "",
  identifier: "sk-ant-oat01-...6789",
  region: null,
  modelIds: {},
  state: "active" as const,
  cooldownUntil: null,
  lastFailureCode: null,
  lastUsedAt: null,
  createdAt: "2026-09-01T00:00:00.000Z",
  updatedAt: "2026-09-01T00:00:00.000Z",
};

const sharedAccount = { id: "shared@example.com", kind: "codex", label: "shared@example.com" };

function dependencies(
  overrides: Partial<TeamAccountsDependencies> = {},
): TeamAccountsDependencies {
  return {
    nativeAccounts: async () => ({
      accounts: [nativeAccount],
      usageAsOf: "2026-09-08T00:00:00.000Z",
      usageGeneratedAtMs: Date.parse("2026-09-08T00:00:00.000Z"),
      cacheMaxAgeSeconds: 0,
      timing: { rdsMs: 1, providerMs: 2, totalMs: 3 },
    }),
    claudeAccounts: async () => [claudeAccount],
    vaultReady: async () => true,
    vaultClient: () =>
      ({
        tenantControlConfigured: true,
        exchangeTeam: async () => ({
          tenantId: "team_1",
          tenantName: "Team",
          tenantKey: "tenant-key",
          proxyUrl: "https://example.invalid",
          capabilities: ["use", "manage_accounts"],
        }),
        listAccounts: async () => [sharedAccount],
      }) as never,
    ...overrides,
  };
}

describe("team account listing", () => {
  test("returns every store's accounts in one read", async () => {
    const result = await listTeamAccounts({ teamId: "team_1", vault }, dependencies());
    expect(result.accounts.map((account) => account.source)).toEqual([
      "native",
      "claude",
      "shared",
    ]);
    expect(result.accounts.map((account) => account.label)).toEqual([
      "codex@example.com",
      "sk-ant-oat01-...6789",
      "shared@example.com",
    ]);
    expect(result.sources).toEqual({
      native: { kind: "ok", count: 1 },
      claude: { kind: "ok", count: 1 },
      shared: { kind: "ok", count: 1 },
    });
  });

  test("only accounts the data plane can select are routable", async () => {
    const result = await listTeamAccounts({ teamId: "team_1", vault }, dependencies());
    expect(result.accounts.filter((account) => account.routable).length).toBe(2);
    expect(
      result.accounts.find((account) => account.source === "shared")?.provider,
    ).toBe("shared");
    expect(
      result.accounts.find((account) => account.source === "shared")?.routable,
    ).toBe(false);
  });

  test("reads the three stores concurrently", async () => {
    // Each read blocks until all three have started. A sequential
    // implementation never reaches the third and this test times out.
    let started = 0;
    let release = () => {};
    const allStarted = new Promise<void>((resolve) => {
      release = resolve;
    });
    const gate = async () => {
      started += 1;
      if (started === 3) release();
      await allStarted;
    };
    const deps = dependencies({
      nativeAccounts: async () => {
        await gate();
        return {
          accounts: [],
          usageAsOf: "2026-09-08T00:00:00.000Z",
          usageGeneratedAtMs: 0,
          cacheMaxAgeSeconds: 0,
          timing: { rdsMs: 0, providerMs: 0, totalMs: 0 },
        };
      },
      claudeAccounts: async () => {
        await gate();
        return [];
      },
      vaultReady: async () => {
        await gate();
        return true;
      },
    });
    await listTeamAccounts({ teamId: "team_1", vault }, deps);
    expect(started).toBe(3);
  });

  test("one failing store never hides the others", async () => {
    const result = await listTeamAccounts(
      { teamId: "team_1", vault },
      dependencies({
        claudeAccounts: async () => {
          throw new Error("claude table unavailable");
        },
      }),
    );
    expect(result.accounts.map((account) => account.source)).toEqual([
      "native",
      "shared",
    ]);
    expect(result.sources.claude).toEqual({ kind: "error" });
  });

  test("a caller without a Stack session reports the vault as unreadable", async () => {
    const result = await listTeamAccounts(
      { teamId: "team_1", vault: { kind: "none" } },
      dependencies(),
    );
    expect(result.sources.shared).toEqual({
      kind: "unavailable",
      reason: "no_session",
    });
    expect(result.accounts.map((account) => account.source)).toEqual([
      "native",
      "claude",
    ]);
  });
});

describe("team account removal", () => {
  const removeNothing = {
    removeNative: async () => ({
      removed: false,
      lastAccount: false,
      legacyCleanupPending: false,
    }),
    removeClaude: async () => ({ removed: false }),
  };

  test("falls through to the Claude store when the native store has no such id", async () => {
    const result = await removeTeamAccount({
      teamId: "team_1",
      accountId: claudeAccount.id,
      vault,
      ...removeNothing,
      removeClaude: async () => ({ removed: true }),
    });
    expect(result).toEqual({
      removed: true,
      source: "claude",
      lastAccount: false,
      legacyCleanupPending: false,
    });
  });

  test("removes a vault account by its non-UUID id without touching the tables", async () => {
    let deleted: string | undefined;
    let nativeCalls = 0;
    const result = await removeTeamAccount({
      teamId: "team_1",
      accountId: sharedAccount.id,
      vault,
      vaultClient: () =>
        ({
          tenantControlConfigured: true,
          exchangeTeam: async () => ({
            tenantId: "team_1",
            tenantName: "Team",
            tenantKey: "tenant-key",
            proxyUrl: "https://example.invalid",
            capabilities: ["use", "manage_accounts"],
          }),
          deleteAccount: async (_tenantKey: string, accountId: string) => {
            deleted = accountId;
          },
        }) as never,
      removeNative: async () => {
        nativeCalls += 1;
        return { removed: false, lastAccount: false, legacyCleanupPending: false };
      },
      removeClaude: async () => ({ removed: false }),
    });
    expect(deleted).toBe(sharedAccount.id);
    expect(nativeCalls).toBe(0);
    expect(result).toEqual({
      removed: true,
      source: "shared",
      lastAccount: false,
      legacyCleanupPending: false,
    });
  });

  test("reports a miss instead of guessing a store", async () => {
    const result = await removeTeamAccount({
      teamId: "team_1",
      accountId: "00000000-0000-4000-8000-000000000009",
      vault,
      ...removeNothing,
    });
    expect(result).toEqual({ removed: false });
  });
});

describe("team account removal misses", () => {
  test("an id the vault does not hold is a miss, not an outage", async () => {
    const { HostedSubrouterError } = await import("../services/subrouter/hostedClient");
    const result = await removeTeamAccount({
      teamId: "team_1",
      accountId: "gone@example.com",
      vault,
      vaultClient: () =>
        ({
          tenantControlConfigured: true,
          exchangeTeam: async () => ({
            tenantId: "team_1",
            tenantName: "Team",
            tenantKey: "tenant-key",
            proxyUrl: "https://example.invalid",
            capabilities: ["use", "manage_accounts"],
          }),
          deleteAccount: async () => {
            throw new HostedSubrouterError("account not found", 404);
          },
        }) as never,
      removeNative: async () => ({
        removed: false,
        lastAccount: false,
        legacyCleanupPending: false,
      }),
      removeClaude: async () => ({ removed: false }),
    });
    expect(result).toEqual({ removed: false });
  });
});
