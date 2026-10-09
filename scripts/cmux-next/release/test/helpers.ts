/** Test support: temp repository roots, and a fake PlanetScale provider whose branches are real Postgres databases. */
import { createHash } from "node:crypto"
import { cpSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import type { BranchProvider } from "../branches.ts"
import { connectUrl, type Sql } from "../runner.ts"
import { REPO_ROOT } from "../trees.ts"

export const REAL = (path: string) => join(REPO_ROOT, path)

/** A temp root holding the repo's real migration trees, lock and role contract. */
export const tempRoot = (): string => {
  const root = mkdtempSync(join(tmpdir(), "rails-root-"))
  for (const dir of ["workers/cmux-vm/migrations", "backend/db/migrations"]) cpSync(REAL(dir), join(root, dir), { recursive: true })
  mkdirSync(join(root, "scripts/cmux-next/release"), { recursive: true })
  for (const f of ["migrations.lock.json", "role-contract.json"]) cpSync(REAL(`scripts/cmux-next/release/${f}`), join(root, `scripts/cmux-next/release/${f}`))
  return root
}

export const writeMigration = (root: string, tree: "cmux-vm" | "backend", name: string, sql: string) => {
  const dir = tree === "cmux-vm" ? "workers/cmux-vm/migrations" : "backend/db/migrations"
  writeFileSync(join(root, dir, name), sql)
}

/** Writes a migration and records it in the temp root's lock, as `lint.ts --update-lock` would after it passes. */
export const addMigration = (root: string, tree: "cmux-vm" | "backend", name: string, sql: string) => {
  writeMigration(root, tree, name, sql)
  const lockPath = join(root, "scripts/cmux-next/release/migrations.lock.json")
  const lock = JSON.parse(readFileSync(lockPath, "utf8"))
  lock.trees[tree].files[name] = createHash("sha256").update(sql).digest("hex")
  writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`)
}

export const readText = (path: string) => readFileSync(path, "utf8")

export const SCRATCH_URL = process.env.SCRATCH_URL ?? ""
/** CI always provides SCRATCH_URL; a run without it must fail, not skip. */
export const requireScratch = () => {
  if (!SCRATCH_URL) throw new Error("SCRATCH_URL is not set: the database tests need a scratch Postgres (CI: the postgres service)")
}

export const dbUrl = (name: string) => {
  const u = new URL(SCRATCH_URL)
  u.pathname = `/${name}`
  return u.toString()
}

const quote = (s: string) => `"${s.replace(/"/g, '""')}"`

let admin: Sql | undefined
export const adminSql = async () => (admin ??= await connectUrl(SCRATCH_URL))

export const createDb = async (name: string, template?: string) => {
  const sql = await adminSql()
  await sql.query(`CREATE DATABASE ${quote(name)}${template ? ` TEMPLATE ${quote(template)}` : ""}`)
}
export const dropDb = async (name: string) => {
  const sql = await adminSql()
  await sql.query(`DROP DATABASE IF EXISTS ${quote(name)} WITH (FORCE)`)
}

export interface FakeProvider extends BranchProvider {
  readonly calls: Array<string>
  readonly dbOf: (database: string, branch: string) => string
  /** Next create copies this database instead of the parent (a branch restored from a stale backup). */
  staleFrom?: string
  /** Next create fails after creating the database. */
  failCreate?: boolean
}

/** Branches are databases named `<prefix>_<database>_<branch>`; create = CREATE DATABASE ... TEMPLATE parent (schema and data). */
export const fakeProvider = (prefix: string, roles: Record<string, string> = {}): FakeProvider => {
  const dbOf = (database: string, branch: string) => `${prefix}_${database}_${branch}`.replace(/[^a-z0-9_]/g, "_").slice(0, 63)
  const provider: FakeProvider = {
    calls: [],
    dbOf,
    async create(database, name, from) {
      provider.calls.push(`create ${database}/${name} from ${from}`)
      const template = provider.staleFrom ?? dbOf(database, from)
      provider.staleFrom = undefined
      await createDb(dbOf(database, name), template)
      if (provider.failCreate) {
        provider.failCreate = false
        throw new Error("fake create failed after the branch appeared")
      }
    },
    async connect(database, branch, access) {
      provider.calls.push(`connect ${access} ${database}/${branch}`)
      return { url: dbUrl(dbOf(database, branch)), release: async () => void provider.calls.push(`release ${database}/${branch}`) }
    },
    async roleUser(database, branch, roleName) {
      return roles[`${branch}/${roleName}`]
    },
    async delete(database, name) {
      provider.calls.push(`delete ${database}/${name}`)
      await dropDb(dbOf(database, name))
    },
    async exists(database, name) {
      const sql = await adminSql()
      return (await sql.query<{ n: string }>("SELECT count(*)::text AS n FROM pg_database WHERE datname = $1", [dbOf(database, name)]))[0]?.n === "1"
    },
  }
  return provider
}

export const uniquePrefix = () => `rr${Date.now().toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`
