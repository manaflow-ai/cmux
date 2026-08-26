import { afterAll, describe, expect, test } from "bun:test";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { closeCloudDbForTests } from "../db/client";
import {
  compareSchemaParity,
  listBundledMigrations,
  bundledMigrationHashes,
  migrationFolderMillis,
  type AppliedMigrationRow,
} from "../services/health/schemaParity";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

const MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "db", "migrations");

function row(overrides: Partial<AppliedMigrationRow>): AppliedMigrationRow {
  return { name: null, hash: null, createdAt: null, ...overrides };
}

afterAll(async () => {
  await closeCloudDbForTests();
});

describe("compareSchemaParity", () => {
  const code = [
    "20260818090000_coderouter_session_accounts",
    "20260820050000_blaxel_vm_provider",
    "20260823010000_cloud_vm_display_name",
    "20260824010000_cloud_vm_preview_leases",
  ];

  test("ok when db head equals code head", () => {
    const report = compareSchemaParity(code, code.map((name) => row({ name })));
    expect(report).toEqual({
      status: "ok",
      codeHead: "20260824010000_cloud_vm_preview_leases",
      dbHead: "20260824010000_cloud_vm_preview_leases",
      pending: [],
    });
  });

  test("behind when the db lags, listing pending migrations oldest first", () => {
    const report = compareSchemaParity(code, [row({ name: code[0]! })]);
    expect(report.status).toBe("behind");
    expect(report.codeHead).toBe("20260824010000_cloud_vm_preview_leases");
    expect(report.dbHead).toBe("20260818090000_coderouter_session_accounts");
    expect(report.pending).toEqual([
      "20260820050000_blaxel_vm_provider",
      "20260823010000_cloud_vm_display_name",
      "20260824010000_cloud_vm_preview_leases",
    ]);
  });

  test("behind with everything pending against an unmigrated database", () => {
    const report = compareSchemaParity(code, []);
    expect(report.status).toBe("behind");
    expect(report.dbHead).toBeNull();
    expect(report.pending).toEqual(code);
  });

  test("ahead when the db has migrations this build does not bundle", () => {
    const report = compareSchemaParity(code.slice(0, 3), code.map((name) => row({ name })));
    expect(report.status).toBe("ahead");
    expect(report.codeHead).toBe("20260823010000_cloud_vm_display_name");
    expect(report.dbHead).toBe("20260824010000_cloud_vm_preview_leases");
    expect(report.pending).toEqual([]);
  });

  test("resolves legacy nameless rows by folder-timestamp millis", () => {
    // 20260820050000 -> 2026-08-20T05:00:00Z; drizzle stores millis in created_at.
    const millis = migrationFolderMillis("20260820050000_blaxel_vm_provider")!;
    const report = compareSchemaParity(code.slice(0, 2), [
      row({ name: code[0]! }),
      row({ createdAt: String(millis) }),
    ]);
    expect(report.status).toBe("ok");
    expect(report.dbHead).toBe("20260820050000_blaxel_vm_provider");
  });

  test("disambiguates same-timestamp legacy rows by hash, like drizzle's upgrader", () => {
    // The real corpus has such a pair: 20260804030000_account_deletion_legacy_progress
    // and 20260804030000_iroh_scoped_discovery_indexes.
    const twins = ["20260804030000_alpha", "20260804030000_beta"];
    const millis = migrationFolderMillis(twins[0]!)!;
    const hashes = new Map([
      ["20260804030000_alpha", "hash-alpha"],
      ["20260804030000_beta", "hash-beta"],
    ]);
    const report = compareSchemaParity(
      twins,
      [
        row({ createdAt: millis, hash: "hash-alpha" }),
        row({ createdAt: millis, hash: "hash-beta" }),
      ],
      hashes,
    );
    expect(report.status).toBe("ok");

    const partial = compareSchemaParity(twins, [row({ createdAt: millis, hash: "hash-alpha" })], hashes);
    expect(partial.status).toBe("behind");
    expect(partial.pending).toEqual(["20260804030000_beta"]);
  });

  test("an unmatchable legacy row never hides pending code migrations", () => {
    const report = compareSchemaParity(code, [
      ...code.map((name) => row({ name })),
      row({ createdAt: "1234567890000", hash: "unknown" }),
    ]);
    expect(report.status).toBe("ok");
  });
});

describe("bundled migrations", () => {
  test("lists the real migrations folder sorted with drizzle's naming shape", () => {
    const names = listBundledMigrations(MIGRATIONS_DIR);
    expect(names.length).toBeGreaterThanOrEqual(59);
    expect(names).toEqual([...names].sort((a, b) => a.localeCompare(b)));
    for (const name of names) {
      expect(name).toMatch(/^\d{14}_/);
      expect(migrationFolderMillis(name)).not.toBeNull();
    }
    // The three additive migrations that drifted from production in the
    // Aug 24/25 2026 outage are bundled.
    expect(names).toContain("20260820050000_blaxel_vm_provider");
    expect(names).toContain("20260823010000_cloud_vm_display_name");
    expect(names).toContain("20260824010000_cloud_vm_preview_leases");
  });

  test("hashes every bundled migration.sql", () => {
    const names = listBundledMigrations(MIGRATIONS_DIR);
    const hashes = bundledMigrationHashes(names, MIGRATIONS_DIR);
    expect(hashes.size).toBe(names.length);
    for (const hash of hashes.values()) {
      expect(hash).toMatch(/^[0-9a-f]{64}$/);
    }
  });

  test("folder millis decode as UTC", () => {
    expect(migrationFolderMillis("20260824010000_cloud_vm_preview_leases")).toBe(
      Date.UTC(2026, 7, 24, 1, 0, 0),
    );
    expect(migrationFolderMillis("not_a_timestamp")).toBeNull();
  });
});

describe("schema-parity route against a migrated database", () => {
  dbTest("reports ok with matching heads once migrations are applied", async () => {
    const { GET } = await import("../app/api/health/schema-parity/route");
    const response = await GET();
    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      status: string;
      codeHead: string | null;
      dbHead: string | null;
      pending: string[];
    };
    const codeHead = listBundledMigrations(MIGRATIONS_DIR).at(-1) ?? null;
    expect(body.status).toBe("ok");
    expect(body.codeHead).toBe(codeHead);
    expect(body.dbHead).toBe(codeHead);
    expect(body.pending).toEqual([]);
  });
});
