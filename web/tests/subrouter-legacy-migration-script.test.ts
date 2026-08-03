import { describe, expect, mock, test } from "bun:test";

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
      openStackSession: mock(),
      exchangeHostedTenant: mock(),
      migrateLegacyTenant: mock(),
      log: mock(),
    })).rejects.toThrow("--finalize-source requires --apply");
  });

  test("dry-run reports database mappings without minting sessions or mutating either service", async () => {
    const openStackSession = mock();
    const exchangeHostedTenant = mock();
    const migrateLegacyTenant = mock();
    const log = mock();

    await expect(runLegacyTenantMigration({
      mappings,
      apply: false,
      finalizeSource: false,
      destinationUrl: "https://sr.cmux.com",
      openStackSession,
      exchangeHostedTenant,
      migrateLegacyTenant,
      log,
    })).resolves.toEqual({ planned: 2, migrated: 0, sourceFinalized: false });

    expect(openStackSession).not.toHaveBeenCalled();
    expect(exchangeHostedTenant).not.toHaveBeenCalled();
    expect(migrateLegacyTenant).not.toHaveBeenCalled();
    expect(log).toHaveBeenCalledWith({
      mode: "dry-run",
      destinationUrl: "https://sr.cmux.com",
      tenants: [
        { teamId: "team-a", legacyTenantId: "legacy-a" },
        { teamId: "team-b", legacyTenantId: "legacy-b" },
      ],
    });
  });

  test("applies mappings by immutable ids and always closes impersonation sessions", async () => {
    const closeA = mock(async () => {});
    const closeB = mock(async () => {});
    const openStackSession = mock(async (mapping: (typeof mappings)[number]) => ({
      accessToken: `access-${mapping.teamId}`,
      close: mapping.teamId === "team-a" ? closeA : closeB,
    }));
    const exchangeHostedTenant = mock(async (input: {
      readonly teamId: string;
      readonly accessToken: string;
    }) => ({
      tenantId: input.teamId,
      tenantKey: input.teamId === "team-a"
        ? "srt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        : "srt_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    }));
    const migrateLegacyTenant = mock(async (input: {
      readonly legacyTenantId: string;
      readonly finalizeSource: boolean;
    }) => ({
      migrated: input.legacyTenantId === "legacy-a" ? 2 : 4,
      sourceFinalized: input.finalizeSource,
    }));
    const logged: unknown[] = [];

    await expect(runLegacyTenantMigration({
      mappings,
      apply: true,
      finalizeSource: true,
      destinationUrl: "https://sr.cmux.com",
      openStackSession,
      exchangeHostedTenant,
      migrateLegacyTenant,
      log: (value) => logged.push(value),
    })).resolves.toEqual({ planned: 2, migrated: 6, sourceFinalized: true });

    expect(openStackSession.mock.calls.map(([mapping]) => mapping.teamId)).toEqual([
      "team-a",
      "team-b",
    ]);
    expect(migrateLegacyTenant).toHaveBeenNthCalledWith(1, {
      legacyTenantId: "legacy-a",
      destinationUrl: "https://sr.cmux.com",
      tenantKey: "srt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      finalizeSource: true,
    });
    expect(closeA).toHaveBeenCalledTimes(1);
    expect(closeB).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(logged)).not.toContain("srt_");
    expect(JSON.stringify(logged)).not.toContain("access-");
  });

  test("closes the current session before stopping after a migration failure", async () => {
    const close = mock(async () => {});
    const migrateLegacyTenant = mock(async () => {
      throw new Error("source migration failed");
    });

    await expect(runLegacyTenantMigration({
      mappings: [mappings[0]!],
      apply: true,
      finalizeSource: false,
      destinationUrl: "https://sr.cmux.com",
      openStackSession: mock(async () => ({ accessToken: "access-secret", close })),
      exchangeHostedTenant: mock(async () => ({
        tenantId: "team-b",
        tenantKey: "srt_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      })),
      migrateLegacyTenant,
      log: mock(),
    })).rejects.toThrow("source migration failed");

    expect(close).toHaveBeenCalledTimes(1);
  });
});
