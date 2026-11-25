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
import { candidateRuns, gh, ghGraphql, GH_RATE_LIMIT_WAIT_MS, guardedVarGate, holdOff, holdPinned, holdReleases, isPromotableLineage, main, missingSecrets, pickCandidate, rollbackPlan, serving, stagingRuns, SOAK_MINUTES, type Approvals, type GitRunner } from "../prod-promote.ts"

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
  it("the switch is off by default: unset or empty releases every commit", () => {
    for (const v of [undefined, ""]) {
      expect(holdOff(v)).toBe(true)
      expect(holdReleases(v, SHA)).toBe(true)
      expect(holdReleases(v, undefined)).toBe(true)
      expect(holdPinned(v)).toBeUndefined()
    }
  })
  it("anything else a person sets holds", () => {
    for (const v of ["hold", "on: held for the launch", "released ", " released", `released:${SHA}\n`, `released:${SHA.slice(0, 12)}`, `released:${SHA}0`]) {
      expect(holdOff(v)).toBe(false)
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
    expect(s).toMatchObject({ version: "v1", sourceTag: tag(repo.A), heldBack: "production serves a rollback", rolledBackTag: tag(repo.B) })
  })
  it("a rollback names the code it removed, past a secret-only deployment on either side", async () => {
    versions = { v4: {}, v3: {}, v2: code(repo.B), v1: code(repo.A) }
    setDeployments([{ version: "v4", trigger: "secret" }, { version: "v1", trigger: "rollback" }, { version: "v3", trigger: "secret" }, { version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    expect(await serving("cmux-api")).toMatchObject({ sourceTag: tag(repo.A), heldBack: "production serves a rollback", rolledBackTag: tag(repo.B) })
  })
  it("a normal deployment and the off switch name no rolled-back code", async () => {
    versions = { v2: off(repo.A), v1: code(repo.A) }
    setDeployments([{ version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    expect((await serving("cmux-api")).rolledBackTag).toBeUndefined()
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

describe("the platform cutover (PLATFORM_SURFACES) in production", () => {
  const approvals = (guarded: Record<string, string> = {}): Approvals => ({ required_secrets: [], do_tags: {}, guarded_vars: guarded })
  const env = (vars: Record<string, string>) => ({ vars: { ENVIRONMENT: "production", ...vars }, migrations: [] })

  it("G7: forwarding a surface to cmux-platform needs an approved value; leaving it unchanged does not", () => {
    const off = env({})
    const on = env({ PLATFORM_SURFACES: "cloud" })
    expect(guardedVarGate(off, on, approvals())).toEqual(["PLATFORM_SURFACES=cloud: not in scripts/cmux-next/release/production-approvals.json guarded_vars"])
    expect(guardedVarGate(off, on, approvals({ "PLATFORM_SURFACES=cloud": "reviewed" }))).toEqual([])
    expect(guardedVarGate(on, on, approvals())).toEqual([])
    expect(guardedVarGate(on, env({ PLATFORM_SURFACES: "cloud,chat" }), approvals({ "PLATFORM_SURFACES=cloud": "reviewed" }))).toEqual([
      "PLATFORM_SURFACES=cloud,chat: not in scripts/cmux-next/release/production-approvals.json guarded_vars",
    ])
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

describe("gh() retries GitHub 5xx", () => {
  // Captured in beforeAll (after the file-level fake fetch is installed), so afterEach puts that fake back.
  const saved: { fetch: typeof fetch; token: string | undefined } = { fetch: globalThis.fetch, token: undefined }
  const stub = (statuses: Array<number | "throw">) => {
    const calls: Array<string> = []
    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      calls.push(`${init?.method ?? "GET"} ${String(input)}`)
      const s = statuses.shift()
      if (s === undefined || s === "throw") throw new Error("test: network down")
      return new Response(s === 204 ? null : JSON.stringify(s < 400 ? { ok: true } : { message: "Server Error" }), { status: s })
    }) as typeof fetch
    return calls
  }
  beforeAll(() => {
    saved.fetch = globalThis.fetch
    saved.token = process.env.GITHUB_TOKEN
    process.env.GITHUB_TOKEN = "test-token"
  })
  afterEach(() => { globalThis.fetch = saved.fetch })
  afterAll(() => { if (saved.token === undefined) delete process.env.GITHUB_TOKEN; else process.env.GITHUB_TOKEN = saved.token })

  it("a 502 then a 200 returns the 200", async () => {
    const calls = stub([502, 200])
    expect(await gh("/actions/runs/1/jobs", {}, [0, 0, 0])).toEqual({ ok: true })
    expect(calls.length).toBe(2)
  })
  it("a network error then a 200 returns the 200", async () => {
    const calls = stub(["throw", 200])
    expect(await gh("/actions/runs/1/jobs", {}, [0, 0, 0])).toEqual({ ok: true })
    expect(calls.length).toBe(2)
  })
  it("5xx on every try throws the original error text after the last retry", async () => {
    const calls = stub([502, 503, 500, 502])
    await expect(gh("/actions/runs/1/jobs", {}, [0, 0, 0])).rejects.toThrow("GitHub /actions/runs/1/jobs: HTTP 502")
    expect(calls.length).toBe(4)
  })
  it("a 404 throws at once", async () => {
    const calls = stub([404, 200])
    await expect(gh("/issues/9", {}, [0, 0, 0])).rejects.toThrow("HTTP 404")
    expect(calls.length).toBe(1)
  })
  it("a POST is never retried (a 5xx may already have created it)", async () => {
    const calls = stub([502, 200])
    await expect(gh("/issues", { method: "POST", body: "{}" }, [0, 0, 0])).rejects.toThrow("HTTP 502")
    expect(calls.length).toBe(1)
  })
})


describe("ghGraphql() retries a failed read", () => {
  // 2026-11-24 14:27Z (run 45406811977): the REST hour was spent 25 minutes before its reset, so G1 fell back to
  // GraphQL, whose one 502 (then a 200 with an error and no data) failed promote-gates; production waited for the
  // next backend push.
  const saved: { fetch: typeof fetch; token: string | undefined } = { fetch: globalThis.fetch, token: undefined }
  const stub = (answers: Array<number | "errors" | "throw">) => {
    let calls = 0
    globalThis.fetch = (async () => {
      calls++
      const a = answers.shift()
      if (a === undefined || a === "throw") throw new Error("test: network down")
      if (a === "errors") return Response.json({ errors: [{ type: "SERVICE_UNAVAILABLE", message: "try again" }] })
      return a === 200 ? Response.json({ data: { ok: true } }) : new Response("bad gateway", { status: a })
    }) as typeof fetch
    return () => calls
  }
  beforeAll(() => {
    saved.fetch = globalThis.fetch
    saved.token = process.env.GITHUB_TOKEN
    process.env.GITHUB_TOKEN = "test-token"
  })
  afterEach(() => { globalThis.fetch = saved.fetch })
  afterAll(() => { if (saved.token === undefined) delete process.env.GITHUB_TOKEN; else process.env.GITHUB_TOKEN = saved.token })

  it("a 502 then data returns the data", async () => {
    const calls = stub([502, 200])
    expect(await ghGraphql("query{}", {}, [0, 0, 0])).toEqual({ ok: true })
    expect(calls()).toBe(2)
  })
  it("a 200 with errors and no data, then a network error, then data returns the data", async () => {
    const calls = stub(["errors", "throw", 200])
    expect(await ghGraphql("query{}", {}, [0, 0, 0])).toEqual({ ok: true })
    expect(calls()).toBe(3)
  })
  it("a failure on every try throws after the last retry, naming the error", async () => {
    const calls = stub([502, "errors", 503, "errors"])
    await expect(ghGraphql("query{}", {}, [0, 0, 0])).rejects.toThrow("SERVICE_UNAVAILABLE: try again")
    expect(calls()).toBe(4)
  })
  it("a 400 (a bad query) throws at once", async () => {
    const calls = stub([400, 200])
    await expect(ghGraphql("query{}", {}, [0, 0, 0])).rejects.toThrow("HTTP 400")
    expect(calls()).toBe(1)
  })
})

describe("gh() waits once for a spent GITHUB_TOKEN hour", () => {
  // 2026-11-21: the repository token's hour still ran out a few minutes before each reset (14:49Z for 14:51Z),
  // and a promote-gates read in those minutes failed the promote ("API rate limit exceeded for installation").
  // GitHub says when the hour resets; one bounded wait until then and one retry is cheaper than a failed promote.
  const saved: { fetch: typeof fetch; token: string | undefined } = { fetch: globalThis.fetch, token: undefined }
  const NOW = 1_795_272_563_000 // 14:49:23Z
  const limited = (resetIn: number, remaining = "0") => new Response(JSON.stringify({ message: "API rate limit exceeded for installation." }), {
    status: 403, headers: { "x-ratelimit-remaining": remaining, "x-ratelimit-reset": String(Math.floor(NOW / 1000) + resetIn) },
  })
  const stub = (answers: Array<() => Response>) => {
    const calls: Array<string> = []
    globalThis.fetch = (async (input: string | URL | Request) => {
      calls.push(String(input))
      return (answers.shift() ?? (() => new Response(JSON.stringify({ ok: true }), { status: 200 })))()
    }) as typeof fetch
    return calls
  }
  const clock = () => {
    const slept: Array<number> = []
    return { slept, limits: { now: () => NOW, sleep: async (ms: number) => { slept.push(ms) } } }
  }
  beforeAll(() => {
    saved.fetch = globalThis.fetch
    saved.token = process.env.GITHUB_TOKEN
    process.env.GITHUB_TOKEN = "test-token"
  })
  afterEach(() => { globalThis.fetch = saved.fetch })
  afterAll(() => { if (saved.token === undefined) delete process.env.GITHUB_TOKEN; else process.env.GITHUB_TOKEN = saved.token })

  it("a rate-limit 403 waits until the reset, then the retry's 200 is the answer", async () => {
    const calls = stub([() => limited(145)])
    const { slept, limits } = clock()
    expect(await gh("/actions/workflows/backend.yml/runs", {}, [0, 0, 0], limits)).toEqual({ ok: true })
    expect(calls.length).toBe(2)
    expect(slept).toEqual([146_000])
  })
  it("waits at most once: a second refusal throws with the rate-limit detail", async () => {
    const calls = stub([() => limited(145), () => limited(145)])
    const { slept, limits } = clock()
    await expect(gh("/actions/workflows/backend.yml/runs", {}, [0, 0, 0], limits)).rejects.toThrow("HTTP 403")
    expect(calls.length).toBe(2)
    expect(slept.length).toBe(1)
  })
  it("a reset past GH_RATE_LIMIT_WAIT_MS throws at once instead of outliving the job", async () => {
    const calls = stub([() => limited(Math.ceil(GH_RATE_LIMIT_WAIT_MS / 1000) + 60)])
    const { slept, limits } = clock()
    await expect(gh("/actions/workflows/backend.yml/runs", {}, [0, 0, 0], limits)).rejects.toThrow("rate limit")
    expect(calls.length).toBe(1)
    expect(slept).toEqual([])
  })
  it("a 403 with requests left is a permission, never waited on", async () => {
    const calls = stub([() => limited(145, "4200")])
    const { slept, limits } = clock()
    await expect(gh("/issues/9", {}, [0, 0, 0], limits)).rejects.toThrow("HTTP 403")
    expect(calls.length).toBe(1)
    expect(slept).toEqual([])
  })
})

describe("G1 excludes a source-fenced staging skip", () => {
  it("a superseded push neither proves green nor poisons another commit's soak; real smoke failures still count", async () => {
    const savedFetch = globalThis.fetch
    const savedToken = process.env.GITHUB_TOKEN
    process.env.GITHUB_TOKEN = "test-token"
    const jobs = (kind: "green" | "red" | "superseded") => [
      { name: "test", conclusion: "success" },
      { name: "migrations-push-guard", conclusion: "success" },
      { name: "deploy-staging", conclusion: kind === "red" ? "failure" : "success", completed_at: "2026-11-03T10:00:00Z", steps: [
        { name: "Newer deployment inputs already queued; skip", conclusion: kind === "superseded" ? "success" : "skipped" },
        { name: "Smoke the API Worker; roll back on red", conclusion: kind === "green" ? "success" : kind === "red" ? "failure" : "skipped" },
      ] },
    ]
    globalThis.fetch = (async (input: string | URL | Request) => {
      const url = new URL(String(input))
      if (url.host !== "api.github.com") throw new Error(`unexpected host ${url.host}`)
      if (url.pathname.endsWith("/backend.yml/runs")) return Response.json({ workflow_runs: [{ id: 3, head_sha: "stale" }, { id: 2, head_sha: "red" }, { id: 1, head_sha: "green" }] })
      const id = /\/runs\/(\d+)\/jobs$/.exec(url.pathname)?.[1]
      if (!id) throw new Error(`unexpected GitHub path ${url.pathname}`)
      return Response.json({ jobs: jobs(id === "3" ? "superseded" : id === "2" ? "red" : "green") })
    }) as typeof fetch
    try {
      expect(await stagingRuns()).toEqual([
        { sha: "red", at: Date.parse("2026-11-03T10:00:00Z"), green: false },
        { sha: "green", at: Date.parse("2026-11-03T10:00:00Z"), green: true },
      ])
    } finally {
      globalThis.fetch = savedFetch
      if (savedToken === undefined) delete process.env.GITHUB_TOKEN
      else process.env.GITHUB_TOKEN = savedToken
    }
  })
})

describe("G1 reads staging runs over GraphQL when the REST hour is spent", () => {
  // 2026-11-21 16:22Z: the repository token's REST hour ran out 29 minutes before its 16:51Z reset, too far to wait
  // for. GraphQL has its own hour (about 550 of 5,000 used at 16:23Z), and one query answers the run list and every
  // run's three jobs, so G1 still decides.
  it("a REST refusal with a far reset answers from one GraphQL read: pushes to feat-cmux-next only, latest attempt", async () => {
    const savedFetch = globalThis.fetch
    const savedToken = process.env.GITHUB_TOKEN
    process.env.GITHUB_TOKEN = "test-token"
    const check = (name: string, conclusion: string, steps: Array<[string, string]> = []) =>
      ({ nodes: [{ name, conclusion, completedAt: "2026-11-21T15:00:00Z", steps: { nodes: steps.map(([n, c]) => ({ name: n, conclusion: c })) } }] })
    const run = (id: number, sha: string, event: string, branch: string, deploy: string, smoke: string, status = "COMPLETED") => ({
      databaseId: id, event, checkSuite: { status, branch: { name: branch }, commit: { oid: sha },
        deploy: check("deploy-staging", deploy, [["Newer deployment inputs already queued; skip", "SKIPPED"], ["Smoke the API Worker; roll back on red", smoke]]),
        test: check("test", "SUCCESS"), guard: check("migrations-push-guard", "SUCCESS") },
    })
    const calls: Array<string> = []
    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(String(input))
      calls.push(`${init?.method ?? "GET"} ${url.pathname}`)
      if (url.pathname.endsWith("/backend.yml/runs")) return new Response(JSON.stringify({ message: "API rate limit exceeded for installation." }), {
        status: 403, headers: { "x-ratelimit-remaining": "0", "x-ratelimit-reset": String(Math.floor(Date.now() / 1000) + 29 * 60) },
      })
      if (url.pathname === "/graphql") return Response.json({ data: { node: { runs: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [
        run(9, "pr", "pull_request", "lane/x", "SUCCESS", "SUCCESS"),
        run(8, "running", "push", "feat-cmux-next", "SUCCESS", "SUCCESS", "IN_PROGRESS"),
        run(7, "green", "push", "feat-cmux-next", "SUCCESS", "SUCCESS"),
        run(6, "other", "push", "main", "SUCCESS", "SUCCESS"),
        run(5, "red", "push", "feat-cmux-next", "FAILURE", "FAILURE"),
        run(4, "skipped", "push", "feat-cmux-next", "SKIPPED", "SKIPPED"),
      ] } } } })
      throw new Error(`unexpected GitHub path ${url.pathname}`)
    }) as typeof fetch
    try {
      expect(await stagingRuns()).toEqual([
        { sha: "green", at: Date.parse("2026-11-21T15:00:00Z"), green: true },
        { sha: "red", at: Date.parse("2026-11-21T15:00:00Z"), green: false },
      ])
      expect(calls).toEqual(["GET /repos/manaflow-ai/cmux/actions/workflows/backend.yml/runs", "POST /graphql"])
    } finally {
      globalThis.fetch = savedFetch
      if (savedToken === undefined) delete process.env.GITHUB_TOKEN
      else process.env.GITHUB_TOKEN = savedToken
    }
  })
})

describe("gates after a rollback (no person needed to move forward)", () => {
  /** main(["gates"]) against the fake Cloudflare above and a fake GitHub: staging proved `greenSha`, one open P0 issue (G2 stops there). */
  const gates = async (greenSha: string, hold?: string) => {
    const saved = { fetch: globalThis.fetch, token: process.env.GITHUB_TOKEN, hold: process.env.CMUX_NEXT_PRODUCTION_HOLD }
    process.env.GITHUB_TOKEN = "test-token"
    if (hold === undefined) delete process.env.CMUX_NEXT_PRODUCTION_HOLD
    else process.env.CMUX_NEXT_PRODUCTION_HOLD = hold
    const greenJobs = [
      { name: "test", conclusion: "success" },
      { name: "migrations-push-guard", conclusion: "success" },
      { name: "deploy-staging", conclusion: "success", completed_at: "2026-10-19T00:00:00Z", steps: [{ name: "Smoke the API Worker; roll back on red", conclusion: "success" }] },
    ]
    globalThis.fetch = (async (input: string | URL | Request) => {
      const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url)
      if (url.host === "api.cloudflare.com") return fakeFetch(input)
      if (url.host !== "api.github.com") throw new Error(`unexpected host ${url.host}`)
      if (url.pathname.endsWith("/backend.yml/runs")) return Response.json({ workflow_runs: [{ id: 1, head_sha: greenSha }] })
      if (url.pathname.endsWith("/runs/1/jobs")) return Response.json({ jobs: greenJobs })
      if (url.pathname.endsWith("/issues")) return Response.json(url.searchParams.get("labels")?.endsWith("P0") ? [{ number: 7 }] : [])
      throw new Error(`unexpected GitHub path ${url.pathname}`)
    }) as typeof fetch
    const lines: Array<string> = []
    const [log, error] = [console.log, console.error]
    console.log = (...a: Array<unknown>) => void lines.push(a.join(" "))
    console.error = (...a: Array<unknown>) => void lines.push(a.join(" "))
    try {
      return { code: await main(["gates"]), out: lines.join("\n") }
    } finally {
      ;[console.log, console.error] = [log, error]
      globalThis.fetch = saved.fetch
      if (saved.token === undefined) delete process.env.GITHUB_TOKEN
      else process.env.GITHUB_TOKEN = saved.token
      if (saved.hold === undefined) delete process.env.CMUX_NEXT_PRODUCTION_HOLD
      else process.env.CMUX_NEXT_PRODUCTION_HOLD = saved.hold
    }
  }
  // B was promoted, then rolled back onto A: production serves A and holds B.
  const rolledBackFromB = () => {
    versions = { v2: code(repo.B), v1: code(repo.A) }
    setDeployments([{ version: "v1", trigger: "rollback" }, { version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
  }
  it("the rolled-back commit itself holds", async () => {
    rolledBackFromB()
    const r = await gates(repo.B)
    expect(r.code).toBe(3)
    expect(r.out).toContain(`HOLD (rolled-back) production serves a rollback of ${repo.B.slice(0, 12)}`)
  })
  it("a newer staging-proven commit goes on to the other gates with the hold switch unset", async () => {
    rolledBackFromB()
    const r = await gates(repo.C)
    expect(r.out).not.toContain("HOLD (rolled-back)")
    expect(r.out).not.toContain("HOLD (G6)")
    expect(r.out).toContain("HOLD (G2) open P0/P1 regression issues: #7")
  })
  it("a hold a person set still stops it first", async () => {
    rolledBackFromB()
    const r = await gates(repo.C, "on: launch freeze")
    expect(r.out).toContain("HOLD (G6) hold switch: on? launch freeze")
  })
  it("the Chief off switch still holds every automatic promote", async () => {
    versions = { v2: off(repo.A), v1: code(repo.A) }
    setDeployments([{ version: "v2", trigger: "deployment" }, { version: "v1", trigger: "deployment" }])
    const r = await gates(repo.C)
    expect(r.out).toContain("HOLD (rolled-back) production serves the Chief off switch")
  })
})

describe("one promote job reads each finished staging run's jobs once (the shared GITHUB_TOKEN hour)", () => {
  // stale then gates, as backend.yml's promote-gates job runs them, each a fresh process sharing --runs-cache.
  // Before: both read the run list and every listed run's jobs (2 x (1 + 30) calls); the 403 that held promotes
  // came from this read when the repository's token hour was spent (run 44878749398, 2026-11-21).
  const greenJobs = (at: string) => [
    { name: "test", conclusion: "success" },
    { name: "migrations-push-guard", conclusion: "success" },
    { name: "deploy-staging", conclusion: "success", completed_at: at, steps: [{ name: "Smoke the API Worker; roll back on red", conclusion: "success" }] },
  ]
  const run = async (listed: Array<{ id: number; head_sha: string; run_attempt?: number }>, argv: Array<string>) => {
    const saved = { fetch: globalThis.fetch, token: process.env.GITHUB_TOKEN, hold: process.env.CMUX_NEXT_PRODUCTION_HOLD }
    process.env.GITHUB_TOKEN = "test-token"
    delete process.env.CMUX_NEXT_PRODUCTION_HOLD
    const calls: Array<string> = []
    globalThis.fetch = (async (input: string | URL | Request) => {
      const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url)
      if (url.host === "api.cloudflare.com") return fakeFetch(input)
      if (url.host !== "api.github.com") throw new Error(`unexpected host ${url.host}`)
      calls.push(url.pathname.replace(/^\/repos\/[^/]+\/[^/]+/, ""))
      if (url.pathname.endsWith("/backend.yml/runs")) return Response.json({ workflow_runs: listed })
      if (/\/runs\/\d+\/jobs$/.test(url.pathname)) return Response.json({ jobs: greenJobs("2026-10-19T00:00:00Z") })
      if (url.pathname.endsWith("/issues")) return Response.json([])
      throw new Error(`unexpected GitHub path ${url.pathname}`)
    }) as typeof fetch
    const [log, error] = [console.log, console.error]
    console.log = () => {}
    console.error = () => {}
    try {
      // Only the reads matter here: a later gate (G3 reads approvals this repository lacks) may throw.
      await main(argv).catch(() => {})
      return calls
    } finally {
      ;[console.log, console.error] = [log, error]
      globalThis.fetch = saved.fetch
      if (saved.token === undefined) delete process.env.GITHUB_TOKEN
      else process.env.GITHUB_TOKEN = saved.token
      if (saved.hold === undefined) delete process.env.CMUX_NEXT_PRODUCTION_HOLD
      else process.env.CMUX_NEXT_PRODUCTION_HOLD = saved.hold
    }
  }
  const jobReads = (calls: Array<string>) => calls.filter((c) => c.endsWith("/jobs")).sort()

  it("stale then gates read each run's jobs once, and the next promote reads only the new run", async () => {
    versions = { v1: code(repo.A) }
    setDeployments([{ version: "v1", trigger: "deployment" }])
    const cache = join(tmpRoot, "staging-runs.json")
    rmSync(cache, { force: true })
    const listed = [{ id: 3, head_sha: repo.C }, { id: 2, head_sha: repo.B }, { id: 1, head_sha: repo.A }]
    const stale = await run(listed, ["stale", "--runs-cache", cache])
    const gates = await run(listed, ["gates", "--runs-cache", cache])
    expect(jobReads([...stale, ...gates])).toEqual(["/actions/runs/1/jobs", "/actions/runs/2/jobs", "/actions/runs/3/jobs"])
    // The next push: one new run, and run 2 re-run (a new attempt may end differently).
    const next = await run([{ id: 4, head_sha: repo.C }, { id: 3, head_sha: repo.C }, { id: 2, head_sha: repo.B, run_attempt: 2 }, { id: 1, head_sha: repo.A }], ["gates", "--runs-cache", cache])
    expect(jobReads(next)).toEqual(["/actions/runs/2/jobs", "/actions/runs/4/jobs"])
  })

  it("a cached verdict for another commit is read again, never trusted", async () => {
    versions = { v1: code(repo.A) }
    setDeployments([{ version: "v1", trigger: "deployment" }])
    const cache = join(tmpRoot, "staging-runs-mismatch.json")
    writeFileSync(cache, JSON.stringify({ "1:1": { sha: repo.B, run: { sha: repo.B, at: 0, green: true } } }))
    const calls = await run([{ id: 1, head_sha: repo.A }], ["gates", "--runs-cache", cache])
    expect(jobReads(calls)).toEqual(["/actions/runs/1/jobs"])
  })
})
