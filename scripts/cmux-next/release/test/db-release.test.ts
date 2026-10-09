/**
 * db-release.ts end to end on a scratch Postgres (SCRATCH_URL). A "branch" is a
 * database; the fake provider makes rehearsal branches with CREATE DATABASE ...
 * TEMPLATE (schema, data and owners, like a PlanetScale point-in-time branch),
 * and connects as a limited owner role (CREATE on the database, nothing in public).
 */
import { afterAll, beforeAll, describe, expect, it } from "bun:test"
import { execFileSync } from "node:child_process"
import { existsSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { changeKey } from "../compat.ts"
import { main, type Deps } from "../db-release.ts"
import { readMigrations, sha256 } from "../lint.ts"
import { readReceipts, writeReceipt } from "../receipts.ts"
import { connectUrl, type Sql } from "../runner.ts"
import { TREES } from "../trees.ts"
import { addMigration, addRequirement, adminSql, createOwnedDb, createOwnerRole, dbUrl, dropDb, fakeProvider, gitInit, requireScratch, tempRoot, uniquePrefix, type FakeProvider } from "./helpers.ts"

const vm = TREES["cmux-vm"]
const created: Array<string> = []
const roles: Array<string> = []
const HOUR = 3600_000

interface World {
  readonly root: string
  readonly receipts: string
  readonly provider: FakeProvider
  readonly deps: Deps
  readonly logs: Array<string>
  readonly errors: Array<string>
  readonly staging: string
  readonly production: string
  clock: number
  /** What the in-process cmux-old compat gate answers (tests set it). */
  compatProblems: Array<string>
  run(...argv: Array<string>): Promise<number>
  /** A superuser connection, for setup and checks the tool never makes. */
  admin(db: string): Promise<Sql>
  /** A connection as the owner role. */
  owner(db: string): Promise<Sql>
  setEnv(name: string, value: string): void
}

const world = async (): Promise<World> => {
  const prefix = uniquePrefix()
  const provider = fakeProvider(prefix)
  await createOwnerRole(provider.owner)
  roles.push(provider.owner)
  const staging = provider.dbOf("cmux-prod", "staging")
  const production = provider.dbOf("cmux-prod", "main")
  for (const db of [staging, production]) {
    await createOwnedDb(db, provider.owner)
    created.push(db)
  }
  const root = tempRoot()
  provider.root = root
  const receipts = mkdtempSync(join(tmpdir(), "rails-receipts-"))
  const logs: Array<string> = []
  const errors: Array<string> = []
  const env: Record<string, string | undefined> = { CMUX_RELEASE_RECEIPTS_DIR: receipts, STAGING_URL: provider.ownerUrl(staging), PROD_URL: provider.ownerUrl(production), CMUX_RELEASE_LANDED_REF: "landed" }
  const w: World = {
    root,
    receipts,
    provider,
    logs,
    errors,
    staging,
    production,
    clock: Date.parse("2026-10-08T12:00:00Z"),
    compatProblems: [],
    deps: { provider, connect: connectUrl, env, root, now: () => new Date(w.clock), log: (l) => logs.push(l), error: (l) => errors.push(l), allowScratchUrls: true, compat: async () => w.compatProblems, ownerPgRole: provider.owner },
    run: (...argv) => main(argv, w.deps),
    admin: (db) => connectUrl(dbUrl(db)),
    owner: (db) => connectUrl(provider.ownerUrl(db)),
    setEnv: (name, value) => void (env[name] = value),
  }
  return w
}

// The landed 0009 is a contract migration: every apply of the full tree names it.
const S = ["--tree", "cmux-vm", "--target", "staging", "--url-env", "STAGING_URL", "--allow-contract", "0009_cmux_vm_mesh_device_address.sql"]
const P = ["--tree", "cmux-vm", "--target", "production", "--url-env", "PROD_URL", "--staging-url-env", "STAGING_URL", "--confirm-production", "--allow-contract", "0009_cmux_vm_mesh_device_address.sql"]

const rows = async (w: World, db: string): Promise<Array<string>> => {
  const s = await w.admin(db)
  try {
    if ((await s.query<{ t: string | null }>("SELECT to_regclass('cmux_vm.schema_migrations')::text AS t"))[0]?.t == null) return []
    return (await s.query<{ version: string }>("SELECT version FROM cmux_vm.schema_migrations ORDER BY version")).map((r) => r.version)
  } finally {
    await s.end()
  }
}

const branchesMade = (w: World) => w.provider.calls.filter((c) => c.startsWith("create ")).map((c) => c.split(" ")[1]!.split("/")[1]!)
const addExtra = (w: World) => {
  addMigration(w.root, "cmux-vm", "0010_extra.sql", "CREATE TABLE IF NOT EXISTS cmux_vm.extra (id text PRIMARY KEY);\n")
  addRequirement(w.root, '{ table: "cmux_vm.extra", migration: "0010" }')
}
/** A git checkout whose origin is a local bare repo with feat-cmux-next at HEAD (tests accept any origin URL). */
const landed = (w: World) => {
  if (!existsSync(join(w.root, ".git"))) gitInit(w.root)
  const bare = mkdtempSync(join(tmpdir(), "rails-origin-"))
  execFileSync("git", ["init", "-q", "--bare", bare])
  git(w.root, "remote", "add", "origin", bare)
  git(w.root, "push", "-q", "origin", "HEAD:refs/heads/feat-cmux-next")
  ;(w.deps as { landedRemote?: RegExp }).landedRemote = /./
  return bare
}
const git = (root: string, ...a: Array<string>) => execFileSync("git", ["-C", root, "-c", "user.email=t@t", "-c", "user.name=t", ...a], { encoding: "utf8" })

beforeAll(() => requireScratch())
afterAll(async () => {
  const s = await adminSql()
  const leftovers = (await s.query<{ datname: string }>("SELECT datname FROM pg_database WHERE datname ~ '^rr'")).map((r) => r.datname)
  for (const db of [...new Set([...created, ...leftovers])]) await dropDb(db)
  for (const role of roles) await s.query(`DROP ROLE IF EXISTS "${role}"`).catch(() => undefined)
  await s.end()
})

describe("apply rehearses in the same run, under the same lock", () => {
  it("rehearses on a throwaway copy (deleted by exact name), then applies; idempotent; the gate passes", async () => {
    const w = await world()
    expect(await w.run("apply", ...S)).toBe(0)
    const [branch] = branchesMade(w)
    expect(branch).toMatch(/^rh-cmux-vm-staging-\d{14}-[0-9a-f]{4}$/)
    expect(w.provider.calls).toContain(`delete cmux-prod/${branch}`)
    expect(await w.provider.exists("cmux-prod", branch!)).toBe(false)
    expect(await rows(w, w.staging)).toEqual(readMigrations(w.root, vm).map((f) => f.name))
    expect(w.logs.some((l) => l.startsWith("bd-summary: db-release apply cmux-vm/staging PASS"))).toBe(true)
    expect(await w.run("apply", ...S)).toBe(0)
    expect(w.logs.at(-1)).toContain("nothing to do")
    expect(await w.run("gate", ...S)).toBe(0)
    expect(readReceipts(w.receipts).map((r) => `${r.action}:${r.result}`)).toEqual(["branch-created:pass", "branch-deleted:pass", "rehearse:pass", "apply:pass"])
  })

  it("P2-6 a forged passing rehearsal receipt does not let a failing migration through", async () => {
    const w = await world()
    expect(await w.run("apply", ...S)).toBe(0)
    addMigration(w.root, "cmux-vm", "0010_bad.sql", "CREATE TABLE cmux_vm.bad (id text REFERENCES cmux_vm.nope (id));\n")
    addRequirement(w.root, '{ table: "cmux_vm.bad", migration: "0010" }')
    for (const set of ["any", "c503862df1a7"]) writeReceipt(w.receipts, { action: "rehearse", tree: "cmux-vm", target: "staging", result: "pass", at: new Date(w.clock).toISOString(), setHash: set, branchDeleted: true, by: "forged" })
    expect(await w.run("apply", ...S)).toBe(1)
    expect(w.errors.join()).toContain("0010_bad.sql")
    for (const b of branchesMade(w)) expect(await w.provider.exists("cmux-prod", b)).toBe(false)
    expect((await rows(w, w.staging)).length).toBe(9)
  })

  it("P2-7 takes the database lock before anything else: a held lock refuses before any branch exists", async () => {
    const w = await world()
    const holder = await w.owner(w.staging)
    await holder.query("SELECT pg_advisory_lock($1)", [vm.lockKey])
    expect(await w.run("apply", ...S)).toBe(1)
    expect(w.errors.at(-1)).toContain("another migration run holds")
    expect(branchesMade(w)).toEqual([])
    await holder.query("SELECT pg_advisory_unlock($1)", [vm.lockKey])
    await holder.end()
    writeFileSync(join(w.receipts, "apply-cmux-vm-staging.lock"), `1 ${new Date().toISOString()}\n`)
    expect(await w.run("apply", ...S)).toBe(1)
    expect(w.errors.at(-1)).toContain("another db-release run holds")
    writeFileSync(join(w.receipts, "apply-cmux-vm-staging.lock"), `1 ${new Date(Date.now() - 3 * HOUR).toISOString()}\n`)
    expect(await w.run("apply", ...S)).toBe(0)
    expect(readdirSync(w.receipts).some((f) => f.endsWith(".lock"))).toBe(false)
  })

  it("a stale copy (backup older than the target) fails, and the target is untouched", async () => {
    const w = await world()
    expect(await w.run("apply", ...S)).toBe(0)
    addExtra(w)
    const empty = `${w.staging}_empty`.slice(0, 63)
    await createOwnedDb(empty, w.provider.owner)
    created.push(empty)
    w.provider.staleFrom = empty
    expect(await w.run("apply", ...S)).toBe(1)
    expect(w.errors.join()).toContain("differs from staging")
    expect((await rows(w, w.staging)).length).toBe(9)
  })

  it("a create that fails after the branch appeared still deletes that branch", async () => {
    const w = await world()
    w.provider.failCreate = true
    expect(await w.run("rehearse", ...S)).toBe(1)
    const [branch] = branchesMade(w)
    expect(await w.provider.exists("cmux-prod", branch!)).toBe(false)
    expect(readReceipts(w.receipts).some((r) => r.action === "branch-deleted" && r.branch === branch)).toBe(true)
  })

  it("cleanup deletes a stranded rehearsal branch by its exact name and nothing else", async () => {
    const w = await world()
    const stranded = "rh-cmux-vm-staging-20261008120000-abcd"
    await createOwnedDb(w.provider.dbOf("cmux-prod", stranded), w.provider.owner)
    created.push(w.provider.dbOf("cmux-prod", stranded))
    writeReceipt(w.receipts, { action: "branch-created", tree: "cmux-vm", target: "staging", result: "pass", at: new Date(w.clock).toISOString(), branch: stranded, by: "test" })
    writeReceipt(w.receipts, { action: "branch-created", tree: "cmux-vm", target: "staging", result: "pass", at: new Date(w.clock).toISOString(), branch: "staging", by: "forged" })
    expect(await w.run("cleanup")).toBe(0)
    expect(w.provider.calls.filter((c) => c.startsWith("delete"))).toEqual([`delete cmux-prod/${stranded}`])
    expect(await w.provider.exists("cmux-prod", "staging")).toBe(true)
  })
})

describe("who may apply", () => {
  it("P2-8 refuses when the owner role cannot be looked up (a tree whose owner is a PlanetScale role)", async () => {
    const w = await world()
    ;(w.deps as { ownerPgRole?: string | null }).ownerPgRole = null
    ;(w.provider as { roleUser: FakeProvider["roleUser"] }).roleUser = async () => {
      throw new Error("pscale: not authenticated")
    }
    expect(await w.run("apply", ...S)).toBe(1)
    expect(w.errors.at(-1)).toContain("cannot confirm the owner role")
    expect(await rows(w, w.staging)).toEqual([])
  })

  it("refuses credentials that are not the target's owner role", async () => {
    const w = await world()
    ;(w.deps as { ownerPgRole?: string | null }).ownerPgRole = "cmux_vm_owner_role"
    expect(await w.run("apply", ...S)).toBe(1)
    expect(w.errors.at(-1)).toContain("not the owner cmux_vm_owner_role")
  })

  it("P0 refuses an owner with power in schema public; staging alone has a loud, recorded allowance", async () => {
    const w = await world()
    for (const db of [w.staging, w.production]) {
      const s = await w.admin(db)
      await s.query("CREATE TABLE public.users (id text PRIMARY KEY)")
      await s.query(`GRANT INSERT, UPDATE, DELETE ON public.users TO "${w.provider.owner}"`)
      await s.end()
    }
    expect(await w.run("apply", ...S)).toBe(1)
    expect(w.errors.at(-1)).toContain("can write public.users")
    expect(await w.run("apply", ...S, "--allow-broad-owner-on-staging")).toBe(0)
    expect(w.logs.join("\n")).toContain("WARNING: the owner role can write outside cmux_vm")
    expect(readReceipts(w.receipts).filter((r) => r.action === "apply").at(-1)?.warnings?.join()).toContain("--allow-broad-owner-on-staging")
    landed(w)
    expect(await w.run("apply", ...P, "--allow-broad-owner-on-staging")).toBe(1)
    expect(w.errors.join()).toContain("never on production")
  })
})

describe("production", () => {
  it("refuses without --confirm-production, outside a clean checkout landed on manaflow-ai/cmux feat-cmux-next, without cmux-old compat, and while staging lacks the files", async () => {
    const w = await world()
    expect(await w.run("apply", ...P.filter((a) => a !== "--confirm-production"))).toBe(1)
    expect(w.errors.at(-1)).toContain("--confirm-production")
    expect(await w.run("apply", ...P)).toBe(1)
    expect(w.errors.at(-1)).toContain("not a git checkout")
    gitInit(w.root)
    expect(await w.run("apply", ...P)).toBe(1)
    expect(w.errors.at(-1)).toContain("is not manaflow-ai/cmux")
    landed(w)
    addExtra(w)
    expect(await w.run("apply", ...P)).toBe(1)
    expect(w.errors.at(-1)).toContain("uncommitted migration changes")
    git(w.root, "add", ".")
    git(w.root, "commit", "-qm", "0010 not landed")
    expect(await w.run("apply", ...P)).toBe(1)
    expect(w.errors.at(-1)).toContain("is not on origin/feat-cmux-next")
    git(w.root, "push", "-q", "origin", "HEAD:refs/heads/feat-cmux-next")
    writeFileSync(join(w.root, "scripts/cmux-next/release/role-contract.json"), readFileSync(join(w.root, "scripts/cmux-next/release/role-contract.json"), "utf8").replace('"grantees": []', '"grantees": ["anyone"]'))
    expect(await w.run("apply", ...P)).toBe(1)
    expect(w.errors.at(-1)).toContain("uncommitted migration changes")
    git(w.root, "checkout", "-q", "--", "scripts/cmux-next/release/role-contract.json")
    expect(await w.run("apply", ...P, "--root", w.root)).toBe(1)
    expect(w.errors.at(-1)).toContain("--root")
    w.compatProblems = ["cmux-old replay: GET /api/vm answered 404"]
    expect(await w.run("apply", ...P)).toBe(1)
    expect(w.errors.at(-1)).toContain("GET /api/vm answered 404")
    w.compatProblems = []
    expect(await w.run("apply", ...P)).toBe(1)
    expect(w.errors.at(-1)).toContain("staging does not have")
    expect(await w.run("apply", ...S)).toBe(0)
    expect(await w.run("apply", ...P)).toBe(0)
    expect((await rows(w, w.production)).length).toBe(10)
  })

  it("a production rehearsal that cannot act as the owner role fails (staging only warns)", async () => {
    const w = await world()
    landed(w)
    expect(await w.run("apply", ...S)).toBe(0)
    const stranger = `${w.provider.owner}_x`.slice(0, 60)
    await (await adminSql()).query(`CREATE ROLE "${stranger}" LOGIN PASSWORD 'pw'`)
    roles.push(stranger)
    ;(w.provider as { copyUrl: FakeProvider["copyUrl"] }).copyUrl = async () => undefined
    ;(w.provider as { connectRole: FakeProvider["connectRole"] }).connectRole = async () => undefined
    ;(w.provider as { connectDefault: FakeProvider["connectDefault"] }).connectDefault = async (database, branch) => {
      const u = new URL(dbUrl(w.provider.dbOf(database, branch)))
      u.username = stranger
      u.password = "pw"
      return { url: u.toString(), release: async () => {} }
    }
    expect(await w.run("apply", ...P)).toBe(1)
    expect(w.errors.join("\n")).toContain("a production rehearsal must run as the owner")
  })
})

describe("re-review: broader owner checks and session-mode connections", () => {
  const grantAndRefuse = async (setup: (owner: string) => string, expected: string) => {
    const w = await world()
    const s = await w.admin(w.staging)
    for (const q of setup(w.provider.owner).split(";").filter((x) => x.trim())) await s.query(q)
    await s.end()
    expect(await w.run("apply", ...S)).toBe(1)
    expect(w.errors.at(-1)).toContain(expected)
  }
  it("refuses an owner that can read a public table", () => grantAndRefuse((o) => `CREATE TABLE public.users (id text); GRANT SELECT ON public.users TO "${o}"`, "can read public.users"))
  it("refuses an owner that can use a public sequence", () => grantAndRefuse((o) => `CREATE SEQUENCE public.users_id_seq; GRANT USAGE ON SEQUENCE public.users_id_seq TO "${o}"`, "can use or update sequence public.users_id_seq"))
  it("refuses an owner that owns a function outside cmux_vm", () => grantAndRefuse((o) => `CREATE FUNCTION public.f() RETURNS int LANGUAGE sql AS 'select 1'; ALTER FUNCTION public.f() OWNER TO "${o}"`, "owns objects outside cmux_vm"))
  it("refuses a pooler (port 6432) for apply: session locks and SET would not hold", async () => {
    const w = await world()
    const u = new URL(w.provider.ownerUrl(w.staging))
    u.port = "6432"
    w.setEnv("POOLED_URL", u.toString())
    expect(await w.run("apply", "--tree", "cmux-vm", "--target", "staging", "--url-env", "POOLED_URL")).toBe(1)
    expect(w.errors.at(-1)).toContain("pooler")
  })
})

describe("special files", () => {
  it("a contract migration applies only with --allow-contract naming it", async () => {
    const w = await world()
    expect(await w.run("apply", ...S)).toBe(0)
    addMigration(w.root, "cmux-vm", "0010_drop_labels_idx.sql", "-- contract: the labels index is unused since the search moved to the API\nDROP INDEX IF EXISTS cmux_vm.resources_labels_idx;\n")
    addRequirement(w.root, '{ table: "cmux_vm.resources", migration: "0010" }')
    expect(await w.run("apply", ...S)).toBe(1)
    expect(w.errors.join()).toContain("--allow-contract")
    expect(await w.run("apply", ...S, "--allow-contract", "0010_drop_labels_idx.sql")).toBe(0)
  })

  it("CREATE INDEX CONCURRENTLY runs outside a transaction and leaves a valid index", async () => {
    const w = await world()
    addMigration(w.root, "cmux-vm", "0010_resources_created_by.sql", "CREATE INDEX CONCURRENTLY IF NOT EXISTS resources_created_by ON cmux_vm.resources (created_by);\n")
    addRequirement(w.root, '{ table: "cmux_vm.resources_created_by", migration: "0010" }')
    expect(await w.run("apply", ...S)).toBe(0)
    const s = await w.admin(w.staging)
    const [row] = await s.query<{ v: boolean }>("SELECT indisvalid AS v FROM pg_index WHERE indexrelid = 'cmux_vm.resources_created_by'::regclass")
    await s.end()
    expect(row?.v).toBe(true)
  })

  it("an untracked database (applied by hand): plan refuses, adopt records it, apply continues from there", async () => {
    const w = await world()
    const s = await w.owner(w.staging)
    for (const f of readMigrations(w.root, vm)) await s.query(f.sql)
    await s.end()
    expect(await w.run("plan", ...S)).toBe(1)
    expect(w.errors.at(-1)).toContain("adopt")
    addExtra(w)
    expect(await w.run("rehearse", ...S, "--adopt-through", "0008")).toBe(0)
    expect(await w.run("adopt", ...S, "--through", "0008")).toBe(0)
    expect(await w.run("apply", ...S)).toBe(0)
    expect((await rows(w, w.staging)).at(-1)).toBe("0010_extra.sql")
  })

  it("adopt refuses a database that lacks what it would record", async () => {
    const w = await world()
    const s = await w.owner(w.staging)
    await s.query("CREATE SCHEMA cmux_vm; CREATE TABLE cmux_vm.resources (cmux_id text)")
    await s.end()
    expect(await w.run("adopt", ...S, "--through", "0008")).toBe(1)
    expect(w.errors.at(-1)).toContain("lacks what migrations up to 0008 add")
  })

  it("rehearse and apply refuse a tree the linter refuses, before any branch", async () => {
    const w = await world()
    addMigration(w.root, "cmux-vm", "0010_drop.sql", "DROP TABLE cmux_vm.audit_log;\n")
    expect(await w.run("rehearse", ...S)).toBe(1)
    expect(w.errors.at(-1)).toContain("migration lint refuses this tree")
    expect(await w.run("apply", ...S)).toBe(1)
    expect(branchesMade(w)).toEqual([])
  })
})

describe("deploy ordering gate (reads the database)", () => {
  it("refuses a commit whose migration is not applied: the 2026-10-07 incident (code needing 0008 ran ahead of it)", async () => {
    const w = await world()
    expect(await w.run("apply", ...S)).toBe(0)
    const s = await w.owner(w.staging)
    await s.query("DROP TABLE cmux_vm.stack_webhook_events; DELETE FROM cmux_vm.schema_migrations WHERE version LIKE '0008%'")
    await s.end()
    expect(await w.run("gate", ...S)).toBe(1)
    const text = w.errors.join("\n")
    expect(text).toContain("lacks migration(s) this commit ships: 0008_cmux_vm_mesh_m4_retries.sql")
    expect(text).toContain("cmux_vm.stack_webhook_events: missing (the Worker would answer 503)")
  })

  it("refuses when the deploy role lacks a privilege the Worker needs, and warns when it cannot read the tracking table", async () => {
    const w = await world()
    expect(await w.run("apply", ...S)).toBe(0)
    const role = `${w.provider.owner}_worker`.slice(0, 60)
    const a = await adminSql()
    await a.query(`CREATE ROLE "${role}" LOGIN PASSWORD 'pw'`)
    roles.push(role)
    const s = await w.owner(w.staging)
    await s.query(`GRANT USAGE ON SCHEMA cmux_vm TO "${role}"; GRANT SELECT ON ALL TABLES IN SCHEMA cmux_vm TO "${role}"; REVOKE SELECT ON cmux_vm.schema_migrations FROM "${role}"`)
    const url = new URL(dbUrl(w.staging))
    url.username = role
    url.password = "pw"
    w.setEnv("WORKER_URL", url.toString())
    const asWorker = ["--tree", "cmux-vm", "--target", "staging", "--url-env", "WORKER_URL"]
    expect(await w.run("gate", ...asWorker)).toBe(1)
    expect(w.errors.join("\n")).toContain("stack_webhook_events: no INSERT privilege")
    expect(w.logs.join("\n")).toContain("cannot read cmux_vm.schema_migrations")
    await s.query(`GRANT SELECT, INSERT, UPDATE ON cmux_vm.stack_webhook_events TO "${role}"`)
    expect(await w.run("gate", ...asWorker)).toBe(0)
    await s.query(`REVOKE ALL ON ALL TABLES IN SCHEMA cmux_vm FROM "${role}"; REVOKE ALL ON SCHEMA cmux_vm FROM "${role}"`)
    await s.end()
  })

  it("refuses a URL for another PlanetScale branch without printing its password", async () => {
    const w = await world()
    ;(w.deps as { allowScratchUrls?: boolean }).allowScratchUrls = false
    w.setEnv("WRONG_URL", "postgresql://pscale_api_abc.pj68ww4tuq8x:hunter2secret@aws.example/postgres")
    expect(await w.run("gate", "--tree", "cmux-vm", "--target", "staging", "--url-env", "WRONG_URL")).toBe(1)
    expect(w.errors.at(-1)).toContain("is not for cmux-prod/staging")
    expect([...w.errors, ...w.logs].join("\n")).not.toContain("hunter2secret")
  })

  it("P3 releases the read role when its connection fails", async () => {
    const w = await world()
    ;(w.provider as { connect: FakeProvider["connect"] }).connect = async (database, branch) => ({ url: "postgres://nobody:x@127.0.0.1:1/none", release: async () => void w.provider.calls.push(`release ${database}/${branch}`) })
    expect(await w.run("plan", "--tree", "cmux-vm", "--target", "staging")).toBe(1)
    expect(w.provider.calls).toContain("release cmux-prod/staging")
  })
})

describe("acceptance migration 0009 and the receipt format", () => {
  it("applies the landed 0009 (a contract migration, --allow-contract); the receipt names what, ids and hashes, before/after, rollback and the run", async () => {
    const w = await world()
    w.setEnv("GITHUB_RUN_ID", "4242")
    expect(await w.run("apply", ...S.filter((a) => !a.startsWith("--allow") && !a.startsWith("0009")))).toBe(1)
    expect(w.errors.join()).toContain("--allow-contract")
    expect(await w.run("apply", ...S)).toBe(0)
    const sql = readFileSync(join(w.root, "workers/cmux-vm/migrations/0009_cmux_vm_mesh_device_address.sql"), "utf8")
    expect(sha256(sql)).toBe("dcd032132b00d3592058415a530b40cef240a7e22b655f7a13ccb7a81ad23d48")
    const apply = readReceipts(w.receipts).filter((r) => r.action === "apply").at(-1)!
    expect(apply.what).toContain("0009_cmux_vm_mesh_device_address.sql")
    expect(apply.target).toBe("staging")
    expect(apply.pending?.at(-1)).toEqual({ name: "0009_cmux_vm_mesh_device_address.sql", checksum: sha256(sql) })
    expect(apply.before).toEqual([])
    expect(apply.after?.at(-1)).toBe("0009_cmux_vm_mesh_device_address.sql")
    expect(apply.rollback?.[0]).toContain("wrangler rollback")
    expect(apply.rollback?.[1]).toContain("ALTER TABLE cmux_vm.mesh_devices DROP COLUMN IF EXISTS public_ipv6")
    expect(apply.runId).toBe("gh:4242/1")
  })
})

describe("design B, D, F, G (third review)", () => {
  const refusedWith = async (setup: (owner: string) => string, expected: string) => {
    const w = await world()
    const s = await w.admin(w.staging)
    for (const q of setup(w.provider.owner).split(";").filter((x) => x.trim())) await s.query(q)
    await s.end()
    expect(await w.run("apply", ...S)).toBe(1)
    expect(w.errors.at(-1)).toContain(expected)
  }
  it("B refuses an owner with BYPASSRLS", () => refusedWith((o) => `ALTER ROLE "${o}" BYPASSRLS`, "bypasses row level security"))
  it("B refuses an owner in a predefined pg_* role", () => refusedWith((o) => `GRANT pg_read_all_data TO "${o}"`, "is a member of pg_read_all_data"))
  it("B refuses an owner that can execute a SECURITY DEFINER function outside cmux_vm", () =>
    refusedWith(() => `CREATE FUNCTION public.sd() RETURNS int LANGUAGE sql SECURITY DEFINER AS 'select 1'`, "can execute SECURITY DEFINER public.sd"))
  it("B refuses a session whose session_user is not the owner (SET ROLE through the URL)", async () => {
    const w = await world()
    const other = `${w.provider.owner}_s`.slice(0, 60)
    const a = await adminSql()
    await a.query(`CREATE ROLE "${other}" LOGIN PASSWORD 'pw'; GRANT "${w.provider.owner}" TO "${other}"`)
    roles.push(other)
    const u = new URL(dbUrl(w.staging))
    u.username = other
    u.password = "pw"
    u.searchParams.set("options", `-c role=${w.provider.owner}`)
    w.setEnv("SU_URL", u.toString())
    expect(await w.run("apply", "--tree", "cmux-vm", "--target", "staging", "--url-env", "SU_URL")).toBe(1)
    expect(w.errors.at(-1)).toContain("session_user")
  })
  it("B production refuses database CREATE after the bootstrap apply", async () => {
    const w = await world()
    landed(w)
    expect(await w.run("apply", ...S)).toBe(0)
    expect(await w.run("apply", ...P)).toBe(0) // bootstrap: the pending set creates the schema
    addExtra(w)
    git(w.root, "add", ".")
    git(w.root, "commit", "-qm", "0010")
    git(w.root, "push", "-q", "origin", "HEAD:refs/heads/feat-cmux-next")
    expect(await w.run("apply", ...S)).toBe(0)
    expect(await w.run("apply", ...P)).toBe(1)
    expect(w.errors.at(-1)).toContain("CREATE on the database")
  })
  it("D production reads migration files from git at the verified commit, not from disk", async () => {
    const w = await world()
    writeFileSync(join(w.root, ".gitignore"), "workers/cmux-vm/migrations/0011_*.sql\n")
    landed(w)
    expect(await w.run("apply", ...S)).toBe(0)
    writeFileSync(join(w.root, "workers/cmux-vm/migrations/0011_ignored.sql"), "CREATE TABLE cmux_vm.ignored (id text);\n")
    expect(await w.run("apply", ...P)).toBe(0)
    expect(await rows(w, w.production)).not.toContain("0011_ignored.sql")
    expect(readReceipts(w.receipts).filter((r) => r.action === "apply").at(-1)?.what).toContain("from git")
  })
  it("F production refuses the test-only compat overrides in the environment", async () => {
    const w = await world()
    landed(w)
    w.setEnv("CMUX_OLD_STAGING_ORIGIN", "http://127.0.0.1:1")
    expect(await w.run("apply", ...P)).toBe(1)
    expect(w.errors.at(-1)).toContain("CMUX_OLD_STAGING_ORIGIN")
  })
  it("G a production rehearsal whose copy login is not the owner fails", async () => {
    const w = await world()
    landed(w)
    expect(await w.run("apply", ...S)).toBe(0)
    const stranger = `${w.provider.owner}_g`.slice(0, 60)
    await (await adminSql()).query(`CREATE ROLE "${stranger}" LOGIN PASSWORD 'pw'`)
    roles.push(stranger)
    ;(w.provider as { copyUrl: FakeProvider["copyUrl"] }).copyUrl = async (database, branch) => {
      const u = new URL(dbUrl(w.provider.dbOf(database, branch)))
      u.username = stranger
      u.password = "pw"
      return u.toString()
    }
    expect(await w.run("apply", ...P)).toBe(1)
    expect(w.errors.join("\n")).toContain(`runs as ${stranger}, not the owner`)
  })
})

describe("rails-hardening-1: owner checks, bootstrap and the environment (P3)", () => {
  const refusedWith = async (setup: (owner: string) => string, expected: string) => {
    const w = await world()
    const s = await w.admin(w.staging)
    for (const q of setup(w.provider.owner).split(";").filter((x) => x.trim())) await s.query(q)
    await s.end()
    expect(await w.run("apply", ...S)).toBe(1)
    expect(w.errors.at(-1)).toContain(expected)
  }
  it("P3-9 refuses a column-level grant on a public table", () => refusedWith((o) => `CREATE TABLE public.users (id text, email text); GRANT SELECT (email) ON public.users TO "${o}"`, "has column privileges on public.users"))
  it("P3-9 refuses CREATE on another schema", () => refusedWith((o) => `CREATE SCHEMA other; GRANT CREATE ON SCHEMA other TO "${o}"`, "has CREATE on schema other"))
  it("P3-9 refuses CREATEDB", () => refusedWith((o) => `ALTER ROLE "${o}" CREATEDB`, "can create databases"))
  it("P3-8 a pending CREATE SCHEMA is no bootstrap when the schema already exists", async () => {
    const w = await world()
    landed(w)
    const p = await w.admin(w.production)
    await p.query(`CREATE SCHEMA cmux_vm AUTHORIZATION "${w.provider.owner}"`)
    await p.end()
    expect(await w.run("apply", ...S)).toBe(0)
    expect(await w.run("apply", ...P)).toBe(1)
    expect(w.errors.at(-1)).toContain("CREATE on the database")
  })
  it("P3-2 production refuses NODE_OPTIONS and BUN_OPTIONS", async () => {
    const w = await world()
    landed(w)
    w.setEnv("NODE_OPTIONS", "--require /tmp/x.js")
    expect(await w.run("apply", ...P)).toBe(1)
    expect(w.errors.at(-1)).toContain("NODE_OPTIONS")
  })
  it("P3-3 DROP INDEX CONCURRENTLY runs outside a transaction", async () => {
    const w = await world()
    expect(await w.run("apply", ...S)).toBe(0)
    addMigration(w.root, "cmux-vm", "0010_drop_idx.sql", "-- contract: the labels index is unused since the search moved to the API\nDROP INDEX CONCURRENTLY IF EXISTS cmux_vm.resources_labels_idx;\n")
    addRequirement(w.root, '{ table: "cmux_vm.resources", migration: "0010" }')
    expect(await w.run("apply", ...S, "--allow-contract", "0010_drop_idx.sql")).toBe(0)
    const s = await w.admin(w.staging)
    expect((await s.query<{ v: string | null }>("SELECT to_regclass('cmux_vm.resources_labels_idx')::text AS v"))[0]?.v).toBeNull()
    await s.end()
  })
})

describe("rails-hardening-2 (fifth review follow-up)", () => {
  it("(3) a production adopt refuses runtime injection", async () => {
    const w = await world()
    landed(w)
    w.setEnv("NODE_OPTIONS", "--require /tmp/x.js")
    expect(await w.run("adopt", "--tree", "cmux-vm", "--target", "production", "--url-env", "PROD_URL", "--through", "0008", "--confirm-production")).toBe(1)
    expect(w.errors.at(-1)).toContain("NODE_OPTIONS")
  })
  it("(4) a DROP INDEX CONCURRENTLY rerun after the index is already gone records the file", async () => {
    const w = await world()
    expect(await w.run("apply", ...S)).toBe(0)
    const s = await w.owner(w.staging)
    await s.query("DROP INDEX cmux_vm.resources_labels_idx")
    await s.end()
    addMigration(w.root, "cmux-vm", "0010_drop_idx.sql", "-- contract: the labels index is unused since the search moved to the API\nDROP INDEX CONCURRENTLY cmux_vm.resources_labels_idx;\n")
    addRequirement(w.root, '{ table: "cmux_vm.resources", migration: "0010" }')
    expect(await w.run("apply", ...S, "--allow-contract", "0010_drop_idx.sql")).toBe(0)
    expect((await rows(w, w.staging)).at(-1)).toBe("0010_drop_idx.sql")
  })
})
