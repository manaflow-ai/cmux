import { describe, expect, test } from "bun:test";

import {
  legacySubrouterRetirementConfigForTarget,
  runLegacyTenantMigration,
} from "../scripts/subrouter/migrate-legacy-tenants";

const mappings = [
  { teamId: "team-b", tenantId: "legacy-b", tenantName: "Team B" },
  { teamId: "team-a", tenantId: "legacy-a", tenantName: "Team A" },
];

describe("legacy Subrouter migration operator", () => {
  test("derives the legacy source from the explicit migration target", () => {
    expect(legacySubrouterRetirementConfigForTarget("production", {
      SUBROUTER_ADMIN_TOKEN: "production-admin",
    })).toEqual({
      baseUrl: "https://subrouter.cmux.dev",
      adminToken: "production-admin",
    });
    expect(legacySubrouterRetirementConfigForTarget("staging", {
      VERCEL_ENV: "production",
      SUBROUTER_ADMIN_TOKEN: "staging-admin",
    })).toEqual({
      baseUrl: "https://subrouter-staging.cmux.dev",
      adminToken: "staging-admin",
    });
  });

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
      markFinalizationStarted: async () => {
        throw new Error("unexpected finalization marker");
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
    let finalizationMarkers = 0;
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
      markFinalizationStarted: async () => {
        finalizationMarkers += 1;
      },
      markHostedReady: async () => {
        readinessMutations += 1;
      },
      log: (value) => logged.push(value),
    })).resolves.toEqual({ planned: 2, migrated: 0, sourceFinalized: false });

    expect(sessionsOpened).toBe(0);
    expect(exchanges).toBe(0);
    expect(migrations).toBe(0);
    expect(finalizationMarkers).toBe(0);
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
      markFinalizationStarted: async () => {
        throw new Error("pre-copy must not persist a finalization marker");
      },
      markHostedReady: async (teamId) => {
        readyTeamIds.push(teamId);
      },
      log: () => {},
    })).resolves.toEqual({ planned: 1, migrated: 4, sourceFinalized: false });

    expect(readyTeamIds).toEqual([]);
  });

  test("persists a resumable finalization before touching the legacy source", async () => {
    const operations: string[] = [];
    let readinessAttempts = 0;
    const migrationOptions = {
      mappings: [mappings[0]!],
      apply: true,
      finalizeSource: true,
      destinationUrl: "https://sr.cmux.com",
      openStackSession: async () => ({
        accessToken: "access-secret",
        close: async () => {},
      }),
      exchangeHostedTenant: async () => ({
        tenantId: "team-b",
        tenantKey: "srt_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      }),
      markFinalizationStarted: async () => {
        operations.push("finalization-started");
      },
      migrateLegacyTenant: async () => {
        operations.push("source-finalized");
        return { migrated: 4, sourceFinalized: true };
      },
      markHostedReady: async () => {
        operations.push("hosted-ready");
        readinessAttempts += 1;
        if (readinessAttempts === 1) throw new Error("readiness write failed");
      },
      log: () => {},
    };

    await expect(runLegacyTenantMigration(migrationOptions)).rejects.toThrow(
      "readiness write failed",
    );
    expect(operations).toEqual([
      "finalization-started",
      "source-finalized",
      "hosted-ready",
    ]);

    await expect(runLegacyTenantMigration(migrationOptions)).resolves.toEqual({
      planned: 1,
      migrated: 4,
      sourceFinalized: true,
    });
    expect(operations.slice(3)).toEqual([
      "finalization-started",
      "source-finalized",
      "hosted-ready",
    ]);
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
    const finalizingTeamIds: string[] = [];
    const readyTeamIds: string[] = [];

    await expect(runLegacyTenantMigration({
      mappings,
      apply: true,
      finalizeSource: true,
      destinationUrl: "https://sr.cmux.com",
      openStackSession,
      exchangeHostedTenant,
      migrateLegacyTenant,
      markFinalizationStarted: async (teamId) => {
        finalizingTeamIds.push(teamId);
      },
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
    expect(finalizingTeamIds).toEqual(["team-a", "team-b"]);
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
      markFinalizationStarted: async () => {
        throw new Error("pre-copy must not persist a finalization marker");
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
