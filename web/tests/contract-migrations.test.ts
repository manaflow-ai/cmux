import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { contractStatements, main } from "../scripts/cloud-vm/contract-migrations.mjs";

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const migrationsDir = path.join(webDir, "db/migrations");
const reasons = (sql: string) => contractStatements(sql).map((finding: { reason: string }) => finding.reason);

describe("expand-only statements pass", () => {
  test.each([
    `CREATE TABLE "x" ("id" text PRIMARY KEY);`,
    `ALTER TABLE "apple_subscriptions" ADD COLUMN "carried_plan" text;`,
    `ALTER TABLE "x" ADD COLUMN IF NOT EXISTS "y" integer DEFAULT 0 NOT NULL;`,
    `CREATE INDEX CONCURRENTLY IF NOT EXISTS "x_y_idx" ON "x" ("y");`,
    `ALTER TYPE "vm_provider" ADD VALUE IF NOT EXISTS 'freestyle';`,
    `ALTER TABLE "x" DROP CONSTRAINT IF EXISTS "x_check";`,
    `ALTER TABLE "x" ALTER COLUMN "y" DROP NOT NULL;`,
    `ALTER TABLE "x" ALTER COLUMN "y" DROP DEFAULT;`,
    `DROP INDEX IF EXISTS "x_old_idx";`,
    `UPDATE "x" SET "y" = 1 WHERE "y" IS NULL;`,
    `-- DROP TABLE "x"; is only a comment\nSELECT 1;`,
  ])("%s", (sql) => {
    expect(contractStatements(sql)).toEqual([]);
  });
});

describe("contract statements are held", () => {
  test.each([
    [`DROP TABLE "x";`, "drops an object"],
    [`DROP TYPE IF EXISTS "vm_provider_old";`, "drops an object"],
    [`ALTER TABLE "x" DROP COLUMN "y";`, "drops a column"],
    [`ALTER TABLE "x" DROP "y";`, "drops a column"],
    [`ALTER TABLE "x" RENAME COLUMN "y" TO "z";`, "renames an object or column"],
    [`ALTER TABLE "x" RENAME TO "z";`, "renames an object or column"],
    [`ALTER TABLE "x" ALTER COLUMN "y" SET DATA TYPE bigint;`, "changes a column type"],
    [`ALTER TABLE "x" ALTER COLUMN y TYPE text USING y::text;`, "changes a column type"],
    [`ALTER TABLE "x" ALTER COLUMN "y" SET NOT NULL;`, "makes a column NOT NULL"],
    [`TRUNCATE "x";`, "truncates a table"],
  ])("%s", (sql, reason) => {
    expect(reasons(sql)).toEqual([reason]);
  });

  test("statement breakpoints split statements", () => {
    const sql = `ALTER TABLE "x" ADD COLUMN "a" text;--> statement-breakpoint\nALTER TABLE "x" DROP COLUMN "b";`;
    expect(reasons(sql)).toEqual(["drops a column"]);
  });
});

describe("cli", () => {
  const run = (files: Record<string, string>) => {
    const lines: string[] = [];
    const code = main(Object.keys(files), {
      read: (file: string) => {
        if (!(file in files)) throw new Error("missing");
        return files[file];
      },
      log: (line: string) => lines.push(line),
      error: (line: string) => lines.push(line),
    });
    return { code, out: lines.join("\n") };
  };

  test("no added migrations passes", () => {
    expect(run({}).code).toBe(0);
  });

  test("the migration from the 2026-11-18 outage is expand-only, so it would have applied automatically", () => {
    const file = path.join(migrationsDir, "20261116120000_apple_iap_carried_plan/migration.sql");
    expect(main([file], { log: () => {}, error: () => {} })).toBe(0);
  });

  test("a contract migration stops the run and names it", () => {
    const result = run({
      "db/migrations/20261120000000_ok/migration.sql": `CREATE TABLE "a" ("id" text);`,
      "db/migrations/20261120000100_drop/migration.sql": `ALTER TABLE "a" DROP COLUMN "b";`,
    });
    expect(result.code).toBe(1);
    expect(result.out).toContain("20261120000000_ok: expand-only");
    expect(result.out).toContain("20261120000100_drop: drops a column");
    expect(result.out).toContain("dispatch cloud-vm-migrate.yml");
  });

  test("an unreadable file is a usage error, not a pass", () => {
    const lines: string[] = [];
    expect(main(["nope/migration.sql"], { read: () => { throw new Error("x"); }, log: () => {}, error: (l: string) => lines.push(l) })).toBe(2);
  });

  test("most existing migrations are expand-only (the hold is rare)", () => {
    const names = readdirSync(migrationsDir).filter((name) => /^\d{14}_/.test(name));
    const held = names.filter((name) => contractStatements(readFileSync(path.join(migrationsDir, name, "migration.sql"), "utf8")).length > 0);
    expect(names.length).toBeGreaterThan(100);
    expect(held.length / names.length).toBeLessThan(0.2);
  });
});
