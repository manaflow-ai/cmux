import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  LINT_BASELINE,
  classifyMigrationSql,
  classifyStatement,
  destructiveApproval,
  lintMigrationsDirectory,
  splitSqlStatements,
} from "../scripts/lint-migrations-additive";

const MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "db", "migrations");

describe("splitSqlStatements", () => {
  test("splits on semicolons and strips drizzle statement breakpoints", () => {
    const statements = splitSqlStatements(
      'CREATE TABLE "a" ("id" text);\n--> statement-breakpoint\nCREATE INDEX "i" ON "a" ("id");',
    );
    expect(statements).toHaveLength(2);
    expect(statements[0]).toStartWith('CREATE TABLE "a"');
    expect(statements[1]).toStartWith('CREATE INDEX "i"');
  });

  test("keeps dollar-quoted DO bodies with inner semicolons as one statement", () => {
    const statements = splitSqlStatements(
      "DO $$ BEGIN ALTER TYPE t ADD VALUE 'x'; EXCEPTION WHEN duplicate_object THEN null; END $$;\nCREATE TYPE u AS ENUM ('a');",
    );
    expect(statements).toHaveLength(2);
    expect(statements[0]).toStartWith("DO $$");
    expect(statements[0]).toContain("EXCEPTION");
  });

  test("ignores semicolons and comment markers inside string literals", () => {
    const statements = splitSqlStatements(
      "INSERT INTO a (v) VALUES ('semi;colon -- not a comment; it''s data');\nSELECT 1;",
    );
    expect(statements).toHaveLength(2);
    expect(statements[0]).toContain("it''s data");
  });

  test("strips nested block comments", () => {
    const statements = splitSqlStatements("/* outer /* inner; */ still comment */ CREATE TABLE t (id text);");
    expect(statements).toEqual(["CREATE TABLE t (id text)"]);
  });
});

describe("classifyStatement", () => {
  const additive = [
    'CREATE TABLE IF NOT EXISTS "cloud_vm_preview_leases" ("id" text PRIMARY KEY)',
    'CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS "idx" ON "t" ("a")',
    "CREATE TYPE \"vm_kind\" AS ENUM ('a', 'b')",
    "ALTER TYPE \"vm_provider\" ADD VALUE IF NOT EXISTS 'blaxel'",
    'ALTER TABLE "cloud_vms" ADD COLUMN IF NOT EXISTS "display_name" text',
    'ALTER TABLE "t" ADD COLUMN "n" integer NOT NULL DEFAULT 0',
    'ALTER TABLE "t" ADD COLUMN "id2" bigint GENERATED ALWAYS AS IDENTITY',
    'ALTER TABLE "t" ADD CONSTRAINT "fk" FOREIGN KEY ("a") REFERENCES "b" ("id") NOT VALID',
    'ALTER TABLE "t" VALIDATE CONSTRAINT "fk"',
    'ALTER TABLE "t" ALTER COLUMN "a" SET DEFAULT \'x\'',
    'ALTER TABLE "t" ALTER COLUMN "a" DROP NOT NULL',
    "COMMENT ON COLUMN \"t\".\"a\" IS 'docs'",
    "SET statement_timeout = '5min'",
  ];
  for (const statement of additive) {
    test(`additive: ${statement.slice(0, 60)}`, () => {
      expect(classifyStatement(statement)).toBeNull();
    });
  }

  const destructive = [
    'DROP TABLE "old_stuff"',
    'DROP INDEX IF EXISTS "idx"',
    'ALTER TABLE "t" DROP COLUMN "a"',
    'ALTER TABLE "t" DROP CONSTRAINT "c"',
    'ALTER TABLE "t" ALTER COLUMN "a" TYPE bigint',
    'ALTER TABLE "t" ALTER COLUMN "a" SET DATA TYPE text',
    'ALTER TABLE "t" ALTER COLUMN "a" SET NOT NULL',
    'ALTER TABLE "t" ADD COLUMN "a" text NOT NULL',
    'ALTER TABLE "t" ADD CONSTRAINT "u" UNIQUE ("a")',
    'ALTER TABLE "t" RENAME COLUMN "a" TO "b"',
    'ALTER TABLE "t" RENAME TO "t2"',
    "UPDATE \"t\" SET \"a\" = 'backfilled' WHERE \"a\" IS NULL",
    'DELETE FROM "t" WHERE "stale" = true',
    'TRUNCATE "t"',
    "WITH ranked AS (SELECT id FROM t) UPDATE t SET a = 1 FROM ranked WHERE t.id = ranked.id",
    "DO $$ BEGIN DROP TABLE x; END $$",
    "CREATE OR REPLACE FUNCTION f() RETURNS void AS $$ BEGIN END $$ LANGUAGE plpgsql",
    'GRANT SELECT ON "t" TO PUBLIC',
    "FLARBLE GARBLE",
  ];
  for (const statement of destructive) {
    test(`destructive: ${statement.slice(0, 60)}`, () => {
      expect(classifyStatement(statement)).not.toBeNull();
    });
  }

  test("string literals cannot fake NOT NULL keywords", () => {
    expect(classifyStatement("ALTER TABLE \"t\" ADD COLUMN \"a\" text DEFAULT 'not null'")).toBeNull();
  });

  test("multi-action ALTER TABLE reports only the destructive actions", () => {
    const reason = classifyStatement(
      'ALTER TABLE "t" ADD COLUMN "ok" numeric(10,2), DROP COLUMN "bad"',
    );
    expect(reason).toContain("drops a column");
    expect(reason).not.toContain("unrecognized");
  });
});

describe("classifyMigrationSql and approvals", () => {
  test("a fully additive migration has no findings", () => {
    const sql = readFileSync(
      join(MIGRATIONS_DIR, "20260823010000_cloud_vm_display_name", "migration.sql"),
      "utf8",
    );
    expect(classifyMigrationSql(sql)).toEqual([]);
  });

  test("findings carry the offending statement and a reason", () => {
    const findings = classifyMigrationSql('DROP TABLE "old";\nCREATE TABLE "new" ("id" text);');
    expect(findings).toHaveLength(1);
    expect(findings[0]!.statement).toContain('DROP TABLE "old"');
    expect(findings[0]!.reason).toContain("DROP");
  });

  test("the allow-destructive marker needs a justification", () => {
    expect(destructiveApproval("-- cmux:allow-destructive: column unused since v2, verified no readers\nDROP TABLE x;")).toBe(
      "column unused since v2, verified no readers",
    );
    expect(destructiveApproval("-- cmux:allow-destructive:\nDROP TABLE x;")).toBeNull();
    expect(destructiveApproval("DROP TABLE x;")).toBeNull();
  });
});

describe("lintMigrationsDirectory on the real corpus", () => {
  test("every migration after the baseline is additive or acknowledged", () => {
    const results = lintMigrationsDirectory(MIGRATIONS_DIR);
    const unacknowledged = results.filter(
      (result) => result.findings.length > 0 && result.approval === null,
    );
    expect(unacknowledged).toEqual([]);
  });

  test("the baseline names a real migration and the outage migrations classify additive", () => {
    const all = lintMigrationsDirectory(MIGRATIONS_DIR, { all: true });
    const names = all.map((result) => result.name);
    expect(names).toContain(LINT_BASELINE);
    for (const outageMigration of [
      "20260820050000_blaxel_vm_provider",
      "20260823010000_cloud_vm_display_name",
      "20260824010000_cloud_vm_preview_leases",
    ]) {
      const result = all.find((candidate) => candidate.name === outageMigration);
      expect(result).toBeDefined();
      expect(result!.findings).toEqual([]);
    }
  });
});
