#!/usr/bin/env bun
// Writes the preview fixtures (invented, neutral data) for the preview harness
// and the FakeHost tests. Tool catalogs come from @cmux/integrations-core (the
// code the app ships), run over the package's test fixtures. Usage: bun first-party-apps/integrations/preview/make-fixtures.ts
import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { importDocument, type Catalog, type PolicyRule } from "@cmux/integrations-core"
import { MAX_CONNECTIONS, sortConnections, type Connection } from "../src/model/connections.ts"
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
  mcp_exposed: false,
  ...over
})

const catalogOf = (c: Catalog, source_url: string) => ({ kind: c.kind, title: c.title, ...(c.version ? { version: c.version } : {}), digest: c.digest, source_url })

export const connections: Connection[] = [
  base("github", "github", { account: { key: "github:installation:4211", name: "orbit-labs" }, sharing: "team", scopes_granted: ["issues:write", "pull_requests:read", "metadata:read"], resources: { repos: ["orbit-labs/api", "orbit-labs/web", "orbit-labs/docs"] }, mcp_exposed: true }),
  base("linear", "linear", { account: { key: "linear:org:77", name: "Orbit" }, scopes_granted: ["read", "issues:create"] }),
  base("slack", "slack", { account: { key: "slack:team:T0ORBIT", name: "orbit-team" }, status: "needs_reauth", sharing: "team", created_by: OTHER, scopes_granted: ["chat:write"] }),
  base("linearpending", "linear", { status: "pending" }),
  base("taskboard", "openapi", {
    account: { key: "openapi:specs.taskboard.example.com:taskboard_api", name: "Taskboard API" },
    catalog: catalogOf(taskboard, "https://specs.taskboard.example.com/openapi.json"),
    auth: { kind: "api_key" },
    mcp_exposed: true
  }),
  base("docs", "mcp", {
    account: { key: "mcp:mcp.docs.example.com:docs_server", name: "Docs Server" },
    sharing: "team",
    catalog: { ...catalogOf(docs, "https://mcp.docs.example.com/mcp"), changed: { at: T0 + 86_400_000, feed_item: "feed_catalogdocs0000001", previous_digest: "mcp:00000000" } },
    auth: { kind: "oauth2_code" }
  })
]

const providers = [
  { provider: "github", configured: true },
  { provider: "linear", configured: true },
  { provider: "slack", configured: true }
]

const policy = { allowed_providers: null, generic_hosts: null, github: { scope: "linking_user_repos", require_org_admin: false, repo_allowlist: null }, source: "admin", locked: false, updated_at: T0, updated_by: OTHER }

const ME_VIEWER = { user: ME, team_admin: false }
const live = (cs: Connection[]) => cs.filter((c) => c.status !== "revoked" && c.status !== "expired").length
const list = (cs: Connection[], over: Record<string, unknown> = {}) => ({ connections: cs, providers, revision: "r12", viewer: ME_VIEWER, limit: { used: live(cs) + 3, max: MAX_CONNECTIONS }, ...over })

const rule = (rid: string, owner: "team" | "user", pattern: string, action: PolicyRule["action"]): PolicyRule => ({ id: rid, owner, pattern, action })

const ns = taskboard.namespace
const toolsFor = (c: Connection) => {
  if (c.provider === "openapi")
    return {
      namespace: ns,
      tools: taskboard.tools,
      rules: [
        // Team (ConnectionDO): every task tool asks. The user's looser rule on listTasks loses (most restrictive wins).
        rule("pol_t1", "team", `${ns}.tasks.*`, "ask"),
        rule("pol_u1", "user", `${ns}.tasks.listTasks`, "allow"),
        // User (UserDO): an exact allow, and a subtree allow that cannot unblock deleteProject (only an exact rule can).
        rule("pol_u3", "user", `${ns}.projects.createProject`, "allow"),
        rule("pol_u4", "user", `${ns}.projects.*`, "allow")
      ],
      catalog: catalogOf(taskboard, "https://specs.taskboard.example.com/openapi.json")
    }
  if (c.provider === "mcp") return { namespace: docs.namespace, tools: docs.tools, rules: [rule("pol_u2", "user", `${docs.namespace}.create_page_2`, "block")], catalog: catalogOf(docs, "https://mcp.docs.example.com/mcp") }
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
  "integration.mcp.set": { scope: "integration:write", class: "mutation" },
  "app.pane.open": { scope: "workspace:write", class: "mutation" },
  "ui.open": { scope: "workspace:write", class: "mutation" }
}

const write = (name: string, value: unknown) => writeFileSync(join(here, `${name}.json`), JSON.stringify(value, null, 2) + "\n")

const githubTools = toolsFor(connections[0]!)
const docsTools = toolsFor(connections[5]!)
write("connections", { scopes, ops: { "integration.list": list(connections), "integration.policy.get": policy, "integration.tools.list": githubTools } })
write("catalog", { scopes, ops: { "integration.list": list(connections), "integration.policy.get": policy, "integration.tools.list": { $sequence: activeOrder.map(toolsFor) } } })
write("taskboard", { scopes, ops: { "integration.list": list(connections), "integration.policy.get": policy, "integration.tools.list": toolsFor(connections[4]!) } })
write("docs", { scopes, ops: { "integration.list": list(connections), "integration.policy.get": policy, "integration.tools.list": docsTools } })
// Today's backend: no tools.list, so a first-class provider falls back to the provider ops this app knows.
write("reauth", { scopes, ops: { "integration.list": list(connections), "integration.policy.get": policy } })
// A team admin: may sign in again, share and disconnect a teammate's team-shared connection (audited).
write("admin", { scopes, ops: { "integration.list": list(connections, { viewer: { user: ME, team_admin: true } }), "integration.policy.get": policy } })
write("empty", { scopes, ops: { "integration.list": list([], { limit: { used: 0, max: MAX_CONNECTIONS } }), "integration.policy.get": { ...policy, source: "default", updated_at: null, updated_by: null } } })
write("limit", { scopes, ops: { "integration.list": list(connections, { limit: { used: MAX_CONNECTIONS, max: MAX_CONNECTIONS } }), "integration.policy.get": policy } })
write("managed", {
  scopes,
  ops: {
    "integration.list": list(connections.filter((c) => c.provider !== "slack")),
    "integration.policy.get": { ...policy, allowed_providers: ["github", "linear", "openapi"], generic_hosts: ["*.taskboard.example.com"], source: "sso", locked: true }
  }
})
// The gateway's URL preview refused the target after DNS (the owner's answer; the app's own pre-check passed).
write("egress", {
  scopes,
  ops: {
    "integration.list": list(connections),
    "integration.policy.get": policy,
    "integration.catalog.preview": { $error: { code: "egress.private_target", message: "resolves to a private address", details: { host: "specs.internal-mirror.example.com" } } }
  }
})
write("missing", { ops: {} })
writeFileSync(join(here, "taskboard-spec.min.json"), JSON.stringify(testFixture("openapi-taskboard.json")) + "\n")
console.log("fixtures written")
