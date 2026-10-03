#!/usr/bin/env bun
// Writes the preview fixtures (invented, neutral data) for the preview harness
// and the FakeHost tests. Tool catalogs come from @cmux/integrations-core (the
// code the app ships), run over the package's test fixtures. Usage: bun first-party-apps/integrations/preview/make-fixtures.ts
import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { importDocument, type PolicyRule } from "@cmux/integrations-core"
import { sortConnections, type Connection } from "../src/model/connections.ts"
import { builtinTools } from "../src/model/providers.ts"

const here = import.meta.dir
const testFixture = (name: string) => JSON.parse(readFileSync(join(here, "../../../libs/integrations-core/test/fixtures", name), "utf8"))

const T0 = 1_790_000_000_000
const ME = "usr_me"
const OTHER = "usr_ada"
const id = (seed: string) => `conn_${seed.padEnd(20, "0").slice(0, 20)}`

const taskboard = importDocument(testFixture("openapi-taskboard.json"), { sourceUrl: "https://specs.taskboard.example.com/openapi.json" })
const docs = importDocument(testFixture("mcp-tools.json"), { serverInfo: { name: "Docs Server", version: "1.2.0" }, sourceUrl: "https://mcp.docs.example.com/mcp" })

const base = (seed: string, provider: string, over: Partial<Connection>): Connection => ({
  id: id(seed),
  owner: "team_orbit",
  created_by: ME,
  provider,
  account: null,
  scopes_requested: [],
  scopes_granted: [],
  status: "active",
  sharing: "private",
  created_at: T0,
  updated_at: T0,
  capabilities: { revoke: true, share: true, reauth: true },
  ...over
})

export const connections: Connection[] = [
  base("github", "github", { account: { key: "github:installation:4211", name: "orbit-labs" }, sharing: "team", scopes_granted: ["issues:write", "pull_requests:read", "metadata:read"], resources: { repos: ["orbit-labs/api", "orbit-labs/web", "orbit-labs/docs"] } }),
  base("linear", "linear", { account: { key: "linear:org:77", name: "Orbit" }, scopes_granted: ["read", "issues:create"] }),
  base("slack", "slack", { account: { key: "slack:team:T0ORBIT", name: "orbit-team" }, status: "needs_reauth", sharing: "team", created_by: OTHER, scopes_granted: ["chat:write"], capabilities: { revoke: false, share: false, reauth: true } }),
  base("calendar", "google_calendar", { status: "pending" }),
  base("taskboard", "openapi", {
    account: { key: "openapi:taskboard", name: "Taskboard API" },
    catalog: { kind: "openapi", title: taskboard.title, version: taskboard.version!, digest: taskboard.digest, tools: taskboard.tools.length, source_url: "https://specs.taskboard.example.com/openapi.json" }
  }),
  base("docs", "mcp", { account: { key: "mcp:docs", name: "Docs Server" }, sharing: "team", catalog: { kind: "mcp", title: docs.title, version: docs.version!, digest: docs.digest, tools: docs.tools.length, source_url: "https://mcp.docs.example.com/mcp" } })
]

const providers = [
  { provider: "github", configured: true },
  { provider: "linear", configured: true },
  { provider: "slack", configured: true },
  { provider: "google_calendar", configured: true }
]

const policy = { allowed_providers: null, github: { scope: "linking_user_repos", require_org_admin: false, repo_allowlist: null }, source: "admin", locked: false, updated_at: T0, updated_by: OTHER }

const list = (cs: Connection[]) => ({ connections: cs, providers, revision: "r12" })

const rule = (rid: string, owner: "team" | "user", pattern: string, action: PolicyRule["action"]): PolicyRule => ({ id: rid, owner, pattern, action })

const toolsFor = (c: Connection) => {
  if (c.provider === "openapi")
    return {
      namespace: taskboard.namespace,
      tools: taskboard.tools,
      // The team asks for every task tool; the user's looser rule on listTasks loses (most restrictive wins).
      rules: [rule("pol_t1", "team", `${taskboard.namespace}.tasks.*`, "ask"), rule("pol_u1", "user", `${taskboard.namespace}.tasks.listTasks`, "allow"), rule("pol_u3", "user", `${taskboard.namespace}.projects.createProject`, "allow")],
      catalog: { title: taskboard.title, version: taskboard.version, digest: taskboard.digest, refreshed_at: T0 }
    }
  if (c.provider === "mcp") return { namespace: docs.namespace, tools: docs.tools, rules: [rule("pol_u2", "user", `${docs.namespace}.create_page_2`, "block")], catalog: { title: docs.title, digest: docs.digest, refreshed_at: T0 } }
  return { namespace: c.provider, tools: builtinTools(c.provider), rules: c.provider === "github" ? [rule("pol_t2", "team", "github.issue.comment", "ask")] : [] }
}

/** tools.list answers in the order the catalog view loads active connections (the app's own sort). */
const activeOrder = sortConnections(connections).filter((c) => c.status === "active")

const scopes = {
  // Existing backend ops the preview host's scope table may not list yet.
  "integration.list": { scope: "integration:read", class: "read" },
  "integration.policy.get": { scope: "integration:read", class: "read" },
  "integration.connect": { scope: "integration:write", class: "mutation" },
  "integration.tools.list": { scope: "integration:read", class: "read" },
  "integration.tools.policy.set": { scope: "integration:write", class: "mutation" },
  "integration.catalog.preview": { scope: "integration:read", class: "read" },
  "integration.share": { scope: "integration:write", class: "mutation" },
  "integration.reauth": { scope: "integration:write", class: "mutation" },
  "integration.revoke": { scope: "integration:write", class: "mutation" },
  "app.pane.open": { scope: "workspace:write", class: "mutation" }
}

const write = (name: string, value: unknown) => writeFileSync(join(here, `${name}.json`), JSON.stringify(value, null, 2) + "\n")

const githubTools = toolsFor(connections[0]!)
write("connections", { scopes, ops: { "integration.list": list(connections), "integration.policy.get": policy, "integration.tools.list": githubTools } })
write("catalog", { scopes, ops: { "integration.list": list(connections), "integration.policy.get": policy, "integration.tools.list": { $sequence: activeOrder.map(toolsFor) } } })
write("taskboard", { scopes, ops: { "integration.list": list(connections), "integration.policy.get": policy, "integration.tools.list": toolsFor(connections[4]!) } })
// Today's backend: no tools.list, so a first-class provider falls back to the provider ops this app knows.
write("reauth", { scopes, ops: { "integration.list": list(connections), "integration.policy.get": policy } })
write("empty", { scopes, ops: { "integration.list": list([]), "integration.policy.get": { ...policy, source: "default", updated_at: null, updated_by: null } } })
write("managed", {
  scopes,
  ops: {
    "integration.list": list(connections.filter((c) => c.provider !== "slack")),
    "integration.policy.get": { ...policy, allowed_providers: ["github", "linear"], source: "sso", locked: true }
  }
})
write("missing", { ops: {} })
writeFileSync(join(here, "taskboard-spec.min.json"), JSON.stringify(testFixture("openapi-taskboard.json")) + "\n")
console.log("fixtures written")
