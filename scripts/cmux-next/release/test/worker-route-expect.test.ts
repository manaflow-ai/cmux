// Per-Worker route expectations (release-smoke.json `expectByWorker`): production cmux-vm has no
// Stack webhook secret yet, so its webhook route answers 503 by design while staging must answer 401.
import { describe, expect, it } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { routesFor, type Route } from "../worker-release.ts"
import { REPO_ROOT } from "../trees.ts"

const webhook: Route = { name: "stack webhook", method: "POST", path: "/v1/webhooks/stack", expect: [401], expectByWorker: { "cmux-vm-production": [503] } }

describe("routesFor", () => {
  it("uses a Worker's own expectation when the route names it, else the default", () => {
    expect(routesFor([webhook], "cmux-vm-production")[0]?.expect).toEqual([503])
    expect(routesFor([webhook], "cmux-vm-staging")[0]?.expect).toEqual([401])
  })

  it("keeps every other field", () => {
    expect(routesFor([webhook], "cmux-vm-production")[0]).toMatchObject({ name: "stack webhook", method: "POST", path: "/v1/webhooks/stack" })
  })
})

describe("committed cmux-vm smoke routes", () => {
  const routes = (JSON.parse(readFileSync(join(REPO_ROOT, "workers/cmux-vm/release-smoke.json"), "utf8")) as { routes: Array<Route> }).routes
  const stack = routes.find((r) => r.path === "/v1/webhooks/stack")

  it("staging must answer 401 on the Stack webhook (the 2026-10-07 incident guard stays)", () => {
    expect(routesFor(routes, "cmux-vm-staging").find((r) => r.path === "/v1/webhooks/stack")?.expect).toEqual([401])
  })

  it("production answers 503 there until its Stack webhook secret exists, and says why", () => {
    expect(routesFor(routes, "cmux-vm-production").find((r) => r.path === "/v1/webhooks/stack")?.expect).toEqual([503])
    expect(stack?.why ?? "").toContain("STACK_WEBHOOK_SECRET")
  })
})
