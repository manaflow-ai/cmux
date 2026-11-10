import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { apply, attemptFor, rollback, status, verify } from "./apply.ts"
import { httpPlatform } from "./clients.ts"
import { migrationIdFor, personalTeamIdFor, sharedTeamIdFor, userIdFor } from "./ids.ts"
import { Ledger } from "./ledger.ts"
import { buildPlan, classifyVm, copiesOf, renderPlanMarkdown, vmSize, type Plan } from "./plan.ts"
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
        creator_user_id: aliceNext,
        name: "alice-dev",
        size: { cpu: 4, memory_mb: 8192, disk_mb: 32768 },
      },
    ])
    expect(vms[0]?.next?.["size"]).toBe('{"cpu":4,"memory_mb":8192,"disk_mb":32768}')
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

  test("a team: its VM lands in the shared team, created by its creator", async () => {
    const plan = await planFor({ kind: "team", id: ACME })
    expect(plan.subject.next_team_id).toBe(sharedTeamIdFor(PROJECT, ACME))
    expect(copiesOf(plan)).toEqual([
      expect.objectContaining({
        classic_vm_id: VM_ACME,
        next_team_id: sharedTeamIdFor(PROJECT, ACME),
        creator_user_id: userIdFor(PROJECT, BOB),
        size: {},
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

  test("size: classic's resource reservation, each axis kept only inside the platform's bounds", () => {
    const vm = (meta: Record<string, unknown>) =>
      ({ provider_metadata: { cmuxResourceReservation: meta } }) as unknown as ClassicVm
    expect(vmSize(vm({ vcpus: 5, memoryMb: 20480, diskMb: 32768 }))).toEqual({ cpu: 5, memory_mb: 20480, disk_mb: 32768 })
    expect(vmSize(vm({ vcpus: 0, memoryMb: 1.5, diskMb: 9_999_999 }))).toEqual({})
    expect(vmSize(vm({ vcpus: "4", memoryMb: 4096 }))).toEqual({ memory_mb: 4096 })
    expect(vmSize({ provider_metadata: null } as unknown as ClassicVm)).toEqual({})
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
// apply / rollback / verify against a fake of cmux-platform's internal migration route (ClassicMigrationRoute.ts).

interface Seen {
  method: string
  path: string
  query: string
  body: Record<string, unknown> | null
}

const PLATFORM_PATH = "/internal/v1/migrations/classic/machines"

/** The route as cmux-platform#1148 specifies it: 201 created / 200 existing, GET list, DELETE deleted|absent. */
const fakePlatform = () => {
  const seen: Seen[] = []
  // `${team}|${migration}|${vm}` -> machine id, while live
  const machines = new Map<string, string>()
  const imports = new Set<string>()
  let seq = 0
  let hold: ((s: Seen) => boolean) | null = null
  let onHold: () => void = () => {}
  const server = Bun.serve({
    port: 0,
    fetch: async (req) => {
      const url = new URL(req.url)
      const text = await req.text()
      const s: Seen = {
        method: req.method,
        path: url.pathname,
        query: url.search,
        body: text ? (JSON.parse(text) as Record<string, unknown>) : null,
      }
      seen.push(s)
      if (url.pathname !== PLATFORM_PATH) return new Response("not found", { status: 404 })
      if (req.headers.get("authorization") !== "Bearer internal") return Response.json({ code: "auth.unauthorized" }, { status: 401 })
      if (hold?.(s)) {
        onHold()
        return new Promise<Response>(() => {})
      }
      if (req.method === "GET") {
        const team = url.searchParams.get("team")
        const mig = url.searchParams.get("migration_id")
        const items = [...machines]
          .filter(([k]) => k.startsWith(`${team}|${mig}|`))
          .map(([k, id]) => ({
            classic_vm_id: k.split("|")[2],
            status: "created",
            machine: { id, status: "running" },
            snapshot: { id: `snap_row_${id}` },
          }))
        return Response.json({ team, migration_id: mig, items })
      }
      const b = s.body ?? {}
      const key = `${b["team"]}|${b["migration_id"]}|${b["classic_vm_id"]}`
      if (req.method === "POST") {
        const had = machines.get(key)
        if (had) return Response.json({ status: "existing", machine: { id: had }, snapshot: { id: `snap_row_${had}` } })
        const id = `mach_${++seq}`
        machines.set(key, id)
        imports.add(key)
        return Response.json(
          { status: "created", machine: { id }, snapshot: { id: `snap_row_${id}`, vm_api_snapshot_id: `snap_${seq}` } },
          { status: 201 },
        )
      }
      if (req.method === "DELETE") {
        const had = machines.delete(key)
        const imp = imports.delete(key)
        return Response.json({ status: had || imp ? "deleted" : "absent", machine: null, snapshot: null, vm_api_imports_deleted: [] })
      }
      return new Response("no", { status: 405 })
    },
  })
  return {
    origin: `http://127.0.0.1:${server.port}`,
    seen,
    machines,
    imports,
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

const count = (seen: Seen[], method: string) => seen.filter((s) => s.method === method && s.path === PLATFORM_PATH).length

describe("apply, kill, re-run, verify, rollback, fresh", () => {
  test("a run killed mid-request re-sends only that request; verify, rollback twice, --fresh, rollback", async () => {
    const next = fakePlatform()
    try {
      const dir = join(tmp, "kill")
      expect((await run(["plan", "--user", ALICE, "--source", "fixture", FIXTURE_PATH, "--out", dir])).code).toBe(0)
      const ledgerPath = join(dir, "ledger.jsonl")
      const env = { CMUX_PLATFORM_ORIGIN: next.origin, INTERNAL_TOKEN: "internal" }
      const applyArgs = ["apply", "--plan", join(dir, "plan.json"), "--ledger", ledgerPath]
      const plan = JSON.parse(readFileSync(join(dir, "plan.json"), "utf8")) as Plan
      const aliceNext = userIdFor(PROJECT, ALICE)
      const team = personalTeamIdFor(aliceNext)

      // Run 1: the import is accepted but never answers; kill the process while it waits.
      const held = next.holdWhen((s) => s.method === "POST")
      const child = Bun.spawn(["bun", MAIN, ...applyArgs], {
        env: { PATH: process.env["PATH"] ?? "", ...env },
        stdin: "ignore",
        stdout: "ignore",
        stderr: "ignore",
      })
      await held
      child.kill("SIGKILL")
      await child.exited
      expect(count(next.seen, "POST")).toBe(1)
      expect(status(new Ledger(ledgerPath)).map((r) => r.platform_import)).toEqual(["in_flight"])

      // Run 2: the in-flight request is re-sent with the same body.
      next.holdWhen(null)
      const second = await run(applyArgs, env)
      expect(second.code).toBe(0)
      expect(second.stdout).toContain(`done ${VM_LIVE}`)
      const posts = next.seen.filter((s) => s.method === "POST")
      expect(posts.length).toBe(2)
      expect(posts[1]?.body).toEqual(posts[0]?.body ?? null)
      expect(posts[0]?.body).toEqual({
        team,
        creator_user: aliceNext,
        migration_id: plan.migration_id,
        classic_vm_id: VM_LIVE,
        upstream_vm_id: "fs-alice-dev",
        name: "alice-dev",
        size: { cpu: 4, memory_mb: 8192, disk_mb: 32768 },
      })

      // Run 3: everything is done; nothing is sent and the ledger does not grow.
      const before = next.seen.length
      const ledgerBytes = readFileSync(ledgerPath, "utf8").length
      const third = await run(applyArgs, env)
      expect(third.code).toBe(0)
      expect(third.stdout).toContain("0 request(s) sent")
      expect(next.seen.length).toBe(before)
      expect(readFileSync(ledgerPath, "utf8").length).toBe(ledgerBytes)
      expect((await run(["status", "--ledger", ledgerPath, "--plan", join(dir, "plan.json")])).stdout).toContain(
        `done                 ${VM_LIVE}  ${plan.migration_id} platform_import=done mach_1`,
      )

      // verify: the machine the ledger recorded is live in NEXT.
      const v1 = await run(["verify", "--ledger", ledgerPath, "--json"], env)
      expect(v1.code).toBe(0)
      expect(JSON.parse(v1.stdout)).toEqual({
        ok: true,
        team,
        rows: [{ attempt: plan.migration_id, classic_vm_id: VM_LIVE, expect: "present", found: "mach_1", ok: true, note: "machine live" }],
      })
      expect(next.seen.at(-1)?.query).toBe(`?team=${team}&migration_id=${encodeURIComponent(plan.migration_id)}`)

      // Rollback: one DELETE; a second rollback sends nothing; verify shows none.
      const rb = await run(["rollback", "--ledger", ledgerPath], env)
      expect(rb.code).toBe(0)
      expect(rb.stdout).toContain(`rolled back ${VM_LIVE} (deleted)`)
      expect(next.seen.filter((s) => s.method === "DELETE").map((s) => s.body)).toEqual([
        { team, migration_id: plan.migration_id, classic_vm_id: VM_LIVE },
      ])
      expect(next.machines.size + next.imports.size).toBe(0)
      const afterFirst = next.seen.length
      const rb2 = await run(["rollback", "--ledger", ledgerPath], env)
      expect(rb2.stdout).toContain("nothing to roll back")
      expect(next.seen.length).toBe(afterFirst)
      expect(status(new Ledger(ledgerPath))[0]?.overall).toBe("rolled_back")
      const v2 = await run(["verify", "--ledger", ledgerPath], env)
      expect(v2.code).toBe(0)
      expect(v2.stdout).toContain("expect absent: none")

      // Apply after rollback leaves the rolled-back VM alone; --fresh copies it again as attempt .r2.
      const again = await run(applyArgs, env)
      expect(again.stdout).toContain("pass --fresh")
      expect(count(next.seen, "POST")).toBe(2)
      const fresh = await run([...applyArgs, "--fresh"], env)
      expect(fresh.code).toBe(0)
      expect(fresh.stdout).toContain(`attempt ${plan.migration_id}.r2: 1 request(s) sent`)
      expect(next.seen.filter((s) => s.method === "POST").at(-1)?.body?.["migration_id"]).toBe(`${plan.migration_id}.r2`)
      // --fresh again is refused while .r2 is live; plain apply is a no-op on it.
      expect((await run([...applyArgs, "--fresh"], env)).stderr).toContain("run rollback first")
      expect((await run(applyArgs, env)).stdout).toContain("0 request(s) sent")
      // verify checks both attempts: .r2 present, the first absent.
      const v3 = JSON.parse((await run(["verify", "--ledger", ledgerPath, "--json"], env)).stdout)
      expect(v3.ok).toBe(true)
      expect(v3.rows.map((r: { attempt: string; expect: string }) => `${r.attempt} ${r.expect}`)).toEqual([
        `${plan.migration_id} absent`,
        `${plan.migration_id}.r2 present`,
      ])
      expect((await run(["rollback", "--ledger", ledgerPath], env)).code).toBe(0)
      expect(next.machines.size).toBe(0)
    } finally {
      next.stop()
    }
  }, 60_000)

  test("verify fails on a machine the ledger does not know and on a missing one", async () => {
    const next = fakePlatform()
    try {
      const plan = await planFor({ kind: "team", id: ACME })
      const ledger = new Ledger(join(tmp, "verify.jsonl"))
      const deps = { platform: httpPlatform(next.origin, "internal") }
      expect((await apply(plan, ledger, deps)).done).toEqual([VM_ACME])
      const team = sharedTeamIdFor(PROJECT, ACME)
      next.machines.set(`${team}|${plan.migration_id}|c-stray`, "mach_stray")
      const r = await verify(ledger, deps)
      expect(r.ok).toBe(false)
      expect(r.rows.find((x) => x.classic_vm_id === "c-stray")?.note).toContain("does not know")
      next.machines.clear()
      const r2 = await verify(ledger, deps)
      expect(r2.rows).toEqual([expect.objectContaining({ classic_vm_id: VM_ACME, ok: false, note: "no live machine in NEXT" })])
    } finally {
      next.stop()
    }
  })

  test("--dry-run sends nothing and writes no ledger", async () => {
    const next = fakePlatform()
    try {
      const plan = await planFor({ kind: "team", id: ACME })
      const ledgerPath = join(tmp, "dry.jsonl")
      const report = await apply(plan, new Ledger(ledgerPath), { platform: httpPlatform(next.origin, "internal") }, { dryRun: true })
      expect(report.would.map((w) => w.action)).toEqual(["send"])
      expect(next.seen).toEqual([])
      expect(existsSync(ledgerPath)).toBe(false)
    } finally {
      next.stop()
    }
  })

  test("--only limits apply to one classic VM; an unknown one is refused", async () => {
    const next = fakePlatform()
    try {
      const plan = await planFor({ kind: "team", id: ACME })
      const deps = { platform: httpPlatform(next.origin, "internal") }
      const ledger = new Ledger(join(tmp, "only.jsonl"))
      await expect(apply(plan, ledger, deps, { only: VM_LIVE })).rejects.toThrow(/no copy/)
      const report = await apply(plan, ledger, deps, { only: VM_ACME })
      expect(report.done).toEqual([VM_ACME])
      expect(next.seen[0]?.body?.["upstream_vm_id"]).toBe("fs-acme-ci")
      expect(next.seen[0]?.body).not.toHaveProperty("vm_api_tenant")
    } finally {
      next.stop()
    }
  })

  test("an id the platform would refuse is never sent", async () => {
    const next = fakePlatform()
    try {
      const f = fixture()
      f.tables.cloud_vms![2]!.id = "x".repeat(64)
      const plan = await planFor({ kind: "team", id: ACME }, f)
      const report = await apply(plan, new Ledger(join(tmp, "badid.jsonl")), { platform: httpPlatform(next.origin, "internal") })
      expect(report.failed[0]?.error).toContain("not 1-63")
      expect(next.seen).toEqual([])
    } finally {
      next.stop()
    }
  })

  test("a ledger of another migration is refused; a torn last line is dropped", async () => {
    const plan = await planFor({ kind: "team", id: ACME })
    const path = join(tmp, "other.jsonl")
    writeFileSync(path, `${JSON.stringify({ at: "x", migration_id: "mig_other", classic_vm_id: "v", step: "platform_import", event: "started" })}\n{"at":`)
    expect(new Ledger(path).read().length).toBe(1)
    await expect(apply(plan, new Ledger(path), { platform: httpPlatform("http://127.0.0.1:9", "k") })).rejects.toThrow(
      /belongs to migration mig_other/,
    )
  })
})

// F1: ledgers the earlier two-step CLI wrote (a `vm_api_import` step before `platform_import`, the platform result
// as `{machine: {id}}`) must stay readable and recoverable: status shows them, rollback deletes the VM API snapshot
// that CLI made through the VM API client (or lists it for manual cleanup), verify reads them, an unknown step is
// ignored. fixtures/base-cli-ledger.jsonl is that CLI's format.
describe("a ledger written by the earlier CLI (vm_api_import)", () => {
  const BASE_LEDGER = join(DIR, "fixtures/base-cli-ledger.jsonl")
  const copy = (name: string) => {
    const p = join(tmp, name)
    writeFileSync(p, readFileSync(BASE_LEDGER, "utf8"))
    return p
  }
  const LEGACY_KEY = "team_legacy|mig_legacy|vm-1"

  test("status shows both steps, the snapshot and the machine, and ignores an unknown step, without a crash", async () => {
    const rows = status(new Ledger(copy("legacy-status.jsonl")))
    expect(rows).toEqual([
      {
        classic_vm_id: "vm-1",
        attempt: "mig_legacy",
        platform_import: "done",
        vm_api_import: "done",
        snapshot: "snap_1",
        machine: "mach_1",
        ignored_steps: ["mystery_step"],
        overall: "done",
      },
      { classic_vm_id: "vm-2", attempt: "mig_legacy", platform_import: "in_flight", vm_api_import: "done", snapshot: "snap_2", overall: "in_flight" },
      { classic_vm_id: "vm-3", attempt: "mig_legacy", platform_import: "pending", vm_api_import: "in_flight", overall: "in_flight" },
      { classic_vm_id: "vm-4", attempt: "mig_legacy", platform_import: "pending", vm_api_import: "failed", overall: "failed" },
    ])
    const cli = await run(["status", "--ledger", copy("legacy-status-cli.jsonl")])
    expect(cli.code).toBe(0)
    expect(cli.stdout).toContain("vm_api_import=done snap_1 platform_import=done mach_1 (ignored unknown steps: mystery_step)")
  })

  test("verify, then rollback deletes the machines and the VM API snapshots; the unanswered import is manual cleanup", async () => {
    const next = fakePlatform()
    const deleted: string[] = []
    try {
      next.machines.set(LEGACY_KEY, "mach_1")
      const ledger = new Ledger(copy("legacy-rollback.jsonl"))
      const deps = {
        platform: httpPlatform(next.origin, "internal"),
        legacyVmApi: { deleteSnapshot: async (id: string) => void deleted.push(id) },
      }
      const v = await verify(ledger, deps)
      expect(v.ok).toBe(true)
      expect(v.rows).toEqual([expect.objectContaining({ classic_vm_id: "vm-1", expect: "present", found: "mach_1" })])

      const r = await rollback(ledger, deps)
      expect(r.failed).toEqual([])
      expect(deleted).toEqual(["snap_2", "snap_1"])
      expect(next.machines.size).toBe(0)
      expect(r.manual_cleanup).toEqual([expect.objectContaining({ classic_vm_id: "vm-3", migration_id: "mig_legacy", vm_api_snapshot_id: null })])
      expect(Object.fromEntries(status(ledger).map((x) => [x.classic_vm_id, x.overall]))).toEqual({
        "vm-1": "rolled_back",
        "vm-2": "rolled_back",
        "vm-3": "rollback_incomplete",
        "vm-4": "rolled_back",
      })
      expect((await verify(ledger, deps)).ok).toBe(true)
      // A second rollback sends nothing and still names what needs a person.
      const again = await rollback(ledger, deps)
      expect(again.sent).toBe(0)
      expect(again.manual_cleanup.map((m) => m.classic_vm_id)).toEqual(["vm-3"])
      expect(deleted).toEqual(["snap_2", "snap_1"])
    } finally {
      next.stop()
    }
  })

  test("without a VM API client the snapshots are reported for manual cleanup with their ids; the CLI exits 1", async () => {
    const next = fakePlatform()
    try {
      next.machines.set(LEGACY_KEY, "mach_1")
      const r = await rollback(new Ledger(copy("legacy-nokey.jsonl")), { platform: httpPlatform(next.origin, "internal") })
      expect(r.failed).toEqual([])
      expect(r.manual_cleanup.map((m) => [m.classic_vm_id, m.vm_api_snapshot_id])).toEqual([
        ["vm-3", null],
        ["vm-2", "snap_2"],
        ["vm-1", "snap_1"],
      ])
      next.machines.set(LEGACY_KEY, "mach_1")
      const cli = await run(["rollback", "--ledger", copy("legacy-nokey-cli.jsonl")], {
        CMUX_PLATFORM_ORIGIN: next.origin,
        INTERNAL_TOKEN: "internal",
      })
      expect(cli.code).toBe(1)
      expect(cli.stdout).toContain("MANUAL CLEANUP vm-1 (mig_legacy) VM API snapshot snap_1")
      expect(cli.stderr).not.toContain("Cannot set properties")
      const v = await run(["verify", "--ledger", copy("legacy-verify-cli.jsonl")], { CMUX_PLATFORM_ORIGIN: next.origin, INTERNAL_TOKEN: "internal" })
      expect(v.stderr).not.toContain("Cannot set properties")
      expect(v.stdout).toContain("vm-1")
    } finally {
      next.stop()
    }
  })

  test("--fresh is refused while an earlier-CLI VM is not rolled back", async () => {
    const plan = { migration_id: "mig_legacy", entries: [], counts: {} } as unknown as Plan
    expect(() => attemptFor(plan, new Ledger(copy("legacy-fresh.jsonl")), true)).toThrow(/not rolled back/)
  })
})
