import { describe, expect, it } from "bun:test"
import { execFileSync } from "node:child_process"
import { join } from "node:path"
import { lintFile, lintTree, readJson, updateLock, CONTRACT_PATH, LOCK_PATH, type Lock, type RoleContract, type TreeRoleContract } from "../lint.ts"
import { REPO_ROOT, TREES } from "../trees.ts"
import { readText, tempRoot, writeMigration } from "./helpers.ts"

const vm = TREES["cmux-vm"]
const backend = TREES.backend
const contract: TreeRoleContract = { grantees: ["cmux_vm_app"], tablePrivileges: ["SELECT", "INSERT", "UPDATE", "DELETE"], schemas: ["cmux_vm"], schemaPrivileges: ["USAGE"] }
const errorsOf = async (sql: string, name = "0009_x.sql") => (await lintFile(vm, name, sql, contract)).errors

const optionsFor = (root: string, base?: string) => ({
  root,
  lock: readJson<Lock>(join(root, LOCK_PATH)),
  contract: readJson<RoleContract>(join(root, CONTRACT_PATH)),
  ...(base ? { base } : {}),
})

describe("refused without a contract header (one fixture per rule)", () => {
  const refused: Array<[string, string]> = [
    ["DROP TABLE", "DROP TABLE cmux_vm.resources;"],
    ["DROP SCHEMA", "DROP SCHEMA cmux_vm CASCADE;"],
    ["DROP INDEX", "DROP INDEX cmux_vm.resources_labels_idx;"],
    ["DROP COLUMN", "ALTER TABLE cmux_vm.resources DROP COLUMN labels;"],
    ["DROP without COLUMN keyword", "ALTER TABLE cmux_vm.resources DROP labels;"],
    ["DROP CONSTRAINT", "ALTER TABLE cmux_vm.resources DROP CONSTRAINT c;"],
    ["RENAME TABLE", "ALTER TABLE cmux_vm.resources RENAME TO things;"],
    ["RENAME COLUMN", "ALTER TABLE cmux_vm.resources RENAME COLUMN labels TO tags;"],
    ["ALTER COLUMN TYPE (narrowing)", "ALTER TABLE cmux_vm.resources ALTER COLUMN tenant_id TYPE varchar(8);"],
    ["SET NOT NULL", "ALTER TABLE cmux_vm.resources ALTER COLUMN display_name SET NOT NULL;"],
    ["DROP DEFAULT", "ALTER TABLE cmux_vm.resources ALTER COLUMN created_at DROP DEFAULT;"],
    ["ADD COLUMN NOT NULL without DEFAULT", "ALTER TABLE cmux_vm.resources ADD COLUMN owner text NOT NULL;"],
    ["ADD COLUMN NOT NULL with a comma in the type", "ALTER TABLE cmux_vm.resources ADD COLUMN cost numeric(10,2) NOT NULL;"],
    ["validated CHECK on an existing table", "ALTER TABLE cmux_vm.resources ADD CONSTRAINT c CHECK (length(tenant_id) > 0);"],
    ["UNIQUE constraint on an existing table", "ALTER TABLE cmux_vm.resources ADD CONSTRAINT u UNIQUE (upstream_id);"],
    ["CREATE INDEX on an existing table without CONCURRENTLY", "CREATE INDEX resources_x ON cmux_vm.resources (created_by);"],
    ["CREATE UNIQUE INDEX CONCURRENTLY on an existing table", "CREATE UNIQUE INDEX CONCURRENTLY resources_u ON cmux_vm.resources (upstream_id);"],
    ["UPDATE without WHERE", "UPDATE cmux_vm.resources SET labels = '{}';"],
    ["DELETE without WHERE", "DELETE FROM cmux_vm.audit_log;"],
    ["TRUNCATE", "TRUNCATE cmux_vm.audit_log;"],
    ["DO block hiding a drop", "DO $$ BEGIN EXECUTE 'drop table cmux_vm.resources'; END $$;"],
    ["CREATE FUNCTION", "CREATE FUNCTION cmux_vm.f() RETURNS int LANGUAGE sql AS 'select 1';"],
    ["string that looks like a comment", "SELECT '--'; DROP TABLE cmux_vm.resources;"],
    ["block comment as whitespace", "DROP/**/TABLE cmux_vm.resources;"],
    ["ALTER TYPE RENAME VALUE", "ALTER TYPE cmux_vm.kind RENAME VALUE 'vm' TO 'machine';"],
    ["GRANT ALL", "GRANT ALL ON cmux_vm.resources TO cmux_vm_app;"],
    ["GRANT TO PUBLIC", "GRANT SELECT ON cmux_vm.resources TO PUBLIC;"],
    ["GRANT to a role outside the contract", "GRANT SELECT ON cmux_vm.resources TO someone_else;"],
    ["GRANT WITH GRANT OPTION", "GRANT SELECT ON cmux_vm.resources TO cmux_vm_app WITH GRANT OPTION;"],
    ["GRANT ON ALL TABLES IN SCHEMA", "GRANT SELECT ON ALL TABLES IN SCHEMA cmux_vm TO cmux_vm_app;"],
    ["GRANT on an unqualified table", "GRANT SELECT ON resources TO cmux_vm_app;"],
    ["GRANT on another schema", "GRANT SELECT ON public.users TO cmux_vm_app;"],
    ["GRANT CREATE on the schema", "GRANT CREATE ON SCHEMA cmux_vm TO cmux_vm_app;"],
    ["role membership", "GRANT pg_write_all_data TO cmux_vm_app;"],
    ["default privileges", "ALTER DEFAULT PRIVILEGES IN SCHEMA cmux_vm GRANT SELECT ON TABLES TO cmux_vm_app;"],
    ["REVOKE", "REVOKE SELECT ON cmux_vm.resources FROM cmux_vm_app;"],
    ["CREATE ROLE", "CREATE ROLE intruder LOGIN;"],
  ]
  for (const [what, sql] of refused) {
    it(`refuses ${what}`, async () => {
      const errors = await errorsOf(`-- fixture\n${sql}\n`)
      expect(errors.length).toBeGreaterThan(0)
    })
  }

  it("names the contract header in the refusal", async () => {
    expect((await errorsOf("DROP TABLE cmux_vm.resources;")).join("\n")).toContain('add "-- contract: <reason>"')
  })

  it("refuses BEGIN/COMMIT and a CONCURRENTLY index that shares its file", async () => {
    expect((await errorsOf("BEGIN; CREATE TABLE cmux_vm.t (id text); COMMIT;")).join()).toContain("BEGIN/COMMIT")
    expect((await errorsOf("CREATE INDEX CONCURRENTLY i ON cmux_vm.resources (created_by);\nCREATE TABLE cmux_vm.t (id text);")).join()).toContain("only statement")
  })
})

describe("accepted expand changes", () => {
  const accepted: Array<[string, string]> = [
    ["a new table with its own (even unique) indexes", "CREATE TABLE cmux_vm.t (id text PRIMARY KEY, n int NOT NULL);\nCREATE UNIQUE INDEX t_n ON cmux_vm.t (n);\nCREATE INDEX t_id ON cmux_vm.t (id);"],
    ["nullable ADD COLUMN", "ALTER TABLE cmux_vm.resources ADD COLUMN note text;"],
    ["ADD COLUMN NOT NULL with DEFAULT", "ALTER TABLE cmux_vm.resources ADD COLUMN IF NOT EXISTS plan text NOT NULL DEFAULT 'free';"],
    ["SET DEFAULT and DROP NOT NULL (widening)", "ALTER TABLE cmux_vm.resources ALTER COLUMN labels SET DEFAULT '{}';\nALTER TABLE cmux_vm.resources ALTER COLUMN display_name DROP NOT NULL;"],
    ["CHECK ... NOT VALID, then VALIDATE", "ALTER TABLE cmux_vm.resources ADD CONSTRAINT c CHECK (length(tenant_id) > 0) NOT VALID;\nALTER TABLE cmux_vm.resources VALIDATE CONSTRAINT c;"],
    ["CREATE INDEX CONCURRENTLY alone", "CREATE INDEX CONCURRENTLY IF NOT EXISTS resources_created_by ON cmux_vm.resources (created_by);"],
    ["UPDATE and DELETE with WHERE", "UPDATE cmux_vm.resources SET labels = '{}' WHERE labels IS NULL;\nDELETE FROM cmux_vm.audit_log WHERE created_at < now() - interval '400 days';"],
    ["ALTER TYPE ADD VALUE", "ALTER TYPE cmux_vm.kind ADD VALUE IF NOT EXISTS 'disk';"],
    ["GRANT inside the role contract", "GRANT SELECT, INSERT ON cmux_vm.resources TO cmux_vm_app;\nGRANT USAGE ON SCHEMA cmux_vm TO cmux_vm_app;"],
    ["comments, schema and inserts", "CREATE SCHEMA IF NOT EXISTS cmux_vm;\nCOMMENT ON TABLE cmux_vm.resources IS 'x';\nINSERT INTO cmux_vm.audit_log (id) VALUES ('a');"],
  ]
  for (const [what, sql] of accepted) {
    it(`accepts ${what}`, async () => {
      expect(await errorsOf(`-- fixture\n${sql}\n`)).toEqual([])
    })
  }
})

describe("contract header", () => {
  it("accepts a non-expand file that carries -- contract: <reason>, and reports it", async () => {
    const report = await lintFile(vm, "0009_drop_labels.sql", "-- contract: labels is unread since 0010 shipped to production\nALTER TABLE cmux_vm.resources DROP COLUMN labels;\n", contract)
    expect(report.errors).toEqual([])
    expect(report.contract).toContain("unread since 0010")
  })
  it("refuses a reason shorter than 10 characters", async () => {
    expect((await errorsOf("-- contract: later\nDROP TABLE cmux_vm.resources;\n")).join()).toContain("at least 10")
  })
  it("ignores a contract line after the first statement", async () => {
    expect((await errorsOf("DROP TABLE cmux_vm.resources;\n-- contract: this comes too late to count\n")).length).toBeGreaterThan(0)
  })
  it("backend files keep -- phase: contract and -- contract: together", async () => {
    const both = "-- phase: contract\n-- contract: drop the legacy column after v2 shipped\nALTER TABLE users DROP COLUMN legacy;\n"
    expect((await lintFile(backend, "0007_x.sql", both, contract)).errors).toEqual([])
    expect((await lintFile(backend, "0007_x.sql", "-- phase: contract\nALTER TABLE users DROP COLUMN legacy;\n", contract)).errors.join()).toContain("together")
    expect((await lintFile(backend, "0007_x.sql", "-- phase: expand\n-- contract: drop the legacy column after v2 shipped\nALTER TABLE users DROP COLUMN legacy;\n", contract)).errors.join()).toContain("together")
  })
})

describe("tree rules: numbering, lock, base revision", () => {
  it("the repository's own trees pass", async () => {
    for (const tree of [vm, backend]) {
      const report = await lintTree(tree, optionsFor(REPO_ROOT))
      expect(report.errors).toEqual([])
    }
  })

  it("refuses a gap, a duplicate number and a bad name", async () => {
    const root = tempRoot()
    writeMigration(root, "cmux-vm", "0010_gap.sql", "CREATE TABLE cmux_vm.g (id text);")
    writeMigration(root, "cmux-vm", "0008_dup.sql", "CREATE TABLE cmux_vm.d (id text);")
    writeMigration(root, "cmux-vm", "0011_Bad-Name.sql", "CREATE TABLE cmux_vm.b (id text);")
    const errors = (await lintTree(vm, optionsFor(root))).errors.join("\n")
    expect(errors).toContain("breaks the numbering")
    expect(errors).toContain("NNNN_lower_snake")
  })

  it("refuses an edited landed file, a removed landed file and a file missing from the lock", async () => {
    const root = tempRoot()
    const dir = join(root, "workers/cmux-vm/migrations")
    execFileSync("sh", ["-c", `printf '\\n-- edit\\n' >> ${dir}/0003_cmux_vm_snapshot_parent.sql && rm ${join(root, "backend/db/migrations/0006_home.sql")}`])
    writeMigration(root, "cmux-vm", "0009_new.sql", "CREATE TABLE cmux_vm.n (id text);")
    const vmErrors = (await lintTree(vm, optionsFor(root))).errors.join("\n")
    expect(vmErrors).toContain("0003_cmux_vm_snapshot_parent.sql changed after it landed")
    expect(vmErrors).toContain("0009_new.sql is not in")
    expect((await lintTree(backend, optionsFor(root))).errors.join("\n")).toContain("0006_home.sql is in the lock but missing")
  })

  it("--update-lock adds a passing new file and refuses a failing one", async () => {
    const root = tempRoot()
    writeMigration(root, "cmux-vm", "0009_new.sql", "CREATE TABLE cmux_vm.n (id text);")
    const ok = await updateLock([vm], optionsFor(root))
    expect(ok.errors).toEqual([])
    expect(ok.added).toEqual(["cmux-vm/0009_new.sql"])
    expect(ok.lock.trees["cmux-vm"].files["0009_new.sql"]).toMatch(/^[0-9a-f]{64}$/)
    writeMigration(root, "cmux-vm", "0009_new.sql", "DROP TABLE cmux_vm.resources;")
    const bad = await updateLock([vm], optionsFor(root))
    expect(bad.errors.join()).toContain("DROP TABLE")
  })

  it("grandfathers only files up to grandfatheredThrough", async () => {
    const root = tempRoot()
    // 0004 replaces CHECK constraints (a contract change by today's rules); it predates them and passes.
    expect((await lintTree(vm, optionsFor(root))).errors).toEqual([])
    const lock = readJson<Lock>(join(root, LOCK_PATH))
    writeMigration(root, "cmux-vm", "0009_drop.sql", "DROP TABLE cmux_vm.audit_log;")
    lock.trees["cmux-vm"].files["0009_drop.sql"] = (await import("../lint.ts")).sha256(readText(join(root, "workers/cmux-vm/migrations/0009_drop.sql")))
    const errors = (await lintTree(vm, { ...optionsFor(root), lock })).errors.join()
    expect(errors).toContain("DROP TABLE")
  })

  it("against --base: refuses a changed base file, a renumbered new file and an edited lock entry", async () => {
    const root = tempRoot()
    const git = (...args: Array<string>) => execFileSync("git", ["-C", root, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim()
    git("init", "-q")
    git("-c", "user.email=t@t", "-c", "user.name=t", "add", ".")
    git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base")
    const base = git("rev-parse", "HEAD")
    // Base gains 0009 on another branch; this tree adds its own 0009 (same number) and edits the lock entry of 0001.
    git("checkout", "-qb", "other")
    writeMigration(root, "cmux-vm", "0009_theirs.sql", "CREATE TABLE cmux_vm.theirs (id text);")
    git("-c", "user.email=t@t", "-c", "user.name=t", "add", ".")
    git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "theirs")
    const theirs = git("rev-parse", "HEAD")
    git("checkout", "-q", base)
    const lock = readJson<Lock>(join(root, LOCK_PATH))
    lock.trees["cmux-vm"].files["0001_cmux_vm_ownership.sql"] = "f".repeat(64)
    const errors = (await lintTree(vm, { ...optionsFor(root), lock, base: theirs })).errors.join("\n")
    expect(errors).toContain("0009_theirs.sql exists at")
    expect(errors).toContain("lock entry 0001_cmux_vm_ownership.sql differs")
    writeMigration(root, "cmux-vm", "0009_mine.sql", "CREATE TABLE cmux_vm.mine (id text);")
    expect((await lintTree(vm, { ...optionsFor(root), base: theirs })).errors.join("\n")).toContain("new 0009_mine.sql must be numbered above 0009")
  })
})

describe("acceptance migration 0009 (feat-cmux-next-wg-link cec68f7fadd8)", () => {
  const fixture = readText(join(import.meta.dirname, "fixtures/0009_cmux_vm_mesh_device_address.sql"))
  it("is refused as written: it drops a CHECK constraint and adds a validated CHECK on an existing table", async () => {
    const errors = await errorsOf(fixture, "0009_cmux_vm_mesh_device_address.sql")
    expect(errors.some((e) => e.includes("DROP CONSTRAINT mesh_signed_requests_purpose_check"))).toBe(true)
    expect(errors.some((e) => e.includes("ADD CONSTRAINT mesh_signed_requests_purpose_check validated on an existing table"))).toBe(true)
    expect(errors.length).toBe(2) // the two ADD COLUMNs (nullable, inline CHECK) are expand
  })
  it("passes with a contract header that states why the replaced CHECK only widens", async () => {
    const withHeader = `-- contract: widens mesh_signed_requests_purpose_check to a superset (adds 'address'); old writes stay valid\n${fixture}`
    expect(await errorsOf(withHeader, "0009_cmux_vm_mesh_device_address.sql")).toEqual([])
  })
})

describe("cmux-vm schema confinement (cmux-old shares cmux-prod), even with a contract header", () => {
  const header = "-- contract: deliberately touching something outside cmux_vm\n"
  const refused: Array<[string, string]> = [
    ["a table in public", "CREATE TABLE public.x (id text);"],
    ["an unqualified table", "CREATE TABLE x (id text);"],
    ["ALTER of a web table", "ALTER TABLE users ADD COLUMN vm_note text;"],
    ["a read of public inside an insert", "INSERT INTO cmux_vm.audit_log (id) SELECT id FROM public.users WHERE id = 'x';"],
    ["a foreign key into public", "CREATE TABLE cmux_vm.y (user_id text REFERENCES public.users (id));"],
    ["another schema", "CREATE SCHEMA other;"],
    ["DROP of a web table", "DROP TABLE public.users;"],
    ["DROP SCHEMA public", "DROP SCHEMA public CASCADE;"],
    ["SET search_path", "SET search_path = public;"],
    ["a function of public", "CREATE TABLE cmux_vm.z (id text DEFAULT public.make_id());"],
    ["a type of public", "CREATE TABLE cmux_vm.w (k public.kind);"],
    ["GRANT on schema public", "GRANT USAGE ON SCHEMA public TO cmux_vm_app;"],
  ]
  for (const [what, sql] of refused) {
    it(`refuses ${what}`, async () => {
      const errors = await errorsOf(`${header}${sql}\n`)
      expect(errors.join("\n")).toContain("touch only schema cmux_vm")
    })
  }
  it("allows pg_catalog types and cmux_vm objects", async () => {
    expect(await errorsOf("CREATE TABLE cmux_vm.v (id int4, at timestamptz DEFAULT now(), n pg_catalog.int8);\nCREATE INDEX v_at ON cmux_vm.v (at);")).toEqual([])
  })
  it("does not apply to the backend tree (its own database)", async () => {
    expect((await lintFile(backend, "0007_x.sql", "-- phase: expand\nCREATE TABLE things (id text);\n", contract)).errors).toEqual([])
  })
})
