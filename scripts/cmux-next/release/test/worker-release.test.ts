/** worker-release.ts with a fake Worker (Bun.serve) and a fake wrangler (a script that logs its argv). */
import { afterAll, describe, expect, it } from "bun:test"
import { chmodSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
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
