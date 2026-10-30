/**
 * prod-promote.ts against a fake Cloudflare API (globalThis.fetch stubbed; any other host throws) and a
 * temp git repository whose commits stand in for production's source commits. Nothing here reaches
 * Cloudflare or GitHub, and `rollback` only ever runs as a dry run (no --execute).
 */
import { afterAll, afterEach, beforeAll, describe, expect, it } from "bun:test"
import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { candidateRuns, guardedVarGate, holdPinned, holdReleases, isPromotableLineage, main, missingSecrets, pickCandidate, rollbackPlan, serving, SOAK_MINUTES, type Approvals, type GitRunner } from "../prod-promote.ts"

const SHA = "0123456789abcdef0123456789abcdef01234567"
const OTHER = "89abcdef0123456789abcdef0123456789abcdef"

describe("G6 hold values", () => {
  it("'released' releases every commit", () => {
    expect(holdReleases("released", SHA)).toBe(true)
    expect(holdReleases("released", undefined)).toBe(true)
    expect(holdPinned("released")).toBeUndefined()
  })
  it("'released:<40 hex>' releases only that commit", () => {
    expect(holdReleases(`released:${SHA}`, SHA)).toBe(true)
    expect(holdPinned(`released:${SHA}`)).toBe(SHA)
  })
  it("a one-shot release for another commit, or no commit, holds", () => {
    expect(holdReleases(`released:${SHA}`, OTHER)).toBe(false)
    expect(holdReleases(`released:${SHA}`, undefined)).toBe(false)
  })
  it("uppercase hex holds (values are exactly lowercase)", () => {
    const upper = SHA.toUpperCase()
    expect(holdReleases(`released:${upper}`, upper)).toBe(false)
    expect(holdReleases(`released:${upper}`, SHA)).toBe(false)
    expect(holdPinned(`released:${upper}`)).toBeUndefined()
    expect(holdReleases("RELEASED", SHA)).toBe(false)
  })
  it("anything else holds", () => {
    for (const v of [undefined, "", "hold", "released ", " released", `released:${SHA}\n`, `released:${SHA.slice(0, 12)}`, `released:${SHA}0`]) {
      expect(holdReleases(v, SHA)).toBe(false)
      expect(holdPinned(v)).toBeUndefined()
    }
  })
})

describe("G1 with --candidate (exact SHA)", () => {
  const now = Date.parse("2026-10-19T12:00:00Z")
  const min = 60_000
  const run = (sha: string, agoMin: number, green = true) => ({ sha, at: now - agoMin * min, green })
  const A = "a".repeat(40)
  const B = "b".repeat(40)
  const C = "c".repeat(40)

  it("without a filter the newest soaked green wins", () => {
    const runs = [run(B, SOAK_MINUTES + 10), run(A, SOAK_MINUTES + 100)]
    expect(pickCandidate(candidateRuns(runs, undefined), now)?.sha).toBe(B)
  })
  it("the wanted commit wins over a newer soaked green", () => {
    const runs = [run(B, SOAK_MINUTES + 10), run(A, SOAK_MINUTES + 100)]
    expect(pickCandidate(candidateRuns(runs, A), now)?.sha).toBe(A)
  })
  it("an unsoaked wanted commit holds; it never falls back to another commit", () => {
    const runs = [run(B, SOAK_MINUTES + 10), run(A, SOAK_MINUTES - 1)]
    expect(pickCandidate(candidateRuns(runs, A), now)).toBeUndefined()
  })
  it("a wanted commit with no green run holds", () => {
    const runs = [run(B, SOAK_MINUTES + 10), run(A, SOAK_MINUTES + 100, false)]
    expect(pickCandidate(candidateRuns(runs, A), now)).toBeUndefined()
    expect(pickCandidate(candidateRuns(runs, C), now)).toBeUndefined()
  })
  it("another commit's red run inside the wanted commit's soak window still holds it", () => {
    const runs = [run(C, SOAK_MINUTES + 50, false), run(A, SOAK_MINUTES + 100)]
    expect(pickCandidate(candidateRuns(runs, A), now)).toBeUndefined()
  })
  it("a red run after the soak window does not", () => {
    const runs = [run(C, 10, false), run(A, SOAK_MINUTES + 100)]
    expect(pickCandidate(candidateRuns(runs, A), now)?.sha).toBe(A)
  })
  it("an older green run of the wanted commit counts when the newer one is not soaked", () => {
    const runs = [run(A, 5), run(B, SOAK_MINUTES + 10), run(A, SOAK_MINUTES + 100)]
    const got = pickCandidate(candidateRuns(runs, A), now)
    expect(got?.sha).toBe(A)
    expect(got?.at).toBe(now - (SOAK_MINUTES + 100) * min)
  })
})

// ---- fake Cloudflare ----

type Dep = { version: string; trigger?: string; at: string }
type Ver = { tag?: string; message?: string }
let deps: Array<Dep> = []
let versions: Record<string, Ver> = {}
const realFetch = globalThis.fetch
const env = { token: process.env.CLOUDFLARE_API_TOKEN, cwd: process.cwd() }

const fakeFetch = async (input: string | URL | Request): Promise<Response> => {
  const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url)
  if (url.host !== "api.cloudflare.com") throw new Error(`test: unexpected fetch ${url.href}`)
  const json = (result: unknown) => new Response(JSON.stringify({ result }), { status: 200 })
  const d = /\/workers\/scripts\/cmux-api\/deployments$/.exec(url.pathname)
  if (d) {
    // Unsorted on purpose: the code sorts by created_on.
    return json({ deployments: [...deps].reverse().map((x) => ({ created_on: x.at, versions: [{ version_id: x.version, percentage: 100 }], annotations: x.trigger ? { "workers/triggered_by": x.trigger } : {} })) })
  }
  const v = /\/workers\/scripts\/cmux-api\/versions\/([^/]+)$/.exec(url.pathname)
  if (v) {
    const ver = versions[v[1]!]
    if (!ver) return new Response("not found", { status: 404 })
    return json({ id: v[1], annotations: { ...(ver.tag ? { "workers/tag": ver.tag } : {}), ...(ver.message ? { "workers/message": ver.message } : {}) } })
  }
  throw new Error(`test: unexpected Cloudflare path ${url.pathname}`)
}

/** Deployments newest first; created_on counts down by the hour. */
const setDeployments = (list: Array<Omit<Dep, "at">>) => {
  const t0 = Date.parse("2026-10-19T12:00:00Z")
  deps = list.map((x, i) => ({ ...x, at: new Date(t0 - i * 3600_000).toISOString() }))
}

// ---- temp repo: A (one DO migration), B (same migrations as A), C (adds a migration) ----

const wranglerWith = (tags: Array<string>) =>
  `// production config\n${JSON.stringify({ name: "cmux-api", env: { production: { vars: { CHIEF_BRAIN_ENABLED: "1" }, migrations: tags.map((tag) => ({ tag, new_sqlite_classes: [`Class_${tag}`] })) } } }, null, 2)}\n`
const repo: Record<"A" | "B" | "C", string> = { A: "", B: "", C: "" }
let tmpRoot = ""

beforeAll(() => {
  const root = (tmpRoot = mkdtempSync(join(tmpdir(), "rails-prod-promote-")))
  // Hermetic even inside a git hook: no inherited GIT_DIR or index, no hooks, no signing.
  const gitEnv = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("GIT_")))
  const git = (...args: Array<string>) =>
    execFileSync("git", ["-c", "user.name=test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", ...args], { cwd: root, env: gitEnv, encoding: "utf8" }).trim()
  git("init", "-q")
  mkdirSync(join(root, "backend/apps/api"), { recursive: true })
  const commit = (tags: Array<string>, note: string) => {
    writeFileSync(join(root, "backend/apps/api/wrangler.jsonc"), wranglerWith(tags))
    writeFileSync(join(root, "note.txt"), note)
    git("add", "-A")
    git("commit", "-q", "-m", note)
    return git("rev-parse", "HEAD")
  }
  repo.A = commit(["v1"], "A")
  repo.B = commit(["v1"], "B")
  repo.C = commit(["v1", "v2"], "C")
  process.chdir(root)
  process.env.CLOUDFLARE_API_TOKEN = "test-token-not-real"
  globalThis.fetch = fakeFetch as typeof fetch
})

afterAll(() => {
  globalThis.fetch = realFetch
  process.chdir(env.cwd)
  rmSync(tmpRoot, { recursive: true, force: true })
  if (env.token === undefined) delete process.env.CLOUDFLARE_API_TOKEN
  else process.env.CLOUDFLARE_API_TOKEN = env.token
})

afterEach(() => {
  deps = []
  versions = {}
})

const tag = (sha: string) => sha.slice(0, 12)
const code = (sha: string, run = 1): Ver => ({ tag: tag(sha), message: `source ${sha} run ${run}` })
const off = (sha: string, run = 1): Ver => ({ tag: tag(sha), message: `source ${sha} chief-off run ${run}` })

/** main(["rollback"]) as a dry run: exit code and printed lines. */
const dryRun = async (...extra: Array<string>) => {
  const lines: Array<string> = []
  const [log, error] = [console.log, console.error]
  console.log = (...a: Array<unknown>) => void lines.push(a.join(" "))
  console.error = (...a: Array<unknown>) => void lines.push(a.join(" "))
  try {
    return { code: await main(["rollback", ...extra]), out: lines.join("\n") }
  } finally {
    ;[console.log, console.error] = [log, error]
  }
}

describe("serving().heldBack", () => {
  it("a normal code deployment is not held back", async () => {
    versions = { v2: code(repo.B), v1: code(repo.A) }
    setDeployments([{ version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    const s = await serving("cmux-api")
    expect(s).toMatchObject({ version: "v2", sourceTag: tag(repo.B) })
    expect(s.heldBack).toBeUndefined()
  })
  it("a rollback deployment holds automatic promotes", async () => {
    versions = { v2: code(repo.B), v1: code(repo.A) }
    setDeployments([{ version: "v1", trigger: "rollback" }, { version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    const s = await serving("cmux-api")
    expect(s).toMatchObject({ version: "v1", sourceTag: tag(repo.A), heldBack: "production serves a rollback" })
  })
  it("the Chief off switch holds automatic promotes, also under a later secret-only deployment", async () => {
    versions = { v3: off(repo.A), v2: off(repo.A), v1: code(repo.A) }
    setDeployments([{ version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    expect((await serving("cmux-api")).heldBack).toBe("production serves the Chief off switch")
    // `wrangler secret put` makes an untagged version of the same code.
    versions.v3 = {}
    setDeployments([{ version: "v3", trigger: "secret" }, { version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    const s = await serving("cmux-api")
    expect(s).toMatchObject({ version: "v3", sourceTag: tag(repo.A), heldBack: "production serves the Chief off switch" })
  })
  it("the off switch is the ' chief-off' word, at the end too, not a lookalike", async () => {
    versions = { v1: { tag: tag(repo.A), message: `source ${repo.A} chief-off` } }
    setDeployments([{ version: "v1", trigger: "deployment" }])
    expect((await serving("cmux-api")).heldBack).toBe("production serves the Chief off switch")
    versions = { v1: { tag: tag(repo.A), message: `source ${repo.A} chief-offline run 1` } }
    expect((await serving("cmux-api")).heldBack).toBeUndefined()
  })
})

describe("rollbackPlan", () => {
  it("targets the version before the current code deployment, with both source commits", async () => {
    versions = { v2: code(repo.B), v1: code(repo.A) }
    setDeployments([{ version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    expect(await rollbackPlan("cmux-api")).toEqual({ fromVersion: "v2", fromSha: repo.B, toVersion: "v1", toSha: repo.A })
  })
  it("a secret-only deployment on top of the current code is not new code", async () => {
    versions = { v3: {}, v2: code(repo.B), v1: code(repo.A) }
    setDeployments([{ version: "v3", trigger: "secret" }, { version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    expect(await rollbackPlan("cmux-api")).toEqual({ fromVersion: "v3", fromSha: repo.B, toVersion: "v1", toSha: repo.A })
  })
  it("a secret-only deployment between the two code versions is the target, with the older code", async () => {
    versions = { v3: code(repo.B), v2: {}, v1: code(repo.A) }
    setDeployments([{ version: "v3", trigger: "deployment" }, { version: "v2", trigger: "secret" }, { version: "v1", trigger: "deployment" }])
    expect(await rollbackPlan("cmux-api")).toEqual({ fromVersion: "v3", fromSha: repo.B, toVersion: "v2", toSha: repo.A })
  })
  it("refuses when production already serves a rollback, unless --force", async () => {
    versions = { v3: code(repo.C), v2: code(repo.B), v1: code(repo.A) }
    setDeployments([{ version: "v2", trigger: "rollback" }, { version: "v3", trigger: "deployment" }, { version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    const plan = await rollbackPlan("cmux-api")
    expect(plan).toEqual({ refused: "cmux-api already serves a rollback; roll forward with an exact-SHA promote, or pass --force to roll back onto the deployment that rollback replaced" })
    // A secret-only deployment on top of the rollback does not hide it.
    versions.v4 = {}
    setDeployments([{ version: "v4", trigger: "secret" }, { version: "v2", trigger: "rollback" }, { version: "v3", trigger: "deployment" }, { version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    expect("refused" in (await rollbackPlan("cmux-api"))).toBe(true)
    expect((await dryRun()).code).toBe(3)
    // --force steps once more, onto the deployment the rollback replaced.
    expect(await rollbackPlan("cmux-api", true)).toEqual({ fromVersion: "v4", fromSha: repo.B, toVersion: "v3", toSha: repo.C })
  })
  it("refuses with no deployment before the current code", async () => {
    versions = { v1: code(repo.A) }
    setDeployments([{ version: "v1", trigger: "deployment" }])
    expect(await rollbackPlan("cmux-api")).toEqual({ refused: "cmux-api: no deployment before the current code" })
  })
  it("from the Chief off switch, the target is the same code with the brain on", async () => {
    versions = { v2: off(repo.B), v1: code(repo.B) }
    setDeployments([{ version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    const plan = await rollbackPlan("cmux-api")
    expect(plan).toEqual({ fromVersion: "v2", fromSha: repo.B, toVersion: "v1", toSha: repo.B })
    const r = await dryRun()
    expect(r.code).toBe(0)
    expect(r.out).toContain("dry run")
    expect(r.out).toContain("rollback v1 --name cmux-api -y")
  })
  it("from the off switch run twice, the target is the version before the first off switch (the brain comes back on)", async () => {
    versions = { v3: off(repo.B, 2), v2: off(repo.B, 1), v1: code(repo.B) }
    setDeployments([{ version: "v3", trigger: "deployment" }, { version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    expect(await rollbackPlan("cmux-api")).toEqual({ fromVersion: "v3", fromSha: repo.B, toVersion: "v1", toSha: repo.B })
    // With secret-only deployments in between too.
    versions = { ...versions, s2: {}, s1: {} }
    setDeployments([{ version: "s2", trigger: "secret" }, { version: "v3", trigger: "deployment" }, { version: "s1", trigger: "secret" }, { version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    expect(await rollbackPlan("cmux-api")).toEqual({ fromVersion: "s2", fromSha: repo.B, toVersion: "v1", toSha: repo.B })
  })
  it("from the off switch with only off-switch deployments before it, refuses", async () => {
    versions = { v2: off(repo.B, 2), v1: off(repo.B, 1) }
    setDeployments([{ version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    expect(await rollbackPlan("cmux-api")).toEqual({ refused: "cmux-api: no deployment before the current code" })
  })
  it("from the off switch, never steps past a rollback onto code that was rolled back", async () => {
    // A, off(A), promote B, B goes bad: rollback onto off(A); then target=chief-off again (serving A).
    versions = { v4: off(repo.A, 2), v3: code(repo.B), v2: off(repo.A, 1), v1: code(repo.A) }
    setDeployments([{ version: "v4", trigger: "deployment" }, { version: "v2", trigger: "rollback" }, { version: "v3", trigger: "deployment" }, { version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    const plan = await rollbackPlan("cmux-api")
    expect("refused" in plan ? plan.refused : plan).toContain("not the code the off switch serves")
    expect((await dryRun()).code).toBe(3)
  })
  it("a code deployment after the off switch rolls back onto the off switch (the brain stays off)", async () => {
    versions = { v3: code(repo.C), v2: off(repo.B), v1: code(repo.B) }
    setDeployments([{ version: "v3", trigger: "deployment" }, { version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    expect(await rollbackPlan("cmux-api")).toEqual({ fromVersion: "v3", fromSha: repo.C, toVersion: "v2", toSha: repo.B })
  })
})

describe("rollback (dry run) and Durable Object migrations", () => {
  it("refuses across a DO lifecycle change and names the added tag", async () => {
    versions = { v2: code(repo.C), v1: code(repo.B) }
    setDeployments([{ version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    const r = await dryRun()
    expect(r.code).toBe(3)
    expect(r.out).toContain("crosses a Durable Object lifecycle change (v2)")
    expect(r.out).toContain("target=chief-off")
    expect(r.out).not.toContain("dry run")
  })
  it("same migrations: prints the wrangler command and changes nothing", async () => {
    versions = { v2: code(repo.B), v1: code(repo.A) }
    setDeployments([{ version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    const r = await dryRun()
    expect(r.code).toBe(0)
    expect(r.out).toContain(`v2 (${tag(repo.B)}) -> v1 (${tag(repo.A)})`)
    expect(r.out).toContain(`--message rollback ${tag(repo.B)} -> ${tag(repo.A)} (prod-promote)`)
  })
  it("an untagged side refuses (roll back by hand)", async () => {
    versions = { v2: code(repo.B), v1: {} }
    setDeployments([{ version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    const r = await dryRun()
    expect(r.code).toBe(3)
    expect(r.out).toContain("roll back by hand: wrangler rollback v1 --name cmux-api")
  })
})

describe("paid Cloud entitlements (CLOUD_PLAN_ENTITLEMENTS) in production", () => {
  const approvals = (guarded: Record<string, string> = {}): Approvals => ({ required_secrets: ["JWT_PRIVATE_JWK"], do_tags: {}, guarded_vars: guarded })
  const env = (vars: Record<string, string>) => ({ vars: { ENVIRONMENT: "production", ...vars }, migrations: [] })

  it("G7: turning it on needs an approved value; leaving it unchanged does not", () => {
    const off = env({})
    const on = env({ CLOUD_PLAN_ENTITLEMENTS: "on" })
    expect(guardedVarGate(off, on, approvals())).toEqual(["CLOUD_PLAN_ENTITLEMENTS=on: not in scripts/cmux-next/release/production-approvals.json guarded_vars"])
    expect(guardedVarGate(off, on, approvals({ "CLOUD_PLAN_ENTITLEMENTS=on": "reviewed" }))).toEqual([])
    expect(guardedVarGate(on, on, approvals())).toEqual([])
    expect(guardedVarGate(on, off, approvals())).toEqual(["CLOUD_PLAN_ENTITLEMENTS=<unset>: not in scripts/cmux-next/release/production-approvals.json guarded_vars"])
  })

  it("G5: on needs the provider key of its transport; off needs none", () => {
    const have = new Set(["JWT_PRIVATE_JWK"])
    expect(missingSecrets(env({}), approvals(), have)).toEqual([])
    expect(missingSecrets(env({ CLOUD_PLAN_ENTITLEMENTS: "on" }), approvals(), have)).toEqual(["CLOUD_FREESTYLE_API_KEY"])
    expect(missingSecrets(env({ CLOUD_PLAN_ENTITLEMENTS: "on", CLOUD_VM_TRANSPORT: "vm-api" }), approvals(), have)).toEqual(["CLOUD_VM_API_SERVICE_KEY"])
    expect(missingSecrets(env({ CLOUD_PLAN_ENTITLEMENTS: "on" }), approvals(), new Set([...have, "CLOUD_FREESTYLE_API_KEY"]))).toEqual([])
    expect(missingSecrets(env({ CLOUD_PLAN_ENTITLEMENTS: "on", CLOUD_VM_TRANSPORT: "direct" }), approvals(), have)).toEqual(["CLOUD_FREESTYLE_API_KEY"])
    // cloudConfig gives any other transport no provider, so no secret satisfies it.
    expect(missingSecrets(env({ CLOUD_PLAN_ENTITLEMENTS: "on", CLOUD_VM_TRANSPORT: "vmapi" }), approvals(), new Set([...have, "CLOUD_FREESTYLE_API_KEY", "CLOUD_VM_API_SERVICE_KEY"]))).toEqual(["CLOUD_VM_TRANSPORT=vmapi (no Cloud provider)"])
  })
})

const lineageRepo = () => {
  const root = mkdtempSync(join(tmpdir(), "prod-promote-lineage-"))
  const run: GitRunner = (args, input) => execFileSync("git", ["-C", root, ...args], { encoding: "utf8", ...(input === undefined ? {} : { input }) }).trim()
  run(["init", "--quiet"])
  run(["config", "user.email", "test@example.com"])
  run(["config", "user.name", "Release test"])
  mkdirSync(join(root, "backend"), { recursive: true })
  const commit = (contents: string, message: string) => {
    writeFileSync(join(root, "backend", "runtime.ts"), contents)
    run(["add", "backend/runtime.ts"])
    run(["commit", "--quiet", "-m", message])
    return run(["rev-parse", "HEAD"])
  }
  return { root, run, commit }
}

describe("production promotion lineage", () => {
  it("accepts a staging history that contains a cherry-pick-equivalent production change", () => {
    const t = lineageRepo()
    const base = t.commit("export const value = 1\n", "base")
    t.run(["checkout", "--quiet", "-b", "candidate", base])
    t.commit("export const value = 2\n", "candidate implementation")
    const candidate = t.commit("export const value = 3\n", "candidate follow-up")
    t.run(["checkout", "--quiet", "-b", "production", base])
    const production = t.commit("export const value = 2\n", "production cherry-pick")

    expect(isPromotableLineage(production, candidate, t.run)).toBe(true)
    expect(isPromotableLineage(base, candidate, t.run)).toBe(true)
  })

  it("rejects a production history with an unmatched backend change", () => {
    const t = lineageRepo()
    const base = t.commit("export const value = 1\n", "base")
    t.run(["checkout", "--quiet", "-b", "candidate", base])
    const candidate = t.commit("export const value = 2\n", "candidate implementation")
    t.run(["checkout", "--quiet", "-b", "production", base])
    t.commit("export const value = 2\n", "production cherry-pick")
    const production = t.commit("export const value = 99\n", "unmatched production change")

    expect(isPromotableLineage(production, candidate, t.run)).toBe(false)
  })
})
