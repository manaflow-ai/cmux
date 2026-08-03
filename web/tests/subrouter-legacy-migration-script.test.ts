import { describe, expect, test } from "bun:test";

import { runLegacyTenantMigration } from "../scripts/subrouter/migrate-legacy-tenants";

const mappings = [
  { teamId: "team-b", tenantId: "legacy-b", tenantName: "Team B" },
  { teamId: "team-a", tenantId: "legacy-a", tenantName: "Team A" },
];

describe("legacy Subrouter migration operator", () => {
  test("requires apply before source finalization", async () => {
    await expect(runLegacyTenantMigration({
      mappings,
      apply: false,
      finalizeSource: true,
      destinationUrl: "https://sr.cmux.com",
      openStackSession: async () => {
        throw new Error("unexpected session");
      },
      exchangeHostedTenant: async () => {
        throw new Error("unexpected exchange");
      },
      migrateLegacyTenant: async () => {
        throw new Error("unexpected migration");
      },
      markHostedReady: async () => {
        throw new Error("unexpected readiness mutation");
      },
      log: () => {},
    })).rejects.toThrow("--finalize-source requires --apply");
  });

  test("dry-run reports database mappings without minting sessions or mutating either service", async () => {
    let sessionsOpened = 0;
    let exchanges = 0;
    let migrations = 0;
    let readinessMutations = 0;
    const logged: unknown[] = [];

    await expect(runLegacyTenantMigration({
      mappings,
      apply: false,
      finalizeSource: false,
      destinationUrl: "https://sr.cmux.com",
      openStackSession: async () => {
        sessionsOpened += 1;
        throw new Error("unexpected session");
      },
      exchangeHostedTenant: async () => {
        exchanges += 1;
        throw new Error("unexpected exchange");
      },
      migrateLegacyTenant: async () => {
        migrations += 1;
        throw new Error("unexpected migration");
      },
      markHostedReady: async () => {
        readinessMutations += 1;
      },
      log: (value) => logged.push(value),
    })).resolves.toEqual({ planned: 2, migrated: 0, sourceFinalized: false });

    expect(sessionsOpened).toBe(0);
    expect(exchanges).toBe(0);
    expect(migrations).toBe(0);
    expect(readinessMutations).toBe(0);
    expect(logged).toEqual([{
      mode: "dry-run",
      destinationUrl: "https://sr.cmux.com",
      tenants: [
        { teamId: "team-a", legacyTenantId: "legacy-a" },
        { teamId: "team-b", legacyTenantId: "legacy-b" },
      ],
    }]);
  });

  test("pre-copy keeps hosted cutover closed until the source is finalized", async () => {
    const readyTeamIds: string[] = [];

    await expect(runLegacyTenantMigration({
      mappings: [mappings[0]!],
      apply: true,
      finalizeSource: false,
      destinationUrl: "https://sr.cmux.com",
      openStackSession: async () => ({
        accessToken: "access-secret",
        close: async () => {},
      }),
      exchangeHostedTenant: async () => ({
        tenantId: "team-b",
        tenantKey: "srt_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      }),
      migrateLegacyTenant: async () => ({
        migrated: 4,
        sourceFinalized: false,
      }),
      markHostedReady: async (teamId) => {
        readyTeamIds.push(teamId);
      },
      log: () => {},
    })).resolves.toEqual({ planned: 1, migrated: 4, sourceFinalized: false });

    expect(readyTeamIds).toEqual([]);
  });

  test("applies mappings by immutable ids and always closes impersonation sessions", async () => {
    const openedTeamIds: string[] = [];
    const closedTeamIds: string[] = [];
    const migrationInputs: unknown[] = [];
    const openStackSession = async (mapping: (typeof mappings)[number]) => {
      openedTeamIds.push(mapping.teamId);
      return {
      accessToken: `access-${mapping.teamId}`,
        close: async () => {
          closedTeamIds.push(mapping.teamId);
        },
      };
    };
    const exchangeHostedTenant = async (input: {
      readonly teamId: string;
      readonly accessToken: string;
    }) => ({
      tenantId: input.teamId,
      tenantKey: input.teamId === "team-a"
        ? "srt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        : "srt_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    });
    const migrateLegacyTenant = async (input: {
      readonly legacyTenantId: string;
      readonly finalizeSource: boolean;
    }) => {
      migrationInputs.push(input);
      return {
      migrated: input.legacyTenantId === "legacy-a" ? 2 : 4,
      sourceFinalized: input.finalizeSource,
      };
    };
    const logged: unknown[] = [];
    const readyTeamIds: string[] = [];

    await expect(runLegacyTenantMigration({
      mappings,
      apply: true,
      finalizeSource: true,
      destinationUrl: "https://sr.cmux.com",
      openStackSession,
      exchangeHostedTenant,
      migrateLegacyTenant,
      markHostedReady: async (teamId) => {
        readyTeamIds.push(teamId);
      },
      log: (value) => logged.push(value),
    })).resolves.toEqual({ planned: 2, migrated: 6, sourceFinalized: true });

    expect(openedTeamIds).toEqual([
      "team-a",
      "team-b",
    ]);
    expect(migrationInputs[0]).toEqual({
      legacyTenantId: "legacy-a",
      destinationUrl: "https://sr.cmux.com",
      tenantKey: "srt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      finalizeSource: true,
    });
    expect(closedTeamIds).toEqual(["team-a", "team-b"]);
    expect(readyTeamIds).toEqual(["team-a", "team-b"]);
    expect(JSON.stringify(logged)).not.toContain("srt_");
    expect(JSON.stringify(logged)).not.toContain("access-");
  });

  test("closes the current session before stopping after a migration failure", async () => {
    let closeCount = 0;
    let readinessMutations = 0;

    await expect(runLegacyTenantMigration({
      mappings: [mappings[0]!],
      apply: true,
      finalizeSource: false,
      destinationUrl: "https://sr.cmux.com",
      openStackSession: async () => ({
        accessToken: "access-secret",
        close: async () => {
          closeCount += 1;
        },
      }),
      exchangeHostedTenant: async () => ({
        tenantId: "team-b",
        tenantKey: "srt_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      }),
      migrateLegacyTenant: async () => {
        throw new Error("source migration failed");
      },
      markHostedReady: async () => {
        readinessMutations += 1;
      },
      log: () => {},
    })).rejects.toThrow("source migration failed");

    expect(closeCount).toBe(1);
    expect(readinessMutations).toBe(0);
  });
});
