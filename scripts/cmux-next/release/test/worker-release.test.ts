/** worker-release.ts with a fake Worker (Bun.serve) and a fake wrangler (a script that logs its argv). */
import { execFileSync } from "node:child_process"
import { afterAll, describe, expect, it } from "bun:test"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { currentVersion, globRegex, main, selectRoutes, type Route } from "../worker-release.ts"

const dir = mkdtempSync(join(tmpdir(), "rails-worker-"))
const calls = join(dir, "wrangler-calls.txt")

/** Fake wrangler: `deployments status --json` prints STATUS_JSON; rollback succeeds unless ROLLBACK_FAIL=1. */
const wrangler = join(dir, "wrangler")
writeFileSync(
  wrangler,
  `#!/bin/sh
echo "$*" >> "${calls}"
case "$1" in
  deployments) [ -n "$STATUS_JSON" ] && { printf '%s' "$STATUS_JSON"; exit 0; }; echo "no deployments" >&2; exit 1 ;;
  rollback) [ "$ROLLBACK_FAIL" = 1 ] && { echo "rollback refused" >&2; exit 1; }; echo "rolled back"; exit 0 ;;
esac
exit 2
`,
)
chmodSync(wrangler, 0o755)

/** The fake Worker answers what `state` says; a rollback flips it to healthy, like the old version would. */
const state = { broken: false }
const server = Bun.serve({
  port: 0,
  fetch(req) {
    const path = new URL(req.url).pathname
    if (path === "/healthz") return Response.json({ ok: true })
    if (state.broken) return Response.json({ _tag: "ServiceUnavailable", message: "Database schema not applied; retry" }, { status: 503 })
    return new Response("unauthorized", { status: 401 })
  },
})
afterAll(() => server.stop(true))
const base = `http://127.0.0.1:${server.port}`

const routesFile = join(dir, "routes.json")
const routes: Array<Route> = [
  { name: "health", method: "GET", path: "/healthz", expect: [200], bodyIncludes: '"ok":true' },
  { name: "schema gate", method: "GET", path: "/v1/vms", expect: [401] },
  { name: "webhook", method: "POST", path: "/v1/webhooks/stack", body: "{}", expect: [401], sources: ["src/handlers/stack-webhook.ts"] },
]
writeFileSync(routesFile, JSON.stringify({ routes }))

const run = async (argv: Array<string>, env: Record<string, string> = {}) => {
  const logs: Array<string> = []
  const errors: Array<string> = []
  const vars = { STATUS_JSON: "", ROLLBACK_FAIL: "", ...env }
  for (const [k, v] of Object.entries(vars)) process.env[k] = v
  try {
    const code = await main(argv, { log: (l) => logs.push(l), error: (l) => errors.push(l) })
    return { code, logs, errors }
  } finally {
    for (const k of Object.keys(vars)) delete process.env[k]
  }
}
const wranglerCalls = () => (existsSync(calls) ? readFileSync(calls, "utf8").trim().split("\n").filter(Boolean) : [])
const verify = (extra: Array<string> = []) => ["verify", "--worker", "cmux-vm-staging", "--url", base, "--routes", routesFile, "--wrangler", wrangler, "--attempts", "2", "--interval-ms", "10", ...extra]

describe("previous", () => {
  it("records the version serving 100%", async () => {
    const out = join(dir, "prev.txt")
    const r = await run(["previous", "--worker", "cmux-vm-staging", "--wrangler", wrangler, "--out", out], { STATUS_JSON: JSON.stringify({ id: "d1", versions: [{ version_id: "v-old", percentage: 100 }] }) })
    expect(r.code).toBe(0)
    expect(readFileSync(out, "utf8")).toBe("v-old")
  })
  it("refuses while a gradual deployment is in progress", () => {
    expect(() => currentVersion(JSON.stringify({ versions: [{ version_id: "a", percentage: 50 }, { version_id: "b", percentage: 50 }] }))).toThrow("gradual")
  })
  it("P2-11 refuses when wrangler cannot report the serving version (no rollback target), unless --allow-first-deploy", async () => {
    const out = join(dir, "prev-none.txt")
    const r = await run(["previous", "--worker", "new-worker", "--wrangler", wrangler, "--out", out])
    expect(r.code).toBe(1)
    expect(r.errors.join()).toContain("no rollback target")
    const first = await run(["previous", "--worker", "new-worker", "--wrangler", wrangler, "--out", out, "--allow-first-deploy"])
    expect(first.code).toBe(0)
    expect(readFileSync(out, "utf8")).toBe("")
  })
  it("P3 picks the newest deployment by created_on, not by list order", () => {
    const list = [
      { created_on: "2026-10-09T02:00:00Z", versions: [{ version_id: "v-new", percentage: 100 }] },
      { created_on: "2026-10-01T02:00:00Z", versions: [{ version_id: "v-older", percentage: 100 }] },
    ]
    expect(currentVersion(JSON.stringify(list))).toBe("v-new")
  })
})

describe("advance", () => {
  const repo = join(dir, "source")
  const origin = join(dir, "origin.git")
  const gitEnv = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("GIT_")))
  const git = (...args: Array<string>) => execFileSync("git", ["-c", "core.hooksPath=/dev/null", "-C", repo, ...args], { encoding: "utf8", env: gitEnv }).trim()
  execFileSync("git", ["init", "-q", repo], { env: gitEnv })
  execFileSync("git", ["init", "-q", "--bare", origin], { env: gitEnv })
  git("config", "user.email", "test@example.invalid")
  git("config", "user.name", "test")
  git("config", "commit.gpgsign", "false")
  mkdirSync(join(repo, ".github/workflows"), { recursive: true })
  mkdirSync(join(repo, "backend"))
  const workflowPath = join(repo, ".github/workflows/backend.yml")
  writeFileSync(workflowPath, readFileSync(new URL("../../../../.github/workflows/backend.yml", import.meta.url), "utf8"))
  writeFileSync(join(repo, "backend/code"), "A")
  const commit = (message: string) => { git("add", "-A"); git("commit", "-qm", message); return git("rev-parse", "HEAD") }
  const a = commit("A")
  writeFileSync(join(repo, "backend/code"), "B")
  const b = commit("B backend change")
  git("checkout", "--detach", a)
  writeFileSync(join(repo, "ui.txt"), "UI-only")
  const ui = commit("UI-only after A")
  git("checkout", "--detach", a)
  writeFileSync(join(repo, "backend/code"), "C")
  const c = commit("divergent backend change")
  git("checkout", "--detach", a)
  writeFileSync(workflowPath, "on:\n  push:\n    paths: ['.github/workflows/backend.yml', '!backend/**']\n")
  const unsupported = commit("unsupported path syntax")
  git("checkout", "--detach", a)
  git("mv", "backend/code", "moved-to-ui.txt")
  const renamed = commit("remove backend input by rename")
  git("remote", "add", "origin", origin)
  git("push", "--quiet", "origin", `${b}:refs/heads/feat-cmux-next`, `${ui}:refs/heads/ui`, `${c}:refs/heads/divergent`, `${unsupported}:refs/heads/unsupported`, `${renamed}:refs/heads/renamed`)
  const check = async (candidate: string, tip: string | null, branch = "feat-cmux-next") => {
    git("checkout", "--detach", candidate)
    if (tip) execFileSync("git", ["--git-dir", origin, "update-ref", `refs/heads/${branch}`, tip], { env: gitEnv })
    const out = join(dir, "advance-output")
    writeFileSync(out, "")
    const before = wranglerCalls().length
    const result = await run(["advance", "--branch", branch, "--source-dir", repo, "--github-output", out])
    return { ...result, output: readFileSync(out, "utf8"), calls: wranglerCalls().slice(before) }
  }
  it("skips older A when a newer backend B is queued, without calling a provider or mutation", async () => {
    const r = await check(a, b)
    expect(r.code).toBe(0)
    expect(r.output).toBe("deploy=false\n")
    expect(r.logs.join()).toContain("newer deployment inputs")
    expect(r.calls).toEqual([])
  })
  it("X running, B pending, then slow A arrives: B survives and only B deploys", async () => {
    const workflow = Bun.YAML.parse(readFileSync(new URL("../../../../.github/workflows/backend.yml", import.meta.url), "utf8")) as any
    for (const environment of ["development", "staging"]) {
      const policy = workflow.jobs[`deploy-${environment}`].concurrency
      const pending: Array<string> = []
      // GitHub's documented concurrency policy: single replaces the pending slot;
      // max retains the waiting jobs. X already holds the one running slot.
      for (const arriving of [b, a]) {
        if (policy.queue !== "max") pending.length = 0
        pending.push(arriving)
      }
      const deployed: Array<string> = []
      for (const candidate of pending) {
        const result = await check(candidate, b)
        expect(result.code).toBe(0)
        if (result.output === "deploy=true\n") deployed.push(candidate)
      }
      expect(deployed).toEqual([b])
    }
  })
  it("admits the current protected source, including same-source retries", async () => {
    const r = await check(b, b)
    expect(r.code).toBe(0)
    expect(r.output).toBe("deploy=true\n")
  })
  it("admits A when the newer protected tip changes only UI and would not trigger backend", async () => {
    const r = await check(a, ui)
    expect(r.code).toBe(0)
    expect(r.output).toBe("deploy=true\n")
  })
  it("removing a backend input by renaming it outside the surface supersedes too", async () => {
    expect((await check(a, renamed)).output).toBe("deploy=false\n")
  })
  it("a newer workflow declaration supersedes the candidate too", async () => {
    expect((await check(a, unsupported)).output).toBe("deploy=false\n")
  })
  it("refuses unavailable refs, divergent histories and unsupported declarations", async () => {
    for (const [candidate, tip, branch] of [[b, null, "missing"], [b, c, "feat-cmux-next"], [unsupported, unsupported, "feat-cmux-next"]] as const) {
      const r = await check(candidate, tip, branch)
      expect(r.code).toBe(1)
      expect(r.output).toBe("")
      expect(r.calls).toEqual([])
    }
  })
})

describe("backend deployment lock wiring", () => {
  const workflow = Bun.YAML.parse(readFileSync(new URL("../../../../.github/workflows/backend.yml", import.meta.url), "utf8")) as any
  it("separates trusted NEXT push runs while preserving complete environment locks", () => {
    expect(workflow.concurrency.group).toContain("github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next' && format('-{0}', github.sha)")
    expect(workflow.concurrency["cancel-in-progress"]).toBe(false)
    expect(workflow.jobs["vitess-development"].concurrency).toEqual({ group: "cmux-next-vitess-development", queue: "max", "cancel-in-progress": false })
    for (const environment of ["development", "staging"]) {
      const job = workflow.jobs[`deploy-${environment}`]
      expect(job.concurrency).toEqual({ group: `cmux-next-deploy-${environment}`, queue: "max", "cancel-in-progress": false })
      const guard = job.steps.findIndex((s: any) => s.id === "source")
      expect(guard).toBeGreaterThan(0)
      expect(job.steps[guard].env).toBeUndefined()
      expect(job.steps[guard].run).toContain("advance --branch feat-cmux-next")
      const mutations = job.steps.slice(guard + 1).filter((s: any) => s.name !== "Newer deployment inputs already queued; skip")
      expect(mutations.length).toBeGreaterThan(2)
      for (const step of mutations) expect(step.if).toContain("steps.source.outputs.deploy == 'true'")
      const smoke = mutations.find((s: any) => s.name.startsWith("Smoke the API Worker"))
      expect(smoke.if).toContain("always()")
      expect(smoke.if).toContain("steps.deploy-api.outcome != 'skipped'")
    }
  })
})

describe("verify", () => {
  it("green: no rollback", async () => {
    state.broken = false
    const before = wranglerCalls().length
    const r = await run(verify(["--previous", "v-old"]))
    expect(r.code).toBe(0)
    expect(wranglerCalls().length).toBe(before)
  })

  it("red (every route 503, the schema gate): rolls back to the previous version, then fails the job", async () => {
    state.broken = true
    const r = await run(verify(["--previous", "v-old"]))
    expect(r.code).toBe(1)
    expect(wranglerCalls().at(-1)).toStartWith("rollback v-old --name cmux-vm-staging -y --message auto-rollback: smoke red (schema gate")
    expect(r.errors.join("\n")).toContain("rolled cmux-vm-staging back to v-old")
  })

  it("red without a recorded previous version: fails without calling rollback", async () => {
    state.broken = true
    const before = wranglerCalls().length
    const r = await run(verify(["--previous-file", join(dir, "prev-none.txt")]))
    expect(r.code).toBe(1)
    expect(r.errors.join()).toContain("cannot roll back automatically")
    expect(wranglerCalls().length).toBe(before)
  })

  it("red and the rollback itself fails: fails loudly", async () => {
    state.broken = true
    const r = await run(verify(["--previous", "v-old"]), { ROLLBACK_FAIL: "1" })
    expect(r.code).toBe(1)
    expect(r.errors.join()).toContain("wrangler rollback v-old failed")
  })
})

describe("route selection", () => {
  it("always runs routes without sources; runs a sourced route only when a matching file changed", () => {
    expect(selectRoutes(routes, []).map((r) => r.name)).toEqual(["health", "schema gate"])
    expect(selectRoutes(routes, ["src/handlers/stack-webhook.ts"]).map((r) => r.name)).toEqual(["health", "schema gate", "webhook"])
    expect(selectRoutes(routes, undefined).map((r) => r.name)).toEqual(["health", "schema gate", "webhook"])
    expect(selectRoutes([{ name: "g", method: "GET", path: "/", expect: [200], sources: ["src/mesh/**"] }], ["src/mesh/acl.ts"]).length).toBe(1)
  })

  it("the committed route files parse and every route has a name, a path and expected statuses", async () => {
    for (const file of ["workers/cmux-vm/release-smoke.json", "backend/apps/api/release-smoke.json"]) {
      const { REPO_ROOT } = await import("../trees.ts")
      const parsed = JSON.parse(readFileSync(join(REPO_ROOT, file), "utf8")) as { routes: Array<Route> }
      expect(parsed.routes.length).toBeGreaterThan(0)
      for (const r of parsed.routes) expect(r.name && r.path.startsWith("/") && r.expect.length > 0).toBe(true)
    }
  })

  it("every source glob in the committed route files matches at least one file", async () => {
    const { REPO_ROOT } = await import("../trees.ts")
    const { execFileSync } = await import("node:child_process")
    for (const [file, dir] of [["workers/cmux-vm/release-smoke.json", "workers/cmux-vm"], ["backend/apps/api/release-smoke.json", "backend/apps/api"]] as const) {
      const files = execFileSync("git", ["-C", join(REPO_ROOT, dir), "ls-files"], { encoding: "utf8" }).split("\n").filter(Boolean)
      const parsed = JSON.parse(readFileSync(join(REPO_ROOT, file), "utf8")) as { routes: Array<Route> }
      for (const r of parsed.routes)
        for (const g of r.sources ?? []) expect({ file, route: r.name, glob: g, matches: files.some((f) => globRegex(g).test(f)) }).toEqual({ file, route: r.name, glob: g, matches: true })
    }
  })
})
