/**
 * db-release.ts end to end on a scratch Postgres (SCRATCH_URL). A "branch" is a
 * database; the fake provider creates rehearsal branches with CREATE DATABASE
 * ... TEMPLATE (schema and data, like a PlanetScale Postgres branch).
 */
import { afterAll, beforeAll, describe, expect, it } from "bun:test"
import { mkdtempSync, readdirSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { main, type Deps } from "../db-release.ts"
import { readMigrations } from "../lint.ts"
import { readReceipts } from "../receipts.ts"
import { connectUrl, type Sql } from "../runner.ts"
import { TREES } from "../trees.ts"
import { adminSql, createDb, dbUrl, dropDb, fakeProvider, requireScratch, SCRATCH_URL, tempRoot, uniquePrefix, addMigration, type FakeProvider } from "./helpers.ts"

const vm = TREES["cmux-vm"]
const created: Array<string> = []
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
  run(...argv: Array<string>): Promise<number>
  sql(db: string): Promise<Sql>
}

const world = async (): Promise<World> => {
  const prefix = uniquePrefix()
  const provider = fakeProvider(prefix)
  const staging = provider.dbOf("cmux-prod", "staging")
  const production = provider.dbOf("cmux-prod", "main")
  for (const db of [staging, production]) {
    await createDb(db)
    created.push(db)
  }
  const root = tempRoot()
  const receipts = mkdtempSync(join(tmpdir(), "rails-receipts-"))
  const logs: Array<string> = []
  const errors: Array<string> = []
  const opened: Array<Sql> = []
  const w: World = {
    root,
    receipts,
    provider,
    logs,
    errors,
    staging,
    production,
    clock: Date.parse("2026-10-08T12:00:00Z"),
    deps: undefined as unknown as Deps,
    run: (...argv) => main(argv, w.deps),
    sql: async (db) => {
      const s = await connectUrl(dbUrl(db))
      opened.push(s)
      return s
    },
  }
  ;(w as { deps: Deps }).deps = {
    provider,
    connect: connectUrl,
    env: { CMUX_RELEASE_RECEIPTS_DIR: receipts, STAGING_URL: dbUrl(staging), PROD_URL: dbUrl(production) },
    root,
    now: () => new Date(w.clock),
    log: (l) => logs.push(l),
    error: (l) => errors.push(l),
    allowScratchUrls: true,
  }
  return w
}

const S = ["--tree", "cmux-vm", "--target", "staging", "--url-env", "STAGING_URL"]
const P = ["--tree", "cmux-vm", "--target", "production", "--url-env", "PROD_URL"]

const rows = async (w: World, db: string) => {
  const s = await w.sql(db)
  try {
    return (await s.query<{ version: string }>("SELECT version FROM cmux_vm.schema_migrations ORDER BY version")).map((r) => r.version)
  } finally {
    await s.end()
  }
}

const rehearsalBranches = (w: World) => w.provider.calls.filter((c) => c.startsWith("create ")).map((c) => c.split(" ")[1]!.split("/")[1]!)

beforeAll(() => requireScratch())
afterAll(async () => {
  const s = await adminSql()
  const leftovers = (await s.query<{ datname: string }>("SELECT datname FROM pg_database WHERE datname ~ '^rr'")).map((r) => r.datname)
  for (const db of [...new Set([...created, ...leftovers])]) await dropDb(db)
  await s.end()
})

describe("rehearse, then apply", () => {
  it("refuses apply without a rehearsal; a rehearsal on a throwaway copy passes, deletes its branch by name, and unlocks apply", async () => {
    const w = await world()
    expect(await w.run("apply", ...S)).toBe(1)
    expect(w.errors.join()).toContain("no passing rehearsal")

    expect(await w.run("rehearse", ...S)).toBe(0)
    const [branch] = rehearsalBranches(w)
    expect(branch).toMatch(/^rh-cmux-vm-staging-\d{14}-[0-9a-f]{4}$/)
    expect(w.provider.calls).toContain(`delete cmux-prod/${branch}`)
    expect(await w.provider.exists("cmux-prod", branch!)).toBe(false)
    expect(await rows(w, w.staging).catch(() => "no table")).toBe("no table") // the rehearsal never touched staging

    expect(await w.run("apply", ...S)).toBe(0)
    expect(await rows(w, w.staging)).toEqual(readMigrations(w.root, vm).map((f) => f.name))
    expect(w.logs.some((l) => l.startsWith("bd-summary: db-release apply cmux-vm/staging PASS"))).toBe(true)

    // Idempotent: nothing pending is a no-op pass; the gate now passes.
    expect(await w.run("apply", ...S)).toBe(0)
    expect(w.logs.at(-1)).toContain("nothing to do")
    expect(await w.run("gate", ...S)).toBe(0)

    const receipts = readReceipts(w.receipts).map((r) => `${r.action}:${r.result}`)
    expect(receipts).toEqual(["branch-created:pass", "branch-deleted:pass", "rehearse:pass", "apply:pass"])
  })

  it("refuses a rehearsal older than 24 h, and one of a different set", async () => {
    const w = await world()
    expect(await w.run("rehearse", ...S)).toBe(0)
    w.clock += 25 * HOUR
    expect(await w.run("apply", ...S)).toBe(1)
    expect(w.errors.at(-1)).toContain("last 24 h")

    w.clock -= 2 * HOUR
    addMigration(w.root, "cmux-vm", "0009_extra.sql", "CREATE TABLE IF NOT EXISTS cmux_vm.extra (id text PRIMARY KEY);\n")
    expect(await w.run("apply", ...S)).toBe(1) // the rehearsed set lacked 0009
    expect(await w.run("rehearse", ...S)).toBe(0)
    expect(await w.run("apply", ...S)).toBe(0)
    expect((await rows(w, w.staging)).at(-1)).toBe("0009_extra.sql")
  })

  it("production: refused without --confirm-production, refused until staging has the files, then passes", async () => {
    const w = await world()
    expect(await w.run("apply", ...P)).toBe(1)
    expect(w.errors.at(-1)).toContain("--confirm-production")
    expect(await w.run("rehearse", ...P)).toBe(0)
    expect(await w.run("apply", ...P, "--confirm-production", "--staging-url-env", "STAGING_URL")).toBe(1)
    expect(w.errors.at(-1)).toContain("staging does not have")
    expect(await w.run("rehearse", ...S)).toBe(0)
    expect(await w.run("apply", ...S)).toBe(0)
    expect(await w.run("apply", ...P, "--confirm-production", "--staging-url-env", "STAGING_URL")).toBe(0)
    expect((await rows(w, w.production)).length).toBe(8)
  })

  it("a migration that fails: the rehearsal fails, its branch is deleted, apply stays refused, staging is untouched", async () => {
    const w = await world()
    expect(await w.run("rehearse", ...S)).toBe(0)
    expect(await w.run("apply", ...S)).toBe(0)
    addMigration(w.root, "cmux-vm", "0009_bad.sql", "CREATE TABLE cmux_vm.bad (id text REFERENCES cmux_vm.nope (id));\n")
    expect(await w.run("rehearse", ...S)).toBe(1)
    expect(w.errors.join()).toContain("0009_bad.sql")
    const branches = rehearsalBranches(w)
    for (const b of branches) expect(await w.provider.exists("cmux-prod", b)).toBe(false)
    expect(readReceipts(w.receipts).filter((r) => r.action === "rehearse").at(-1)?.result).toBe("fail")
    expect(await w.run("apply", ...S)).toBe(1)
    expect((await rows(w, w.staging)).length).toBe(8)
  })

  it("a copy that differs from the target (stale backup) fails the rehearsal", async () => {
    const w = await world()
    expect(await w.run("rehearse", ...S)).toBe(0)
    expect(await w.run("apply", ...S)).toBe(0)
    addMigration(w.root, "cmux-vm", "0009_extra.sql", "CREATE TABLE IF NOT EXISTS cmux_vm.extra (id text PRIMARY KEY);\n")
    const empty = `${w.staging}_empty`.slice(0, 63)
    await createDb(empty)
    created.push(empty)
    w.provider.staleFrom = empty
    expect(await w.run("rehearse", ...S)).toBe(1)
    expect(w.errors.join()).toContain("differs from staging")
    expect(await w.run("apply", ...S)).toBe(1)
  })

  it("a create that fails after the branch appeared still deletes that branch", async () => {
    const w = await world()
    w.provider.failCreate = true
    expect(await w.run("rehearse", ...S)).toBe(1)
    const [branch] = rehearsalBranches(w)
    expect(await w.provider.exists("cmux-prod", branch!)).toBe(false)
    expect(readReceipts(w.receipts).some((r) => r.action === "branch-deleted" && r.branch === branch)).toBe(true)
  })

  it("cleanup deletes a stranded rehearsal branch by its exact name and nothing else", async () => {
    const w = await world()
    const stranded = "rh-cmux-vm-staging-20261008120000-abcd"
    await createDb(w.provider.dbOf("cmux-prod", stranded))
    created.push(w.provider.dbOf("cmux-prod", stranded))
    const { writeReceipt } = await import("../receipts.ts")
    writeReceipt(w.receipts, { action: "branch-created", tree: "cmux-vm", target: "staging", result: "pass", at: new Date(w.clock).toISOString(), branch: stranded, by: "test" })
    writeReceipt(w.receipts, { action: "branch-created", tree: "cmux-vm", target: "staging", result: "pass", at: new Date(w.clock).toISOString(), branch: "staging", by: "forged" })
    expect(await w.run("cleanup")).toBe(0)
    expect(w.provider.calls.filter((c) => c.startsWith("delete"))).toEqual([`delete cmux-prod/${stranded}`])
    expect(await w.provider.exists("cmux-prod", "staging")).toBe(true)
  })
})

describe("one run at a time", () => {
  it("refuses apply while another runner holds the database lock, and while a local lock is fresh", async () => {
    const w = await world()
    expect(await w.run("rehearse", ...S)).toBe(0)
    const holder = await w.sql(w.staging)
    await holder.query("SELECT pg_advisory_lock($1)", [vm.lockKey])
    expect(await w.run("apply", ...S)).toBe(1)
    expect(w.errors.at(-1)).toContain("another migration run holds")
    await holder.query("SELECT pg_advisory_unlock($1)", [vm.lockKey])
    await holder.end()

    writeFileSync(join(w.receipts, "apply-cmux-vm-staging.lock"), `1 ${new Date().toISOString()}\n`)
    expect(await w.run("apply", ...S)).toBe(1)
    expect(w.errors.at(-1)).toContain("another db-release run holds")
    writeFileSync(join(w.receipts, "apply-cmux-vm-staging.lock"), `1 ${new Date(Date.now() - 3 * HOUR).toISOString()}\n`)
    expect(await w.run("apply", ...S)).toBe(0) // a 3 h old lock is a crashed run
    expect(readdirSync(w.receipts).some((f) => f.endsWith(".lock"))).toBe(false)
  })
})

describe("special files", () => {
  it("a contract migration applies only with --allow-contract naming it", async () => {
    const w = await world()
    expect(await w.run("rehearse", ...S)).toBe(0)
    expect(await w.run("apply", ...S)).toBe(0)
    addMigration(w.root, "cmux-vm", "0009_drop_labels_idx.sql", "-- contract: the labels index is unused since the search moved to the API\nDROP INDEX IF EXISTS cmux_vm.resources_labels_idx;\n")
    expect(await w.run("rehearse", ...S)).toBe(1)
    expect(w.errors.join()).toContain("--allow-contract")
    expect(await w.run("rehearse", ...S, "--allow-contract", "0009_drop_labels_idx.sql")).toBe(0)
    expect(await w.run("apply", ...S)).toBe(1)
    expect(await w.run("apply", ...S, "--allow-contract", "0009_drop_labels_idx.sql")).toBe(0)
  })

  it("CREATE INDEX CONCURRENTLY runs outside a transaction and leaves a valid index", async () => {
    const w = await world()
    addMigration(w.root, "cmux-vm", "0009_resources_created_by.sql", "CREATE INDEX CONCURRENTLY IF NOT EXISTS resources_created_by ON cmux_vm.resources (created_by);\n")
    expect(await w.run("rehearse", ...S)).toBe(0)
    expect(await w.run("apply", ...S)).toBe(0)
    const s = await w.sql(w.staging)
    const [row] = await s.query<{ v: boolean }>("SELECT indisvalid AS v FROM pg_index WHERE indexrelid = 'cmux_vm.resources_created_by'::regclass")
    await s.end()
    expect(row?.v).toBe(true)
  })

  it("an untracked database (applied by hand): plan refuses, adopt records it, apply continues from there", async () => {
    const w = await world()
    const s = await w.sql(w.staging)
    for (const f of readMigrations(w.root, vm)) await s.query(f.sql)
    await s.end()
    expect(await w.run("plan", ...S)).toBe(1)
    expect(w.errors.at(-1)).toContain("adopt")
    addMigration(w.root, "cmux-vm", "0009_extra.sql", "CREATE TABLE IF NOT EXISTS cmux_vm.extra (id text PRIMARY KEY);\n")
    expect(await w.run("rehearse", ...S, "--adopt-through", "0008")).toBe(0)
    expect(await w.run("adopt", ...S, "--through", "0008")).toBe(0)
    expect(await w.run("apply", ...S)).toBe(0)
    expect((await rows(w, w.staging)).at(-1)).toBe("0009_extra.sql")
  })

  it("adopt refuses a database that lacks what it would record", async () => {
    const w = await world()
    const s = await w.sql(w.staging)
    await s.query("CREATE SCHEMA cmux_vm; CREATE TABLE cmux_vm.resources (cmux_id text)")
    await s.end()
    expect(await w.run("adopt", ...S, "--through", "0008")).toBe(1)
    expect(w.errors.at(-1)).toContain("lacks what migrations up to 0008 add")
  })
})

describe("deploy ordering gate (reads the database)", () => {
  const ready = async () => {
    const w = await world()
    expect(await w.run("rehearse", ...S)).toBe(0)
    expect(await w.run("apply", ...S)).toBe(0)
    return w
  }

  it("refuses a commit whose migration is not applied: the 2026-10-07 incident (code needing 0008 ran ahead of it)", async () => {
    const w = await ready()
    const s = await w.sql(w.staging)
    await s.query("DROP TABLE cmux_vm.stack_webhook_events; DELETE FROM cmux_vm.schema_migrations WHERE version LIKE '0008%'")
    await s.end()
    expect(await w.run("gate", ...S)).toBe(1)
    const text = w.errors.join("\n")
    expect(text).toContain("lacks migration(s) this commit ships: 0008_cmux_vm_mesh_m4_retries.sql")
    expect(text).toContain("cmux_vm.stack_webhook_events: missing (the Worker would answer 503)")
  })

  it("refuses when the deploy role lacks a privilege the Worker needs, and warns when it cannot read the tracking table", async () => {
    const w = await ready()
    const role = `${w.staging}_worker`.slice(0, 60)
    const s = await w.sql(w.staging)
    await s.query(`CREATE ROLE "${role}" LOGIN PASSWORD 'pw'`)
    await s.query(`GRANT USAGE ON SCHEMA cmux_vm TO "${role}"; GRANT SELECT ON ALL TABLES IN SCHEMA cmux_vm TO "${role}"`)
    await s.query(`REVOKE SELECT ON cmux_vm.schema_migrations FROM "${role}"`)
    const url = new URL(dbUrl(w.staging))
    url.username = role
    url.password = "pw"
    ;(w.deps.env as Record<string, string>).WORKER_URL = url.toString()
    const asWorker = ["--tree", "cmux-vm", "--target", "staging", "--url-env", "WORKER_URL"]
    expect(await w.run("gate", ...asWorker)).toBe(1)
    expect(w.errors.join("\n")).toContain("stack_webhook_events: no INSERT privilege")
    expect(w.logs.join("\n")).toContain("cannot read cmux_vm.schema_migrations")
    await s.query(`GRANT SELECT, INSERT, UPDATE ON cmux_vm.stack_webhook_events TO "${role}"`)
    expect(await w.run("gate", ...asWorker)).toBe(0)
    await s.query(`REVOKE ALL ON ALL TABLES IN SCHEMA cmux_vm FROM "${role}"; REVOKE ALL ON SCHEMA cmux_vm FROM "${role}"`)
    await s.end()
    const admin = await adminSql()
    await admin.query(`DROP ROLE "${role}"`)
  })

  it("refuses a URL for another PlanetScale branch without printing its password", async () => {
    const w = await world()
    ;(w.deps as { allowScratchUrls?: boolean }).allowScratchUrls = false
    ;(w.deps.env as Record<string, string>).WRONG_URL = "postgresql://pscale_api_abc.pj68ww4tuq8x:hunter2secret@aws.example/postgres"
    expect(await w.run("gate", "--tree", "cmux-vm", "--target", "staging", "--url-env", "WRONG_URL")).toBe(1)
    expect(w.errors.at(-1)).toContain("is not for cmux-prod/staging")
    expect([...w.errors, ...w.logs].join("\n")).not.toContain("hunter2secret")
  })
})

it("the scratch server is reachable", async () => {
  expect(SCRATCH_URL).not.toBe("")
  const s = await adminSql()
  expect((await s.query<{ one: number }>("SELECT 1 AS one"))[0]?.one).toBe(1)
})

describe("acceptance migration 0009 and the receipt format", () => {
  it("rehearses and applies 0009 (contract header, --allow-contract); the receipt names what, ids and hashes, before/after, rollback and the run", async () => {
    const w = await world()
    expect(await w.run("rehearse", ...S)).toBe(0)
    expect(await w.run("apply", ...S)).toBe(0)
    const { readFileSync } = await import("node:fs")
    const fixture = readFileSync(join(import.meta.dirname, "fixtures/0009_cmux_vm_mesh_device_address.sql"), "utf8")
    const sql = `-- contract: widens mesh_signed_requests_purpose_check to a superset (adds 'address'); old writes stay valid\n${fixture}`
    addMigration(w.root, "cmux-vm", "0009_cmux_vm_mesh_device_address.sql", sql)
    const allow = ["--allow-contract", "0009_cmux_vm_mesh_device_address.sql"]
    expect(await w.run("rehearse", ...S, ...allow)).toBe(0)
    ;(w.deps.env as Record<string, string>).GITHUB_RUN_ID = "4242"
    expect(await w.run("apply", ...S, ...allow)).toBe(0)
    const apply = readReceipts(w.receipts).filter((r) => r.action === "apply").at(-1)!
    expect(apply.what).toContain("0009_cmux_vm_mesh_device_address.sql")
    expect(apply.target).toBe("staging")
    expect(apply.pending).toEqual([{ name: "0009_cmux_vm_mesh_device_address.sql", checksum: (await import("../lint.ts")).sha256(sql) }])
    expect(apply.before?.length).toBe(8)
    expect(apply.after?.at(-1)).toBe("0009_cmux_vm_mesh_device_address.sql")
    expect(apply.rollback?.[0]).toContain("wrangler rollback")
    expect(apply.rollback?.[1]).toContain("ALTER TABLE cmux_vm.mesh_devices DROP COLUMN IF EXISTS public_ipv6")
    expect(apply.runId).toBe("gh:4242/1")
    const s = await w.sql(w.staging)
    const cols = await s.query<{ attname: string }>("SELECT attname FROM pg_attribute WHERE attrelid = 'cmux_vm.mesh_devices'::regclass AND attname LIKE 'public_ipv6%' ORDER BY 1")
    await s.end()
    expect(cols.map((c) => c.attname)).toEqual(["public_ipv6", "public_ipv6_at"])
  })

  it("rehearse and apply refuse a tree the linter refuses", async () => {
    const w = await world()
    addMigration(w.root, "cmux-vm", "0009_drop.sql", "DROP TABLE cmux_vm.audit_log;\n")
    expect(await w.run("rehearse", ...S)).toBe(1)
    expect(w.errors.at(-1)).toContain("migration lint refuses this tree")
    expect(w.provider.calls.filter((c) => c.startsWith("create"))).toEqual([])
  })
})
