import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { apply, rollback, status } from "./apply.ts"
import { httpPlatform, httpVmApi, mapTenantResolver } from "./clients.ts"
import { migrationIdFor, personalTeamIdFor, sharedTeamIdFor, userIdFor } from "./ids.ts"
import { Ledger } from "./ledger.ts"
import { buildPlan, classifyVm, copiesOf, renderPlanMarkdown, type Plan } from "./plan.ts"
import {
  assertSelectOnly,
  checkClassicHost,
  ClassicHostRefused,
  fixtureSource,
  readFixture,
  ReadOnlyViolation,
  readSubject,
  withReadOnlyTransaction,
  type ClassicVm,
  type FixtureFile,
  type OwnerTeamFacts,
  type PgConnection,
} from "./source.ts"

const DIR = import.meta.dirname
const MAIN = join(DIR, "main.ts")
const FIXTURE_PATH = join(DIR, "fixtures/staging-test.json")
const fixture = () => readFixture(FIXTURE_PATH)
const PROJECT = "00000000-0000-4000-8000-0000000057a6"
const ALICE = "11111111-1111-4111-8111-111111111111"
const BOB = "22222222-2222-4222-8222-222222222222"
const ACME = "bbbbbbbb-0000-4000-8000-000000000ac3"
const ALICE_TEAM = "aaaaaaaa-0000-4000-8000-00000000a11c"
const VM_LIVE = "c0000001-0000-4000-8000-000000000001"
const VM_DEAD = "c0000002-0000-4000-8000-000000000002"
const VM_ACME = "c0000003-0000-4000-8000-000000000003"
const ALICE_TENANT = "tenant_alice_personal"

let tmp: string
beforeAll(() => {
  tmp = mkdtempSync(join(tmpdir(), "classic-migrate-"))
})
afterAll(() => rmSync(tmp, { recursive: true, force: true }))

const planFor = async (subject: { kind: "user" | "team"; id: string }, f: FixtureFile = fixture()) =>
  buildPlan(await fixtureSource(f, "fixture").read(subject), PROJECT, "fixture")

const byKind = (plan: Plan, kind: string) => plan.entries.filter((e) => e.kind === kind)

describe("plan", () => {
  test("a user: identity carried, the live personal VM copied, the destroyed one not, the rest reported", async () => {
    const plan = await planFor({ kind: "user", id: ALICE })
    const aliceNext = userIdFor(PROJECT, ALICE)
    expect(plan.migration_id).toBe(migrationIdFor(PROJECT, { kind: "user", id: ALICE }))
    expect(plan.subject.next_team_id).toBe(personalTeamIdFor(aliceNext))
    expect(byKind(plan, "user")).toEqual([
      expect.objectContaining({
        action: "carried",
        next: { user_id: aliceNext, personal_team_id: personalTeamIdFor(aliceNext) },
      }),
    ])
    expect(byKind(plan, "membership").map((e) => e.action)).toEqual(["carried", "carried"])
    expect(byKind(plan, "plan_metadata")[0]?.summary).toBe("cmuxPlan=pro cmuxVmPlan=none")

    const vms = byKind(plan, "cloud_vm")
    expect(vms.map((e) => [e.classic_id, e.action])).toEqual([
      [VM_LIVE, "copy"],
      [VM_DEAD, "not-migrated"],
    ])
    expect(vms[0]?.personal_reason).toContain("only member is the creator")
    expect(vms[1]?.reason).toContain("destroyed")
    expect(copiesOf(plan)).toEqual([
      {
        classic_vm_id: VM_LIVE,
        upstream_vm_id: "fs-alice-dev",
        next_team_id: personalTeamIdFor(aliceNext),
        tenant: { kind: "personal", stack_user_id: ALICE, user_id: aliceNext },
        creator_user_id: aliceNext,
        name: "alice-dev",
        size: null,
      },
    ])
    expect(vms[0]?.next?.["vm_api_tenant"]).toBe("personal tenant (resolved at apply)")
    // Alice's personal Stack team is named as such: its VMs land in her NEXT personal team.
    expect(byKind(plan, "team").find((e) => e.classic_id === ALICE_TEAM)?.summary).toContain("personal Stack team")

    expect(byKind(plan, "stripe_customer")).toEqual([
      expect.objectContaining({ classic_id: "cus_alice", action: "link", next: { team_id: personalTeamIdFor(aliceNext) } }),
    ])
    for (const kind of [
      "classic_snapshot",
      "cloud_vm_publication",
      "cloud_vm_domain",
      "cloud_vm_tunnel",
      "coderouter_api_key",
      "runs",
      "vault_sessions",
    ]) {
      expect(byKind(plan, kind).length).toBe(1)
      expect(byKind(plan, kind)[0]?.action).toBe("not-migrated")
      expect(byKind(plan, kind)[0]?.reason).toBeTruthy()
    }
    expect(byKind(plan, "coderouter_api_key")[0]?.reason).toContain("stays valid on classic")
    expect(plan.counts).toEqual({ carried: 6, copy: 1, link: 1, "not-migrated": 8, "needs-decision": 0 })
  })

  test("a team: its VM lands in the shared team under the Stack team tenant, created by its creator", async () => {
    const plan = await planFor({ kind: "team", id: ACME })
    expect(plan.subject.next_team_id).toBe(sharedTeamIdFor(PROJECT, ACME))
    expect(copiesOf(plan)).toEqual([
      expect.objectContaining({
        classic_vm_id: VM_ACME,
        next_team_id: sharedTeamIdFor(PROJECT, ACME),
        tenant: { kind: "team", tenant_id: ACME },
        creator_user_id: userIdFor(PROJECT, BOB),
      }),
    ])
    expect(byKind(plan, "cloud_vm")[0]?.personal_reason).toBe(`shared: owner team ${ACME} has 2 members`)
    expect(byKind(plan, "stripe_customer").map((e) => e.classic_id)).toEqual(["cus_acme"])
  })

  test("a user's VM on a shared team is left to the team's migration", async () => {
    const f = fixture()
    f.tables.cloud_vms!.push({ ...f.tables.cloud_vms![2]!, id: "c0000004-0000-4000-8000-000000000004", user_id: ALICE })
    const plan = await planFor({ kind: "user", id: ALICE }, f)
    const e = plan.entries.find((x) => x.classic_id === "c0000004-0000-4000-8000-000000000004")
    expect(e?.action).toBe("not-migrated")
    expect(e?.reason).toContain(`--team ${ACME}`)
  })

  test("output is deterministic: same rows, same bytes, entries in a stable order", async () => {
    const a = await planFor({ kind: "user", id: ALICE })
    const f = fixture()
    for (const rows of Object.values(f.tables)) (rows as unknown[]).reverse()
    const b = await planFor({ kind: "user", id: ALICE }, f)
    expect(JSON.stringify(b)).toBe(JSON.stringify(a))
    expect(renderPlanMarkdown(b)).toBe(renderPlanMarkdown(a))
  })

  test("the CLI writes plan.json and plan.md", async () => {
    const out = join(tmp, "cli-plan")
    const r = await run(["plan", "--user", ALICE, "--source", "fixture", FIXTURE_PATH, "--out", out])
    expect(r.code).toBe(0)
    expect(r.stdout).toContain("counts: carried 6, copy 1, link 1, not-migrated 8")
    const plan = JSON.parse(readFileSync(join(out, "plan.json"), "utf8")) as Plan
    expect(plan).toEqual({ ...(await planFor({ kind: "user", id: ALICE })), source: `fixture ${FIXTURE_PATH}` })
    expect(readFileSync(join(out, "plan.md"), "utf8")).toContain("| cloud_vm | `" + VM_LIVE + "` | copy |")
  })
})

describe("personal or shared owner", () => {
  const vm = (owner: string | null, user = ALICE): ClassicVm => ({
    id: "v",
    user_id: user,
    owner_team_id: owner,
    billing_team_id: null,
    provider: "freestyle",
    provider_vm_id: "fs",
    display_name: null,
    slug: null,
    image_id: "i",
    image_version: null,
    status: "running",
    destroyed_at: null,
    provider_metadata: {},
  })
  const facts = (f: Partial<OwnerTeamFacts> & { id: string }): Map<string, OwnerTeamFacts> =>
    new Map([
      [
        f.id,
        {
          team: { id: f.id, display_name: "T", client_read_only_metadata: null },
          member_ids: [ALICE],
          team_subscription_ids: [],
          ...f,
        },
      ],
    ])

  test("owner_team_id = user id, empty or null is personal", () => {
    for (const o of [ALICE, "", null]) expect(classifyVm(vm(o), new Map()).owner).toBe("personal")
  })
  test("a team marker decides first", () => {
    const f = facts({
      id: "t",
      member_ids: [ALICE, BOB],
      team: { id: "t", display_name: "T", client_read_only_metadata: null, server_metadata: { isPersonal: true } },
    })
    expect(classifyVm(vm("t"), f)).toEqual({
      owner: "personal",
      reason: "owner team t is marked personal (server_metadata.isPersonal)",
    })
  })
  test("sole member = creator and no team subscription is personal", () => {
    expect(classifyVm(vm("t"), facts({ id: "t" })).owner).toBe("personal")
  })
  test("two or more members is shared", () => {
    expect(classifyVm(vm("t"), facts({ id: "t", member_ids: [ALICE, BOB] })).owner).toBe("shared")
  })
  test("ambiguous cases need a decision, never a guess", () => {
    expect(classifyVm(vm("t"), facts({ id: "t", team_subscription_ids: ["sub_x"] })).owner).toBe("needs-decision")
    expect(classifyVm(vm("t"), facts({ id: "t", member_ids: [BOB] })).owner).toBe("needs-decision")
    expect(classifyVm(vm("t"), facts({ id: "t", member_ids: [] })).owner).toBe("needs-decision")
    expect(classifyVm(vm("t"), facts({ id: "t", team: null })).owner).toBe("needs-decision")
  })
  test("a needs-decision VM is reported, not copied", async () => {
    const f = fixture()
    f.tables.stripe_subscriptions!.push({
      id: "sub_alice_team",
      customer_id: "cus_x",
      stack_user_id: ALICE,
      stack_team_id: ALICE_TEAM,
      status: "active",
      plan: "team",
      scope: "team",
      seats: 1,
    })
    const plan = await planFor({ kind: "user", id: ALICE }, f)
    expect(byKind(plan, "cloud_vm")[0]).toEqual(expect.objectContaining({ classic_id: VM_LIVE, action: "needs-decision" }))
    expect(copiesOf(plan)).toEqual([])
    expect(plan.counts["needs-decision"]).toBe(1)
  })
  test("a team that is someone's personal team sends its VM to that user's migration", async () => {
    const plan = await planFor({ kind: "team", id: ALICE_TEAM })
    expect(byKind(plan, "cloud_vm")[0]?.reason).toContain(`--user ${ALICE}`)
    expect(copiesOf(plan)).toEqual([])
  })
})

describe("classic stays read only", () => {
  /** A fake connection: records statements, answers SHOW with `readOnly`, and SELECTs with no rows. */
  const fakeConn = (readOnly = "on") => {
    const statements: string[] = []
    let released = 0
    const conn: PgConnection = {
      unsafe: async (text) => {
        statements.push(text.trim().split(/\s+/).join(" "))
        if (text.startsWith("SHOW transaction_read_only")) return [{ transaction_read_only: readOnly }]
        if (/count\(\*\)/.test(text)) return [{ n: 0 }]
        return []
      },
      release: () => {
        released++
      },
    }
    return { conn, statements, released: () => released }
  }

  test("every query runs inside BEGIN READ ONLY with a statement timeout, then ROLLBACK", async () => {
    for (const subject of [
      { kind: "user", id: ALICE },
      { kind: "team", id: ACME },
    ] as const) {
      const f = fakeConn()
      const rows = await withReadOnlyTransaction(f.conn, (q) => readSubject(q, subject))
      expect(rows.subject).toEqual(subject)
      expect(f.statements.slice(0, 4)).toEqual([
        "BEGIN READ ONLY",
        "SET TRANSACTION READ ONLY",
        "SET LOCAL statement_timeout = 15000",
        "SHOW transaction_read_only",
      ])
      expect(f.statements.at(-1)).toBe("ROLLBACK")
      const queries = f.statements.slice(4, -1)
      expect(queries.length).toBeGreaterThan(8)
      for (const q of queries) expect(q).toMatch(/^select /i)
      expect(f.released()).toBe(1)
    }
  })

  test("a connection that is not read only is refused, rolled back and released", async () => {
    const f = fakeConn("off")
    await expect(withReadOnlyTransaction(f.conn, (q) => readSubject(q, { kind: "user", id: ALICE }))).rejects.toThrow(
      ReadOnlyViolation,
    )
    expect(f.statements.filter((s) => /^select/i.test(s))).toEqual([])
    expect(f.statements.at(-1)).toBe("ROLLBACK")
    expect(f.released()).toBe(1)
  })

  test("a write statement never reaches the connection", async () => {
    const f = fakeConn()
    await expect(
      withReadOnlyTransaction(f.conn, async (q) => q("update cloud_vms set status = 'destroyed'")),
    ).rejects.toThrow(ReadOnlyViolation)
    expect(f.statements.some((s) => s.startsWith("update"))).toBe(false)
    expect(f.statements.at(-1)).toBe("ROLLBACK")
    for (const bad of [
      "delete from runs",
      "select 1; delete from runs",
      "insert into x select 1",
      "with x as (delete from runs returning *) select * from x",
      "COMMIT",
      "set transaction read write",
    ])
      expect(() => assertSelectOnly(bad)).toThrow(ReadOnlyViolation)
    expect(() => assertSelectOnly("select created_at, updated_at from cloud_vms where id = $1")).not.toThrow()
  })

  test("the classic host must be on CLASSIC_DB_HOST_ALLOW unless --allow-production-read", () => {
    const url = "postgres://ro:x@classic-prod.example.com:5432/cmux"
    expect(() => checkClassicHost(url, undefined, false)).toThrow(/CLASSIC_DB_HOST_ALLOW is required/)
    expect(() => checkClassicHost(url, " , ", false)).toThrow(/CLASSIC_DB_HOST_ALLOW is required/)
    expect(() => checkClassicHost(url, "classic-staging.example.com", false)).toThrow(/not on CLASSIC_DB_HOST_ALLOW/)
    expect(() => checkClassicHost(url, "classic-staging.example.com", false)).toThrow(ClassicHostRefused)
    expect(checkClassicHost(url, "classic-staging.example.com, classic-prod.example.com", false)).toEqual({
      host: "classic-prod.example.com",
      via: "allowlist",
    })
    expect(checkClassicHost(url, undefined, true)).toEqual({ host: "classic-prod.example.com", via: "allow-production-read" })
  })

  test("the CLI refuses both before it connects", async () => {
    const base = ["plan", "--user", ALICE, "--source", "postgres", "--stack-project", PROJECT, "--out", tmp]
    // Port 9 (discard): a connection attempt would hang or fail differently; the refusal comes first.
    const env = { CLASSIC_DATABASE_URL: "postgres://ro@127.0.0.1:9/cmux" }
    const missing = await run(base, env)
    expect(missing.code).toBe(1)
    expect(missing.stderr).toContain("CLASSIC_DB_HOST_ALLOW is required")
    const other = await run(base, { ...env, CLASSIC_DB_HOST_ALLOW: "classic-staging.example.com" })
    expect(other.code).toBe(1)
    expect(other.stderr).toContain("127.0.0.1 is not on CLASSIC_DB_HOST_ALLOW")
  })
})

// --------------------------------------------------------------------------------------------------------------
// apply / rollback against a fake VM API and platform.

interface Seen {
  method: string
  path: string
  body: Record<string, unknown> | null
}

const fakeNext = () => {
  const seen: Seen[] = []
  const snaps = new Map<string, string>() // migration/classic vm -> snap id
  const live = new Set<string>() // snap ids
  const machines = new Set<string>() // migration/classic vm
  let hold: ((s: Seen) => boolean) | null = null
  let onHold: () => void = () => {}
  const server = Bun.serve({
    port: 0,
    fetch: async (req) => {
      const url = new URL(req.url)
      const text = await req.text()
      const s: Seen = { method: req.method, path: url.pathname, body: text ? (JSON.parse(text) as Record<string, unknown>) : null }
      seen.push(s)
      const auth = req.headers.get("authorization")
      if (hold?.(s)) {
        onHold()
        return new Promise<Response>(() => {})
      }
      const key = `${s.body?.["migration_id"]}/${s.body?.["classic_vm_id"]}`
      if (url.pathname === "/v1/imports/classic-vm-snapshots" && req.method === "POST") {
        if (auth !== "Bearer vm-key") return new Response("no", { status: 401 })
        let id = snaps.get(key)
        if (!id) snaps.set(key, (id = `snap_${String(snaps.size + 1).padStart(26, "0")}`))
        live.add(id)
        return Response.json({ id })
      }
      if (url.pathname.startsWith("/v1/imports/classic-vm-snapshots/") && req.method === "DELETE") {
        const id = decodeURIComponent(url.pathname.split("/").at(-1)!)
        if (!live.delete(id)) return new Response("gone", { status: 404 })
        return new Response(null, { status: 204 })
      }
      if (url.pathname === "/internal/v1/migrations/classic/machines") {
        if (auth !== "Bearer internal") return new Response("no", { status: 401 })
        if (req.method === "POST") {
          machines.add(key)
          return Response.json({ machine: { id: `mach_${key.length}` }, snapshot: { id: "csnap_1" } })
        }
        if (req.method === "DELETE") {
          if (!machines.delete(key)) return new Response("gone", { status: 404 })
          return new Response(null, { status: 204 })
        }
      }
      return new Response("not found", { status: 404 })
    },
  })
  return {
    origin: `http://127.0.0.1:${server.port}`,
    seen,
    live,
    machines,
    holdWhen: (f: ((s: Seen) => boolean) | null) => {
      hold = f
      return new Promise<void>((resolve) => {
        onHold = resolve
      })
    },
    stop: () => server.stop(true),
  }
}

const run = async (args: string[], env: Record<string, string> = {}) => {
  const p = Bun.spawn(["bun", MAIN, ...args], {
    env: { PATH: process.env["PATH"] ?? "", HOME: process.env["HOME"] ?? "", ...env },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  })
  const [stdout, stderr, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited])
  return { code, stdout, stderr }
}

const count = (seen: Seen[], method: string, path: string) =>
  seen.filter((s) => s.method === method && s.path.startsWith(path)).length

describe("apply, kill, re-run, rollback", () => {
  const VM_PATH = "/v1/imports/classic-vm-snapshots"
  const PLATFORM_PATH = "/internal/v1/migrations/classic/machines"

  test("a run killed mid-step re-sends only the in-flight request, then rollback undoes it once", async () => {
    const next = fakeNext()
    try {
      const dir = join(tmp, "kill")
      const planOut = await run(["plan", "--user", ALICE, "--source", "fixture", FIXTURE_PATH, "--out", dir])
      expect(planOut.code).toBe(0)
      const tenants = join(dir, "tenants.json")
      writeFileSync(tenants, JSON.stringify({ [ALICE]: ALICE_TENANT }))
      const ledgerPath = join(dir, "ledger.jsonl")
      const env = {
        CMUX_VM_API_ORIGIN: next.origin,
        CMUX_VM_IMPORT_KEY: "vm-key",
        CMUX_PLATFORM_ORIGIN: next.origin,
        INTERNAL_TOKEN: "internal",
      }
      const applyArgs = ["apply", "--plan", join(dir, "plan.json"), "--ledger", ledgerPath, "--personal-tenants", tenants]

      // Run 1: the platform import never answers; kill the process while it waits.
      const held = next.holdWhen((s) => s.method === "POST" && s.path === PLATFORM_PATH)
      const child = Bun.spawn(["bun", MAIN, ...applyArgs], {
        env: { PATH: process.env["PATH"] ?? "", ...env },
        stdin: "ignore",
        stdout: "ignore",
        stderr: "ignore",
      })
      await held
      child.kill("SIGKILL")
      await child.exited
      expect(count(next.seen, "POST", VM_PATH)).toBe(1)
      expect(count(next.seen, "POST", PLATFORM_PATH)).toBe(1)
      expect(status(new Ledger(ledgerPath)).map((r) => [r.vm_api_import, r.platform_import])).toEqual([
        ["done", "in_flight"],
      ])

      // Run 2: the done step is skipped; the in-flight one is re-sent with the same body.
      next.holdWhen(null)
      const second = await run(applyArgs, env)
      expect(second.code).toBe(0)
      expect(second.stdout).toContain(`done ${VM_LIVE}`)
      expect(count(next.seen, "POST", VM_PATH)).toBe(1)
      const platformPosts = next.seen.filter((s) => s.method === "POST" && s.path === PLATFORM_PATH)
      expect(platformPosts.length).toBe(2)
      expect(platformPosts[1]?.body).toEqual(platformPosts[0]?.body ?? null)
      const plan = JSON.parse(readFileSync(join(dir, "plan.json"), "utf8")) as Plan
      expect(next.seen.find((s) => s.method === "POST" && s.path === VM_PATH)?.body).toEqual({
        tenant_id: ALICE_TENANT,
        created_by: userIdFor(PROJECT, ALICE),
        classic_vm_id: VM_LIVE,
        upstream_vm_id: "fs-alice-dev",
        migration_id: plan.migration_id,
      })
      expect(platformPosts[0]?.body).toEqual({
        team: personalTeamIdFor(userIdFor(PROJECT, ALICE)),
        creator_user: userIdFor(PROJECT, ALICE),
        migration_id: plan.migration_id,
        classic_vm_id: VM_LIVE,
        vm_api_snapshot_id: "snap_00000000000000000000000001",
        name: "alice-dev",
        size: null,
      })

      // Run 3: everything is done; nothing is sent.
      const before = next.seen.length
      expect((await run(applyArgs, env)).code).toBe(0)
      expect(next.seen.length).toBe(before)
      const st = await run(["status", "--ledger", ledgerPath, "--plan", join(dir, "plan.json")])
      expect(st.stdout).toContain(`done                 ${VM_LIVE}`)

      // Rollback: machine first, then the VM API snapshot; a second rollback sends nothing.
      const rb = await run(["rollback", "--ledger", ledgerPath], env)
      expect(rb.code).toBe(0)
      const undo = next.seen.slice(before).map((s) => `${s.method} ${s.path}`)
      expect(undo).toEqual([`DELETE ${PLATFORM_PATH}`, `DELETE ${VM_PATH}/snap_00000000000000000000000001`])
      expect(next.seen.at(-2)?.body).toEqual({
        team: personalTeamIdFor(userIdFor(PROJECT, ALICE)),
        migration_id: plan.migration_id,
        classic_vm_id: VM_LIVE,
      })
      expect(next.machines.size).toBe(0)
      expect(next.live.size).toBe(0)
      const afterFirst = next.seen.length
      const rb2 = await run(["rollback", "--ledger", ledgerPath], env)
      expect(rb2.code).toBe(0)
      expect(rb2.stdout).toContain("nothing to roll back")
      expect(next.seen.length).toBe(afterFirst)
      expect(status(new Ledger(ledgerPath))[0]?.overall).toBe("rolled_back")

      // Apply after rollback leaves the rolled-back VM alone.
      const again = await run(applyArgs, env)
      expect(again.stdout).toContain("rolled back in this ledger")
      expect(next.seen.length).toBe(afterFirst)
    } finally {
      next.stop()
    }
  }, 30_000)

  test("--dry-run sends nothing and writes no ledger", async () => {
    const next = fakeNext()
    try {
      const plan = await planFor({ kind: "team", id: ACME })
      const ledgerPath = join(tmp, "dry.jsonl")
      const vmApi = httpVmApi(next.origin, "vm-key")
      const platform = httpPlatform(next.origin, "internal")
      const report = await apply(
        plan,
        new Ledger(ledgerPath),
        { vmApi, platform, resolvePersonalTenant: mapTenantResolver({}) },
        { dryRun: true },
      )
      expect(report.would.map((w) => w.action)).toEqual(["send", "send"])
      expect(next.seen).toEqual([])
      expect(existsSync(ledgerPath)).toBe(false)
    } finally {
      next.stop()
    }
  })

  test("--only limits apply to one classic VM; an unknown one is refused", async () => {
    const next = fakeNext()
    try {
      const plan = await planFor({ kind: "team", id: ACME })
      const deps = {
        vmApi: httpVmApi(next.origin, "vm-key"),
        platform: httpPlatform(next.origin, "internal"),
        resolvePersonalTenant: mapTenantResolver({}),
      }
      const ledger = new Ledger(join(tmp, "only.jsonl"))
      await expect(apply(plan, ledger, deps, { only: VM_LIVE })).rejects.toThrow(/no copy/)
      const report = await apply(plan, ledger, deps, { only: VM_ACME })
      expect(report.done).toEqual([VM_ACME])
      expect(next.seen.find((s) => s.path === VM_PATH)?.body?.["tenant_id"]).toBe(ACME)
    } finally {
      next.stop()
    }
  })

  test("an unresolved personal tenant fails before any request", async () => {
    const next = fakeNext()
    try {
      const plan = await planFor({ kind: "user", id: ALICE })
      const report = await apply(plan, new Ledger(join(tmp, "notenant.jsonl")), {
        vmApi: httpVmApi(next.origin, "vm-key"),
        platform: httpPlatform(next.origin, "internal"),
        resolvePersonalTenant: mapTenantResolver({}),
      })
      expect(report.failed[0]?.error).toContain("no personal VM API tenant")
      expect(next.seen).toEqual([])
    } finally {
      next.stop()
    }
  })

  test("rollback of an import that never answered learns its id with the same request, then deletes it", async () => {
    const next = fakeNext()
    try {
      const plan = await planFor({ kind: "team", id: ACME })
      const ledger = new Ledger(join(tmp, "inflight.jsonl"))
      const req = {
        tenant_id: ACME,
        created_by: userIdFor(PROJECT, BOB),
        classic_vm_id: VM_ACME,
        upstream_vm_id: "fs-acme-ci",
        migration_id: plan.migration_id,
      }
      // The import reached the VM API, but the run died before recording its answer.
      await httpVmApi(next.origin, "vm-key").importSnapshot(req)
      ledger.append({ migration_id: plan.migration_id, classic_vm_id: VM_ACME, step: "vm_api_import", event: "started", request: req })
      const report = await rollback(ledger, {
        vmApi: httpVmApi(next.origin, "vm-key"),
        platform: httpPlatform(next.origin, "internal"),
      })
      expect(report.failed).toEqual([])
      expect(next.seen.slice(1).map((s) => `${s.method} ${s.path}`)).toEqual([
        `POST ${VM_PATH}`,
        `DELETE ${VM_PATH}/snap_00000000000000000000000001`,
      ])
      expect(next.live.size).toBe(0)
    } finally {
      next.stop()
    }
  })

  test("a ledger of another migration is refused; a torn last line is dropped", async () => {
    const plan = await planFor({ kind: "team", id: ACME })
    const path = join(tmp, "other.jsonl")
    writeFileSync(path, `${JSON.stringify({ at: "x", migration_id: "mig_other", classic_vm_id: "v", step: "vm_api_import", event: "started" })}\n{"at":`)
    expect(new Ledger(path).read().length).toBe(1)
    await expect(
      apply(plan, new Ledger(path), {
        vmApi: httpVmApi("http://127.0.0.1:9", "k"),
        platform: httpPlatform("http://127.0.0.1:9", "k"),
        resolvePersonalTenant: mapTenantResolver({}),
      }),
    ).rejects.toThrow(/belongs to migration mig_other/)
  })
})
