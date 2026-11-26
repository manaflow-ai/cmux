import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  contractStatements,
  pendingMigrations,
  readLedgerNames,
  reportPending,
} from "../scripts/cloud-vm/contract-migrations.mjs";

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const migrationsDir = path.join(webDir, "db/migrations");
const reasons = (sql: string) => contractStatements(sql).map((finding: { reason: string }) => finding.reason);

const scratchDirs: string[] = [];
afterEach(() => {
  for (const dir of scratchDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function fixture(migrations: Record<string, string>): string {
  const dir = mkdtempSync(path.join(tmpdir(), "cmux-contract-"));
  scratchDirs.push(dir);
  for (const [name, sql] of Object.entries(migrations)) {
    mkdirSync(path.join(dir, name), { recursive: true });
    writeFileSync(path.join(dir, name, "migration.sql"), sql);
  }
  return dir;
}

describe("expand-only statements pass", () => {
  test.each([
    `CREATE TABLE "x" ("id" text PRIMARY KEY);`,
    `ALTER TABLE "apple_subscriptions" ADD COLUMN "carried_plan" text;`,
    `ALTER TABLE "x" ADD COLUMN IF NOT EXISTS "y" integer DEFAULT 0 NOT NULL;`,
    `CREATE INDEX CONCURRENTLY IF NOT EXISTS "x_y_idx" ON "x" ("y");`,
    `ALTER TYPE "vm_provider" ADD VALUE IF NOT EXISTS 'freestyle';`,
    `ALTER TABLE "x" ALTER COLUMN "y" DROP NOT NULL;`,
    `ALTER TABLE "x" ALTER COLUMN "y" DROP DEFAULT;`,
    `UPDATE "x" SET "y" = 1 WHERE "y" IS NULL;`,
    `-- DROP TABLE "x"; is only a comment\nSELECT 1;`,
    // Constraints and unique indexes on a table this migration creates cannot reject live writes.
    `CREATE TABLE "n" ("id" text, "u" text NOT NULL);\nALTER TABLE "n" ADD CONSTRAINT "n_fk" FOREIGN KEY ("u") REFERENCES "x"("id");\nCREATE UNIQUE INDEX "n_u" ON "n" ("u");`,
  ])("%s", (sql) => {
    expect(contractStatements(sql)).toEqual([]);
  });
});

describe("contract statements are held", () => {
  test.each([
    [`DROP TABLE "x";`, "drops something"],
    [`DROP TYPE IF EXISTS "vm_provider_old";`, "drops something"],
    [`ALTER TABLE "x" DROP COLUMN "y";`, "drops something"],
    [`ALTER TABLE "x" DROP "y";`, "drops something"],
    // A dropped index or constraint can be a live upsert's ON CONFLICT target.
    [`DROP INDEX IF EXISTS "x_old_idx";`, "drops something"],
    [`ALTER TABLE "x" DROP CONSTRAINT IF EXISTS "x_check";`, "drops something"],
    [`DROP TRIGGER "t" ON "x";`, "drops something"],
    [`ALTER TABLE "x" RENAME COLUMN "y" TO "z";`, "renames something"],
    [`ALTER TABLE "x" RENAME TO "z";`, "renames something"],
    [`ALTER TABLE "x" ALTER COLUMN "y" SET DATA TYPE bigint;`, "changes a column type"],
    [`ALTER TABLE "x" ALTER COLUMN y TYPE text USING y::text;`, "changes a column type"],
    [`ALTER TABLE "x" ALTER COLUMN "y" SET NOT NULL;`, "makes a column NOT NULL"],
    [`TRUNCATE "x";`, "truncates a table"],
    [`REVOKE SELECT ON "x" FROM app;`, "revokes a privilege"],
    [`ALTER TABLE "x" ADD COLUMN "y" text NOT NULL;`, "adds a NOT NULL column without a default"],
    [`ALTER TABLE "x" ADD CONSTRAINT "x_y_check" CHECK ("y" > 0) NOT VALID;`, "adds a constraint live writes may violate"],
    [`ALTER TABLE "x" ADD CONSTRAINT "x_u" UNIQUE ("u");`, "adds a constraint live writes may violate"],
    [`CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS "x_u" ON "x" ("u");`, "adds a unique index live writes may violate"],
  ])("%s", (sql, reason) => {
    expect(reasons(sql)).toEqual([reason]);
  });

  test("statement breakpoints split statements even with comments around them", () => {
    const sql = `ALTER TABLE "x" ADD COLUMN "a" text--> statement-breakpoint\nALTER TABLE "x" DROP COLUMN "b"`;
    expect(contractStatements(sql)).toHaveLength(1);
    expect(contractStatements(sql)[0].statement).toBe(`ALTER TABLE "x" DROP COLUMN "b"`);
  });

  test("the migration from the 2026-11-18 outage is expand-only, so it would have applied automatically", () => {
    const sql = readFileSync(path.join(migrationsDir, "20261116120000_apple_iap_carried_plan/migration.sql"), "utf8");
    expect(contractStatements(sql)).toEqual([]);
  });
});

describe("pending migrations", () => {
  const folder = () =>
    fixture({
      "20261120000000_drop": `ALTER TABLE "a" DROP COLUMN "b";`,
      "20261120000100_ok": `CREATE TABLE "c" ("id" text);`,
    });

  test("a migration held on one push is still held on the next, because pending comes from the ledger", () => {
    const migrationsFolder = folder();
    // The next push only added 20261120000100_ok, but the drop is still unapplied.
    const pending = pendingMigrations(webDir, [], { migrationsFolder });
    expect(pending.map((m: { name: string }) => m.name)).toEqual(["20261120000000_drop", "20261120000100_ok"]);
    const lines: string[] = [];
    const code = reportPending("production", pending, { log: (l: string) => lines.push(l), error: (l: string) => lines.push(l) });
    expect(code).toBe(1);
    expect(lines.join("\n")).toContain("20261120000000_drop: drops something");
    expect(lines.join("\n")).toContain("20261120000100_ok: expand-only");
    expect(lines.join("\n")).toContain("dispatch cloud-vm-migrate.yml with target=production");
  });

  test("once a person applied the drop, the next push applies on its own", () => {
    const pending = pendingMigrations(webDir, ["20261120000000_drop"], { migrationsFolder: folder() });
    expect(reportPending("production", pending, { log: () => {}, error: () => {} })).toBe(0);
  });

  test("nothing pending passes", () => {
    const lines: string[] = [];
    expect(reportPending("staging", [], { log: (l: string) => lines.push(l) })).toBe(0);
    expect(lines).toEqual(["contract-migrations: staging has no pending migrations."]);
  });
});

describe("ledger read", () => {
  function fakeClient(present: boolean, names: string[]) {
    const queries: string[] = [];
    return {
      queries,
      query: async (text: string) => {
        queries.push(text);
        if (text.includes("to_regclass")) return { rows: [{ present }] };
        if (text.startsWith("select name")) return { rows: names.map((name) => ({ name })) };
        return { rows: [] };
      },
    };
  }

  test("reads names inside a read-only transaction and rolls back", async () => {
    const client = fakeClient(true, ["a", "b"]);
    expect(await readLedgerNames(client)).toEqual(["a", "b"]);
    expect(client.queries[0]).toBe("begin read only");
    expect(client.queries.at(-1)).toBe("rollback");
  });

  test("a database with no ledger has everything pending", async () => {
    const client = fakeClient(false, []);
    expect(await readLedgerNames(client)).toEqual([]);
    expect(client.queries.some((q) => q.startsWith("select name"))).toBe(false);
  });
});

test("the hold stays rare over the real migrations folder", () => {
  const names = readdirSync(migrationsDir).filter((name) => /^\d{14}_/.test(name));
  const held = names.filter((name) => contractStatements(readFileSync(path.join(migrationsDir, name, "migration.sql"), "utf8")).length > 0);
  console.log(`held ${held.length} of ${names.length}:\n${held.join("\n")}`);
  expect(names.length).toBeGreaterThan(100);
  expect(held.length / names.length).toBeLessThan(0.35);
});
