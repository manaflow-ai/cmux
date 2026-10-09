/**
 * Design change after the third review: the linter is a strict allowlist of exact statement
 * shapes; a contract header lifts only a named list of non-expand operations; the owner role's
 * privileges are the real wall. One fixture per rule.
 */
import { describe, expect, it } from "bun:test"
import { lintFile, type TreeRoleContract } from "../lint.ts"
import { TREES } from "../trees.ts"

const vm = TREES["cmux-vm"]
const contract: TreeRoleContract = { grantees: ["cmux_vm_app"], tablePrivileges: ["SELECT", "INSERT", "UPDATE", "DELETE"], schemas: ["cmux_vm"], schemaPrivileges: ["USAGE"] }
const header = "-- contract: deliberate non-expand change for this fixture\n"
const errorsOf = async (sql: string) => (await lintFile(vm, "0009_x.sql", sql, contract)).errors

describe("A: allowed without a header (exact shapes)", () => {
  const ok: Array<[string, string]> = [
    ["a table with built-in types, NULL/NOT NULL, constant and allowlisted defaults, keys and checks", "CREATE TABLE IF NOT EXISTS cmux_vm.t (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), n int4 NOT NULL DEFAULT 0, name text NULL CHECK (char_length(name) BETWEEN 1 AND 80), owner text REFERENCES cmux_vm.resources (cmux_id), at timestamptz NOT NULL DEFAULT now(), UNIQUE (n, name));"],
    ["ADD COLUMN nullable, with a constant default, with an inline CHECK", "ALTER TABLE cmux_vm.resources ADD COLUMN note text, ADD COLUMN plan text NOT NULL DEFAULT 'free', ADD COLUMN v6 text NULL CHECK (v6 IS NULL OR v6 ~ '^[0-9a-f:]{2,39}$');"],
    ["ADD CONSTRAINT ... NOT VALID and VALIDATE", "ALTER TABLE cmux_vm.resources ADD CONSTRAINT c CHECK (length(tenant_id) > 0) NOT VALID;\nALTER TABLE cmux_vm.resources VALIDATE CONSTRAINT c;"],
    ["a unique index on a new table and a CONCURRENTLY index with a partial WHERE", "CREATE TABLE cmux_vm.u (a text);\nCREATE UNIQUE INDEX u_a ON cmux_vm.u USING btree (a);"],
    ["CREATE INDEX CONCURRENTLY with an allowlisted expression", "CREATE INDEX CONCURRENTLY IF NOT EXISTS resources_lower ON cmux_vm.resources (lower(created_by)) WHERE deleted_at IS NULL;"],
    ["a sequence and an enum", "CREATE SEQUENCE IF NOT EXISTS cmux_vm.s START 1;\nCREATE TYPE cmux_vm.mode AS ENUM ('a', 'b');\nALTER TYPE cmux_vm.mode ADD VALUE IF NOT EXISTS 'c';"],
    ["COMMENT on cmux_vm objects and GRANT per the contract", "COMMENT ON TABLE cmux_vm.resources IS 'x';\nGRANT SELECT ON cmux_vm.resources TO cmux_vm_app;"],
  ]
  for (const [what, sql] of ok) it(`accepts ${what}`, async () => expect(await errorsOf(sql)).toEqual([]))
})

describe("A: a header lifts only the named list", () => {
  const liftable: Array<[string, string]> = [
    ["DROP CONSTRAINT", "ALTER TABLE cmux_vm.resources DROP CONSTRAINT IF EXISTS c;"],
    ["DROP INDEX", "DROP INDEX IF EXISTS cmux_vm.resources_labels_idx;"],
    ["DROP COLUMN", "ALTER TABLE cmux_vm.resources DROP COLUMN labels;"],
    ["DROP TABLE", "DROP TABLE cmux_vm.audit_log;"],
    ["RENAME within cmux_vm", "ALTER TABLE cmux_vm.resources RENAME COLUMN labels TO tags;"],
    ["SET NOT NULL", "ALTER TABLE cmux_vm.resources ALTER COLUMN display_name SET NOT NULL;"],
    ["ALTER COLUMN TYPE", "ALTER TABLE cmux_vm.resources ALTER COLUMN display_name TYPE text;"],
    ["a validated CHECK on an existing table (a CHECK replacement)", "ALTER TABLE cmux_vm.resources ADD CONSTRAINT c CHECK (length(tenant_id) > 0);"],
  ]
  for (const [what, sql] of liftable) {
    it(`${what}: refused without a header, accepted with one`, async () => {
      expect((await errorsOf(sql)).length).toBeGreaterThan(0)
      expect(await errorsOf(header + sql)).toEqual([])
    })
  }
})

describe("A: refused always (with or without a header)", () => {
  const never: Array<[string, string]> = [
    ["INSERT (data belongs in a reviewed data file, not a schema migration)", "INSERT INTO cmux_vm.audit_log (id) VALUES ('a');"],
    ["UPDATE with a WHERE", "UPDATE cmux_vm.resources SET labels = '{}' WHERE labels IS NULL;"],
    ["DELETE with a WHERE", "DELETE FROM cmux_vm.audit_log WHERE created_at < now();"],
    ["a CTE", "WITH x AS (SELECT 1) INSERT INTO cmux_vm.t (n) SELECT 1 FROM x;"],
    ["a top-level SELECT", "SELECT 1;"],
    ["SET DEFAULT on an existing column", "ALTER TABLE cmux_vm.resources ALTER COLUMN labels SET DEFAULT '{}';"],
    ["DROP NOT NULL", "ALTER TABLE cmux_vm.resources ALTER COLUMN display_name DROP NOT NULL;"],
    ["DROP ... CASCADE", "DROP TABLE cmux_vm.audit_log CASCADE;"],
    ["a domain", "CREATE DOMAIN cmux_vm.d AS text;"],
    ["a composite type", "CREATE TYPE cmux_vm.pair AS (a int, b int);"],
    ["a range type", "CREATE TYPE cmux_vm.r AS RANGE (subtype = int4);"],
    ["an operator", "CREATE OPERATOR cmux_vm.=== (leftarg = int4, rightarg = int4, function = int4eq);"],
    ["a cast", "CREATE CAST (text AS cmux_vm.mode) WITH INOUT;"],
    ["ALTER FUNCTION", "ALTER FUNCTION cmux_vm.f() SECURITY DEFINER;"],
    ["a view", "CREATE VIEW cmux_vm.v AS SELECT 1;"],
    ["a column COLLATE", "CREATE TABLE cmux_vm.c (a text COLLATE \"C\");"],
    ["an index opclass", "CREATE INDEX CONCURRENTLY i ON cmux_vm.resources (created_by text_pattern_ops);"],
    ["an index USING brin", "CREATE INDEX CONCURRENTLY i ON cmux_vm.resources USING brin (created_at);"],
    ["a schema-qualified operator", "CREATE TABLE cmux_vm.o (a int CHECK (a OPERATOR(public.=) 1));"],
    ["a subquery in a CHECK", "CREATE TABLE cmux_vm.q (a int CHECK (a IN (SELECT 1)));"],
    ["a non-built-in column type", "CREATE TABLE cmux_vm.w (a public.citext);"],
    ["an UNLOGGED table", "CREATE UNLOGGED TABLE cmux_vm.l (a int);"],
    ["table inheritance", "CREATE TABLE cmux_vm.i (a int) INHERITS (cmux_vm.resources);"],
    ["storage options", "CREATE TABLE cmux_vm.p (a int) WITH (fillfactor = 50);"],
    ["a foreign key outside cmux_vm", "CREATE TABLE cmux_vm.f (u text REFERENCES public.users (id));"],
  ]
  for (const [what, sql] of never) {
    it(`refuses ${what}`, async () => {
      expect((await errorsOf(sql)).length).toBeGreaterThan(0)
      expect((await errorsOf(header + sql)).length).toBeGreaterThan(0)
    })
  }
})

describe("J: the parser itself is pinned", () => {
  it("refuses to lint when node_modules/libpg-query differs from the pinned version and hashes", async () => {
    const { parserProblems } = await import("../lint.ts")
    expect(parserProblems()).toEqual([])
    expect(parserProblems({ version: "18.1.5", sha256: { "wasm/libpg-query.wasm": "0".repeat(64) } }).join()).toContain("libpg-query.wasm")
  })
})
