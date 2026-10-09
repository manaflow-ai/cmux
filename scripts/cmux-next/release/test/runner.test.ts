/**
 * The runner's own guards, independent of the linter (review P0/P1-1/P1-4): each
 * cmux-vm file runs with search_path = cmux_vm, pg_catalog, a lock_timeout and a
 * statement_timeout, and is rolled back when it wrote rows or catalog entries
 * outside schema cmux_vm (cmux-old's web/ shares the database).
 */
import { afterAll, beforeAll, describe, expect, it } from "bun:test"
import { sha256, readMigrations, type MigrationFile } from "../lint.ts"
import { applyPending, connectUrl, type Sql } from "../runner.ts"
import { TREES } from "../trees.ts"
import { adminSql, createDb, dbUrl, dropDb, REAL, requireScratch, uniquePrefix } from "./helpers.ts"

const vm = TREES["cmux-vm"]
const base = readMigrations(REAL(""), vm)
const file = (name: string, sql: string): MigrationFile => ({ name, number: Number(name.slice(0, 4)), sql, checksum: sha256(sql) })
const dbs: Array<string> = []

const fresh = async (): Promise<Sql> => {
  const db = `${uniquePrefix()}_guard`
  await createDb(db)
  dbs.push(db)
  const sql = await connectUrl(dbUrl(db))
  await applyPending(sql, vm, base, { by: "t", target: "staging" })
  await sql.query("CREATE TABLE public.users (id text PRIMARY KEY, name text); INSERT INTO public.users VALUES ('a', 'old')")
  return sql
}
const applied = async (sql: Sql) => (await sql.query<{ version: string }>("SELECT version FROM cmux_vm.schema_migrations ORDER BY version")).map((r) => r.version)

beforeAll(() => requireScratch())
afterAll(async () => {
  for (const db of dbs) await dropDb(db)
  await (await adminSql()).end()
})

describe("runtime confinement guard (P0): writes outside cmux_vm roll back", () => {
  const outside: Array<[string, string, string]> = [
    ["an UPDATE of a public table", "UPDATE public.users SET name = 'new' WHERE id = 'a';", "SELECT name AS v FROM public.users WHERE id = 'a'"],
    ["an ALTER of a public table", "ALTER TABLE public.users ADD COLUMN y text;", "SELECT count(*)::text AS v FROM pg_attribute WHERE attrelid = 'public.users'::regclass AND attname = 'y'"],
    ["a TRUNCATE of a public table", "TRUNCATE public.users;", "SELECT count(*)::text AS v FROM public.users"],
    ["a foreign key into public", "CREATE TABLE cmux_vm.z (u text REFERENCES public.users (id));", "SELECT count(*)::text AS v FROM pg_class WHERE relname = 'z'"],
    ["a GRANT on a public table", "GRANT SELECT ON public.users TO PUBLIC;", "SELECT has_table_privilege('public', 'public.users', 'SELECT')::text AS v"],
    ["a new schema", "CREATE SCHEMA other;", "SELECT count(*)::text AS v FROM pg_namespace WHERE nspname = 'other'"],
  ]
  for (const [what, body, probe] of outside) {
    it(`refuses ${what} and leaves the database as it was`, async () => {
      const sql = await fresh()
      try {
        const before = (await sql.query<{ v: string }>(probe))[0]?.v
        await expect(applyPending(sql, vm, [...base, file("0009_x.sql", body)], { by: "t", target: "staging" })).rejects.toThrow("outside schema cmux_vm")
        expect((await sql.query<{ v: string }>(probe))[0]?.v).toBe(before)
        expect((await applied(sql)).length).toBe(8)
      } finally {
        await sql.end()
      }
    })
  }

  it("refuses CREATE INDEX CONCURRENTLY on a table outside cmux_vm before running it", async () => {
    const sql = await fresh()
    try {
      await expect(applyPending(sql, vm, [...base, file("0009_i.sql", "CREATE INDEX CONCURRENTLY users_name ON public.users (name);")], { by: "t", target: "staging" })).rejects.toThrow("outside schema cmux_vm")
      expect((await sql.query<{ v: string | null }>("SELECT to_regclass('public.users_name')::text AS v"))[0]?.v).toBeNull()
    } finally {
      await sql.end()
    }
  })

  it("an unqualified name lands in cmux_vm (search_path = cmux_vm, pg_catalog)", async () => {
    const sql = await fresh()
    try {
      await applyPending(sql, vm, [...base, file("0009_t.sql", "CREATE TABLE things (id text);")], { by: "t", target: "staging" })
      expect((await sql.query<{ a: string | null; b: string | null }>("SELECT to_regclass('cmux_vm.things')::text AS a, to_regclass('public.things')::text AS b"))[0]).toEqual({ a: "cmux_vm.things", b: null })
    } finally {
      await sql.end()
    }
  })
})

describe("lock and statement timeouts (P1-4)", () => {
  it("a file that waits for a lock fails within seconds instead of queueing every query behind it", async () => {
    const sql = await fresh()
    const db = dbs.at(-1)!
    const holder = await connectUrl(dbUrl(db))
    await holder.query("BEGIN")
    await holder.query("LOCK TABLE cmux_vm.audit_log IN ACCESS SHARE MODE")
    const started = Date.now()
    await expect(applyPending(sql, vm, [...base, file("0009_note.sql", "ALTER TABLE cmux_vm.audit_log ADD COLUMN note text;")], { by: "t", target: "staging" })).rejects.toThrow("lock timeout")
    expect(Date.now() - started).toBeLessThan(10_000)
    await holder.query("ROLLBACK")
    await holder.end()
    expect((await applied(sql)).length).toBe(8)
    await sql.end()
  })
})

describe("timeout settings (re-review P3)", () => {
  it("accepts a positive duration and refuses zero, quotes and garbage", async () => {
    const { timeoutSetting } = await import("../runner.ts")
    expect(timeoutSetting("3s", "x")).toBe("3s")
    expect(timeoutSetting("250ms", "x")).toBe("250ms")
    for (const bad of ["0", "0s", "3s'; DROP", "", "forever"]) expect(() => timeoutSetting(bad, "x")).toThrow()
  })
})
