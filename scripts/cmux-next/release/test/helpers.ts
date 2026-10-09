/** Test support: temp repository roots, and a fake PlanetScale provider whose branches are real Postgres databases. */
import { createHash } from "node:crypto"
import { execFileSync } from "node:child_process"
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
  mkdirSync(join(root, "workers/cmux-vm/src/db"), { recursive: true })
  cpSync(REAL("workers/cmux-vm/src/db/schema-requirements.ts"), join(root, "workers/cmux-vm/src/db/schema-requirements.ts"))
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

/** Appends one entry (a TS object literal) to the temp root's REQUIRED_SCHEMA. */
export const addRequirement = (root: string, literal: string) => {
  const path = join(root, "workers/cmux-vm/src/db/schema-requirements.ts")
  const text = readFileSync(path, "utf8")
  const end = text.indexOf("];", text.indexOf("export const REQUIRED_SCHEMA"))
  writeFileSync(path, `${text.slice(0, end)}  ${literal},\n${text.slice(end)}`)
}

/** Makes `root` a git repository with one commit; `landed` names the branch the production apply checks ancestry against. */
export const gitInit = (root: string): string => {
  const git = (...args: Array<string>) => execFileSync("git", ["-C", root, "-c", "user.email=t@t", "-c", "user.name=t", ...args], { encoding: "utf8" }).trim()
  git("init", "-q")
  git("add", ".")
  git("commit", "-qm", "landed")
  git("branch", "landed")
  return git("rev-parse", "HEAD")
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
  /** The limited owner role every branch connection uses (CREATE on the database, nothing in public), like PlanetScale's cmux-vm-owner should be. */
  readonly owner: string
  /** A URL to `db` as the owner role. */
  readonly ownerUrl: (db: string) => string
  /** Next create copies this database instead of the parent (a branch restored from a stale backup). */
  staleFrom?: string
  /** Next create fails after creating the database. */
  failCreate?: boolean
}

/** Creates a database the owner role may create schemas in (public stays owned by the database owner). */
export const createOwnedDb = async (name: string, owner: string, template?: string) => {
  await createDb(name, template)
  const sql = await adminSql()
  await sql.query(`GRANT CREATE ON DATABASE ${quote(name)} TO ${quote(owner)}`)
}

export const createOwnerRole = async (role: string) => {
  const sql = await adminSql()
  await sql.query(`CREATE ROLE ${quote(role)} LOGIN PASSWORD 'pw'`)
}

/**
 * Branches are databases named `<prefix>_<database>_<branch>`; create = CREATE DATABASE ... TEMPLATE
 * parent (schema, data and object owners, like a PlanetScale point-in-time branch). Every connection
 * is the owner role, so the broad-privilege refusal sees what production should look like.
 */
export const fakeProvider = (prefix: string, roles: Record<string, string> = {}): FakeProvider => {
  const dbOf = (database: string, branch: string) => `${prefix}_${database}_${branch}`.replace(/[^a-z0-9_]/g, "_").slice(0, 63)
  const owner = `${prefix}_owner`
  const ownerUrl = (db: string) => {
    const u = new URL(dbUrl(db))
    u.username = owner
    u.password = "pw"
    return u.toString()
  }
  const provider: FakeProvider = {
    calls: [],
    dbOf,
    owner,
    ownerUrl,
    async create(database, name, from) {
      provider.calls.push(`create ${database}/${name} from ${from}`)
      const template = provider.staleFrom ?? dbOf(database, from)
      provider.staleFrom = undefined
      await createOwnedDb(dbOf(database, name), owner, template)
      if (provider.failCreate) {
        provider.failCreate = false
        throw new Error("fake create failed after the branch appeared")
      }
    },
    async connect(database, branch, access) {
      provider.calls.push(`connect ${access} ${database}/${branch}`)
      return { url: ownerUrl(dbOf(database, branch)), release: async () => void provider.calls.push(`release ${database}/${branch}`) }
    },
    async connectDefault(database, branch) {
      provider.calls.push(`connect default ${database}/${branch}`)
      return { url: ownerUrl(dbOf(database, branch)), release: async () => {} }
    },
    async connectRole(database, branch) {
      provider.calls.push(`connect owner ${database}/${branch}`)
      return { url: ownerUrl(dbOf(database, branch)), release: async () => {} }
    },
    async roleNames() {
      return []
    },
    async roleUser(database, branch, roleName) {
      return roles[`${branch}/${roleName}`] ?? (roleName === "cmux-vm-owner" ? owner : undefined)
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
