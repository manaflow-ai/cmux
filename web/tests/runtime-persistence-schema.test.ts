import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { getTableConfig } from "drizzle-orm/pg-core";
import { cloudRuntimes, runAttempts } from "../db/schema";

const migration = readFileSync(new URL(
  "../db/migrations/20261017000000_runtime_persistence/migration.sql",
  import.meta.url,
), "utf8").replace(/\s+/g, " ");

describe("Runtime persistence schema", () => {
  test("declares lifecycle, placement, lease and tenant idempotency columns", () => {
    const runtimeColumns = getTableConfig(cloudRuntimes).columns.map((column) => column.name);
    expect(runtimeColumns).toEqual(expect.arrayContaining([
      "runtime_kind",
      "lifecycle_state",
      "machine_id",
      "placement_generation",
      "lease_token",
      "lease_generation",
      "lease_expires_at",
      "idempotency_key",
      "updated_at",
      "released_at",
    ]));
    const runtimeIndexes = getTableConfig(cloudRuntimes).indexes.map((index) => index.config.name);
    expect(runtimeIndexes).toContain("cloud_runtimes_owner_idempotency_unique");
    expect(runtimeIndexes).toContain("cloud_runtimes_lease_idx");
  });

  test("links attempts to runtimes without making the relation mandatory", () => {
    const attemptRuntime = getTableConfig(runAttempts).columns.find((column) => column.name === "runtime_id");
    expect(attemptRuntime?.notNull).toBe(false);
    expect(getTableConfig(runAttempts).indexes.map((index) => index.config.name)).toContain("run_attempts_runtime_idx");
    expect(migration).toContain('ADD COLUMN "runtime_id" uuid REFERENCES "cloud_runtimes"("id") ON DELETE SET NULL');
  });

  test("backfills old VM-created identities before adding lease fences", () => {
    expect(migration).toContain('CREATE TYPE "cloud_runtime_kind" AS ENUM');
    expect(migration).toContain('CREATE TYPE "cloud_runtime_lifecycle" AS ENUM');
    expect(migration).toContain("'suspended', 'stopped'");
    expect(migration).toContain('WHEN machine."status" = \'running\' THEN \'running\'');
    expect(migration).toContain('ADD CONSTRAINT "cloud_runtimes_lease_generation_nonnegative"');
  });
});

