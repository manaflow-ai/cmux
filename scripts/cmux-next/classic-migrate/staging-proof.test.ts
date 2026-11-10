import { describe, expect, test } from "bun:test"
import { buildPlan } from "./plan.ts"
import { fixtureSource, readFixture } from "./source.ts"
import {
  checkDryRun,
  runProof,
  summaryMarkdown,
  teardownState,
  type Http,
  type ProofOps,
  type ProofState,
} from "./staging-proof.ts"
import { join } from "node:path"

// The staging proof's pure parts, with fakes: step order, teardown on every path, the dry-run check, and the
// idempotent teardown of a state file. No network.

const fakeOps = (fail: Partial<Record<keyof ProofOps, string>> = {}) => {
  const calls: string[] = []
  const op = (name: keyof ProofOps) => async () => {
    calls.push(name)
    if (fail[name]) throw new Error(fail[name])
    return `${name} ok`
  }
  const ops: ProofOps = {
    setup: op("setup"),
    dryRun: op("dryRun"),
    migrate: op("migrate"),
    rollback: op("rollback"),
    rescueRollback: op("rescueRollback"),
    teardown: op("teardown"),
  }
  return { ops, calls }
}

const results = (steps: { step: string; result: string }[]) => steps.map((s) => `${s.step}:${s.result}`)

describe("runProof", () => {
  test("all steps in order; no rescue rollback when ROLLBACK passed", async () => {
    const f = fakeOps()
    const r = await runProof(f.ops, { migrateSkip: null })
    expect(r.ok).toBe(true)
    expect(f.calls).toEqual(["setup", "dryRun", "migrate", "rollback", "teardown"])
    expect(results(r.steps)).toEqual(["setup:pass", "dry_run:pass", "migrate:pass", "rollback:pass", "teardown:pass"])
  })

  test("without the internal token MIGRATE and ROLLBACK are not-run and the proof passes", async () => {
    const f = fakeOps()
    const r = await runProof(f.ops, { migrateSkip: "no token" })
    expect(r.ok).toBe(true)
    expect(f.calls).toEqual(["setup", "dryRun", "teardown"])
    expect(results(r.steps)).toEqual(["setup:pass", "dry_run:pass", "migrate:not-run", "rollback:not-run", "teardown:pass"])
    expect(r.steps[2]?.detail).toBe("no token")
  })

  test("a failed SETUP stops the rest but still tears down, without a rescue rollback", async () => {
    const f = fakeOps({ setup: "stack said no" })
    const r = await runProof(f.ops, { migrateSkip: null })
    expect(r.ok).toBe(false)
    expect(f.calls).toEqual(["setup", "teardown"])
    expect(results(r.steps)).toEqual(["setup:fail", "dry_run:not-run", "migrate:not-run", "rollback:not-run", "teardown:pass"])
  })

  test("a failed MIGRATE rolls NEXT back before the teardown", async () => {
    const f = fakeOps({ migrate: "exec never answered" })
    const r = await runProof(f.ops, { migrateSkip: null })
    expect(r.ok).toBe(false)
    expect(f.calls).toEqual(["setup", "dryRun", "migrate", "rescueRollback", "teardown"])
    expect(results(r.steps).at(-2)).toBe("rollback:not-run")
    expect(r.steps.at(-1)?.detail).toContain("rescue rollback: rescueRollback ok")
  })

  test("a failed ROLLBACK is rolled back again; a failed rescue still tears down and fails the teardown", async () => {
    const f = fakeOps({ rollback: "verify found a machine", rescueRollback: "platform 503" })
    const r = await runProof(f.ops, { migrateSkip: null })
    expect(f.calls).toEqual(["setup", "dryRun", "migrate", "rollback", "rescueRollback", "teardown"])
    expect(results(r.steps).slice(-2)).toEqual(["rollback:fail", "teardown:fail"])
    expect(r.steps.at(-1)?.detail).toContain("rescue rollback FAILED: platform 503")
  })

  test("a failed DRY RUN never migrates", async () => {
    const f = fakeOps({ dryRun: "needs-decision" })
    const r = await runProof(f.ops, { migrateSkip: null })
    expect(f.calls).toEqual(["setup", "dryRun", "teardown"])
    expect(r.ok).toBe(false)
  })

  test("seconds come from the clock; the summary is a table", async () => {
    let t = 0
    const r = await runProof(fakeOps().ops, { migrateSkip: null, now: () => (t += 1500) })
    expect(r.steps.map((s) => s.seconds)).toEqual([1.5, 1.5, 1.5, 1.5, 1.5])
    const md = summaryMarkdown(r.ok, r.steps, { classic: "https://x" })
    expect(md).toContain("staging proof: PASS")
    expect(md).toContain("| migrate | 1.5 | pass | migrate ok |")
  })
})

describe("checkDryRun", () => {
  const FIXTURE = join(import.meta.dirname, "fixtures/staging-test.json")
  const plan = async (kind: "user" | "team", id: string) =>
    buildPlan(await fixtureSource(readFixture(FIXTURE), "fixture").read({ kind, id }), "p", "fixture")

  test("passes when the VM is copy and nothing needs a decision; names what is wrong otherwise", async () => {
    const team = await plan("team", "bbbbbbbb-0000-4000-8000-000000000ac3")
    expect(checkDryRun(team, ["fs-acme-ci"])).toEqual([])
    expect(checkDryRun(team, ["fs-missing"])).toEqual(["classic VM fs-missing is not in the team plan"])
    const user = await plan("user", "11111111-1111-4111-8111-111111111111")
    expect(checkDryRun(user, ["fs-alice-old"])[0]).toContain("is not-migrated")
    expect(checkDryRun({ ...user, counts: { ...user.counts, "needs-decision": 2 } }, ["fs-alice-dev"])).toEqual([
      "2 object(s) need a decision",
    ])
  })
})

describe("teardownState", () => {
  const ep = { stackApi: "https://stack", classic: "https://classic" }
  const keys = { project: "p", clientKey: "", serverKey: "s" }
  const state = (): ProofState => ({
    tag: "t",
    users: [
      { id: "u1", email: "o@x", role: "owner" },
      { id: "u2", email: "m@x", role: "member" },
    ],
    team: { id: "t1" },
    vms: [
      { id: "vm-a", kind: "personal", nonce: "n1" },
      { id: "vm-b", kind: "team", nonce: "n2" },
    ],
    ledgers: [],
  })
  const fakeHttp = (answer: (method: string, url: string) => number) => {
    const calls: string[] = []
    const http: Http = async (method, url) => {
      calls.push(`${method} ${url}`)
      if (url.endsWith("/auth/sessions")) return { status: 200, body: { access_token: "a", refresh_token: "r" } }
      return { status: answer(method, url), body: {} }
    }
    return { http, calls }
  }

  test("deletes VMs, then the team, then the users; a 404 counts as gone; a second run sends nothing", async () => {
    const s = state()
    const f = fakeHttp((_, url) => (url.endsWith("vm-b") ? 404 : 200))
    const saves: number[] = []
    const out = await teardownState(s, { http: f.http, ep, keys, save: () => saves.push(1) })
    expect(out).toContain("deleted 2 classic VM(s), 1 team, 2 user(s)")
    expect(f.calls.filter((c) => !c.endsWith("/auth/sessions"))).toEqual([
      "DELETE https://classic/api/vm/vm-a",
      "DELETE https://classic/api/vm/vm-b",
      "DELETE https://stack/api/v1/teams/t1",
      "DELETE https://stack/api/v1/users/u1",
      "DELETE https://stack/api/v1/users/u2",
    ])
    expect(saves.length).toBe(5)
    const again = fakeHttp(() => 500)
    await teardownState(s, { http: again.http, ep, keys, save: () => {} })
    expect(again.calls).toEqual([])
  })

  test("a VM that will not delete keeps its owner for the sweep and fails", async () => {
    const s = state()
    const f = fakeHttp((_, url) => (url.endsWith("vm-a") ? 502 : 200))
    await expect(teardownState(s, { http: f.http, ep, keys, save: () => {} })).rejects.toThrow(
      /classic VM vm-a \(HTTP 502\).*user o@x kept for the classic sweep/,
    )
    expect(s.users.map((u) => u.gone ?? false)).toEqual([false, true])
    expect(f.calls).not.toContain("DELETE https://stack/api/v1/users/u1")
  })
})
