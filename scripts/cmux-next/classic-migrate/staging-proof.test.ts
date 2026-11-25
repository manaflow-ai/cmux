import { describe, expect, test } from "bun:test"
import { buildPlan } from "./plan.ts"
import { fixtureSource, readFixture } from "./source.ts"
import {
  checkDryRun,
  runProof,
  SCOPE_HEADER,
  summaryMarkdown,
  teardownOnly,
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
    personalTeam: { id: "pt1", created: false },
    vms: [
      { id: "vm-a", kind: "personal", nonce: "n1", scope: "pt1" },
      { id: "vm-b", kind: "team", nonce: "n2", scope: "t1" },
    ],
    ledgers: [],
  })
  const fakeHttp = (
    answer: (method: string, url: string, headers: Record<string, string>, body: unknown) => number | { status: number; body: any },
  ) => {
    const calls: string[] = []
    const scopes: string[] = []
    const http: Http = async (method, url, body, headers = {}) => {
      calls.push(`${method} ${url}`)
      if (url.endsWith("/auth/sessions")) return { status: 200, body: { access_token: "a", refresh_token: "r" } }
      if (url.startsWith("https://classic")) scopes.push(`${method} ${url} ${headers[SCOPE_HEADER] ?? "(none)"}`)
      const a = answer(method, url, headers, body)
      return typeof a === "number" ? { status: a, body: {} } : a
    }
    return { http, calls, scopes }
  }

  test("deletes VMs, then the team, then the users; a 404 counts as gone; a second run sends nothing", async () => {
    const s = state()
    const f = fakeHttp((_, url) => (url.endsWith("vm-b") ? 404 : 200))
    const saves: number[] = []
    const out = await teardownState(s, { http: f.http, ep, keys, save: () => saves.push(1) })
    expect(out).toContain("deleted 2 classic VM(s), 1 team(s), 2 user(s)")
    expect(f.scopes).toEqual(["DELETE https://classic/api/vm/vm-a pt1", "DELETE https://classic/api/vm/vm-b t1"])
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

  // F2: classic resolves a request's account scope from X-Cmux-Team-Id; without it, once the paid shared team
  // exists, a personal-VM request can resolve to the shared team, and classic then hides the personal VM (404).
  test("F2: each VM is deleted under its own scope; a 404 without a recorded scope is not taken as gone", async () => {
    const s = state()
    // Classic as it scopes: vm-a is visible only under pt1, vm-b only under t1.
    const owns: Record<string, string> = { "vm-a": "pt1", "vm-b": "t1" }
    const f = fakeHttp((method, url, headers) => {
      const vm = url.split("/api/vm/")[1]
      if (method === "DELETE" && vm) return owns[vm] === headers[SCOPE_HEADER] ? 200 : 404
      return 200
    })
    await teardownState(s, { http: f.http, ep, keys, save: () => {} })
    expect(s.vms.every((v) => v.gone)).toBe(true)
    expect(f.scopes).toEqual(["DELETE https://classic/api/vm/vm-a pt1", "DELETE https://classic/api/vm/vm-b t1"])

    // A state with no recorded scope (written before the fix): the scope-filtered 404 does not count as gone.
    const old = state()
    delete old.vms[0]!.scope
    const g = fakeHttp((method, url, headers) => {
      const vm = url.split("/api/vm/")[1]
      if (method === "DELETE" && vm) return owns[vm] === headers[SCOPE_HEADER] ? 200 : 404
      return 200
    })
    await expect(teardownState(old, { http: g.http, ep, keys, save: () => {} })).rejects.toThrow(
      /classic VM vm-a \(HTTP 404 with no recorded scope/,
    )
    expect(old.vms[0]!.gone).toBeUndefined()
    expect(old.users.find((u) => u.role === "owner")!.gone).toBeUndefined()
  })

  // F3: deleting the team would drop the membership classic's ownership check needs to retry the VM's delete.
  test("F3: the team is kept while its VM is not confirmed gone, and deleted on the retry that removes the VM", async () => {
    const s = state()
    let vmB = 502
    const f = fakeHttp((method, url) => (url.endsWith("/api/vm/vm-b") ? vmB : 200))
    await expect(teardownState(s, { http: f.http, ep, keys, save: () => {} })).rejects.toThrow(/team t1 kept/)
    expect(f.calls).not.toContain("DELETE https://stack/api/v1/teams/t1")
    expect(s.team!.gone).toBeUndefined()
    vmB = 200
    const retry = fakeHttp((method, url) => (url.endsWith("/api/vm/vm-b") ? vmB : 200))
    await teardownState(s, { http: retry.http, ep, keys, save: () => {} })
    expect(retry.calls.filter((c) => !c.endsWith("/auth/sessions"))).toEqual([
      "DELETE https://classic/api/vm/vm-b",
      "DELETE https://stack/api/v1/teams/t1",
      "DELETE https://stack/api/v1/users/u1",
    ])
  })

  test("a personal team the proof made is deleted after its VM; one Stack made is left alone", async () => {
    const s = state()
    s.personalTeam = { id: "pt1", created: true }
    const f = fakeHttp(() => 200)
    await teardownState(s, { http: f.http, ep, keys, save: () => {} })
    expect(f.calls).toContain("DELETE https://stack/api/v1/teams/pt1")
    const t = state()
    const g = fakeHttp(() => 200)
    await teardownState(t, { http: g.http, ep, keys, save: () => {} })
    expect(g.calls).not.toContain("DELETE https://stack/api/v1/teams/pt1")
  })

  // F4: classic answered 503 vm_operation_in_progress while the create went on, so no VM id was recorded.
  test("F4: an unanswered create is found by its recorded intent and deleted before its owner", async () => {
    const s = state()
    s.vms = [{ id: "vm-a", kind: "personal", nonce: "n1", scope: "pt1" }]
    s.creates = [
      { kind: "personal", key: "k-personal", scope: "pt1", body: { provider: "freestyle", displayName: "classicmig-t-personal" }, resolved: "vm-a" },
      { kind: "team", key: "k-team", scope: "t1", body: { provider: "freestyle", displayName: "classicmig-t-team" } },
    ]
    const f = fakeHttp((method, url, headers) => {
      // The create finished after its 503: the list under t1 shows it by its display name.
      if (method === "GET" && url === "https://classic/api/vm")
        return { status: 200, body: { vms: headers[SCOPE_HEADER] === "t1" ? [{ id: "vm-late", displayName: "classicmig-t-team" }] : [] } }
      return 200
    })
    await teardownState(s, { http: f.http, ep, keys, save: () => {} })
    expect(s.creates[1]!.resolved).toBe("vm-late")
    expect(f.scopes).toEqual([
      "GET https://classic/api/vm t1",
      "DELETE https://classic/api/vm/vm-a pt1",
      "DELETE https://classic/api/vm/vm-late t1",
    ])
    const calls = f.calls.filter((c) => !c.endsWith("/auth/sessions"))
    expect(calls.indexOf("DELETE https://classic/api/vm/vm-late")).toBeLessThan(calls.indexOf("DELETE https://stack/api/v1/teams/t1"))
    expect(calls.indexOf("DELETE https://stack/api/v1/teams/t1")).toBeLessThan(calls.indexOf("DELETE https://stack/api/v1/users/u1"))
  })

  test("F4: not in the list, the create is replayed with its Idempotency-Key; still running keeps the owner and team", async () => {
    const s = state()
    s.vms = []
    s.creates = [{ kind: "team", key: "k-team", scope: "t1", body: { provider: "freestyle", displayName: "classicmig-t-team" } }]
    const keys_: string[] = []
    let createAnswer: { status: number; body: any } = { status: 503, body: { error: "vm_operation_in_progress" } }
    const answer = (method: string, url: string, headers: Record<string, string>) => {
      if (method === "GET" && url === "https://classic/api/vm") return { status: 200, body: { vms: [] } }
      if (method === "POST" && url === "https://classic/api/vm") {
        keys_.push(`${headers["idempotency-key"]} ${headers[SCOPE_HEADER]}`)
        return createAnswer
      }
      return 200
    }
    const f = fakeHttp(answer)
    await expect(
      teardownState(s, { http: f.http, ep, keys, save: () => {}, createWaitMs: 0, sleep: async () => {} }),
    ).rejects.toThrow(/classic create team \(Idempotency-Key k-team\) unresolved.*team t1 kept.*user o@x kept/)
    expect(f.calls).not.toContain("DELETE https://stack/api/v1/teams/t1")
    expect(f.calls).not.toContain("DELETE https://stack/api/v1/users/u1")
    // The retry: the replay now answers with the VM the first request made.
    createAnswer = { status: 200, body: { id: "vm-late" } }
    const g = fakeHttp(answer)
    await teardownState(s, { http: g.http, ep, keys, save: () => {}, createWaitMs: 0, sleep: async () => {} })
    expect(keys_).toEqual(["k-team t1", "k-team t1"])
    expect(g.calls).toContain("DELETE https://classic/api/vm/vm-late")
    expect(s.users.every((u) => u.gone)).toBe(true)
  })

  test("F4: a create classic recorded as failed resolves to none", async () => {
    const s = state()
    s.vms = []
    s.creates = [{ kind: "team", key: "k", scope: "t1", body: { provider: "freestyle", displayName: "d" } }]
    const f = fakeHttp((method, url) => {
      if (method === "GET" && url === "https://classic/api/vm") return { status: 200, body: { vms: [] } }
      if (method === "POST" && url === "https://classic/api/vm") return { status: 500, body: { error: "vm_create_failed" } }
      return 200
    })
    await teardownState(s, { http: f.http, ep, keys, save: () => {}, createWaitMs: 0 })
    expect(s.creates[0]!.resolved).toMatch(/^none:/)
    expect(s.users.every((u) => u.gone)).toBe(true)
  })
})

// F5: in --teardown-only, a failed rescue rollback must not skip the classic teardown.
describe("teardownOnly", () => {
  test("F5: a rescue-rollback failure still runs the teardown; both failures are reported together", async () => {
    const f = fakeOps({ rescueRollback: "platform 503", teardown: "left behind: classic VM vm-a" })
    const r = await teardownOnly(f.ops, true)
    expect(f.calls).toEqual(["rescueRollback", "teardown"])
    expect(r.ok).toBe(false)
    expect(r.failures).toEqual(["rescue rollback: platform 503", "teardown: left behind: classic VM vm-a"])
  })

  test("F5: a rescue-rollback failure alone fails the run after a clean teardown", async () => {
    const f = fakeOps({ rescueRollback: "platform 503" })
    const r = await teardownOnly(f.ops, true)
    expect(f.calls).toEqual(["rescueRollback", "teardown"])
    expect(r).toEqual({ ok: false, notes: ["teardown ok"], failures: ["rescue rollback: platform 503"] })
    const g = fakeOps()
    expect(await teardownOnly(g.ops, false)).toEqual({ ok: true, notes: ["teardown ok"], failures: [] })
    expect(g.calls).toEqual(["teardown"])
  })
})
