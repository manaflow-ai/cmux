import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { fixture, lastGesture, makeHost, run, submit, tap, texts, visible } from "./harness.ts"
import { scanCalls } from "./l10n-scan.ts"

const FOCUS_OPS = ["workspace.focus", "pane.focus", "tab.focus", "screen.focus", "terminal.input.focus", "browser.activate"]
const SPEC = readFileSync(join(import.meta.dir, "../preview/taskboard-spec.min.json"), "utf8").trim()
const names = (host: ReturnType<typeof makeHost>) => host.calls.map((c) => c.name)
const callsOf = (host: ReturnType<typeof makeHost>, op: string) => host.calls.filter((c) => c.name === op)
const ok = (value: unknown) => () => ({ ok: true, body: { value } })
const fail = (code: string, message = code) => () => ({ ok: false, body: { code, message } })

async function pane(variant = "connections", ops = fixture("connections").ops, extra = {}) {
  const host = makeHost({ variant }, ops, extra)
  expect(host.mount("m", "renderPane")).toBe("")
  await host.settle(20)
  return host
}

describe("variants read the owner's records", () => {
  test("connections: list sorted attention first, from integration.list and integration.policy.get only", async () => {
    const host = await pane("connections")
    expect(names(host)).toEqual(["integration.list", "integration.policy.get"])
    const all = texts(host, "m")
    expect(all.indexOf("orbit-team")).toBeLessThan(all.indexOf("orbit-labs"))
    expect(all).toContain("Needs sign-in")
    expect(all).toContain("1 need attention")
    expect(all).toContain("Team policy set by an admin")
    expect(host.calls.filter((c) => FOCUS_OPS.includes(c.name))).toEqual([])
    expect(host.timers.size).toBe(0)
  })

  test("gallery: providers first; configured ones connect, others say why", async () => {
    const host = await pane("gallery")
    const all = texts(host, "m")
    for (const name of ["GitHub", "Linear", "Slack", "Google Calendar", "Gmail", "OpenAPI", "GraphQL", "MCP"]) expect(all).toContain(name)
    expect(all.filter((s) => s === "Coming")).toHaveLength(2) // Google Calendar and Gmail: shown, not connectable
    expect(all).toContain("9 of 50 connections")
    expect(all).toContain("Your connections")
  })

  test("catalog: loads every active connection's tools and shows each policy", async () => {
    const host = await pane("catalog", fixture("catalog").ops)
    expect(callsOf(host, "integration.tools.list").map((c) => c.params.connection)).toHaveLength(4)
    const all = texts(host, "m")
    expect(all).toContain("Delete a project")
    expect(all).toContain("Default: destructive")
    expect(all).toContain("Set by your team")
    expect(all).toContain("github.issue.comment")
  })

  test("empty and missing states", async () => {
    const empty = await pane("connections", fixture("empty").ops)
    expect(texts(empty, "m")).toContain("No integrations yet")
    const missing = await pane("connections", fixture("missing").ops)
    expect(texts(missing, "m")).toContain("integration.list is not available yet.")
  })

  test("integration.changed on the user stream re-reads the list once per event; nothing polls", async () => {
    const host = await pane("connections")
    host.mount("s", "renderSection")
    await host.settle(20)
    const before = callsOf(host, "integration.list").length
    host.emit("integration.changed", { connection: "conn_github00000000000000" })
    await host.settle(20)
    expect(callsOf(host, "integration.list")).toHaveLength(before + 1)
    expect(host.timers.size).toBe(0)
  })

  test("cycleVariant walks the three designs", async () => {
    const host = await pane("connections")
    expect((await run(host, "cycleVariant")).body).toMatchObject({ value: { variant: "gallery" } })
    expect((await run(host, "cycleVariant")).body).toMatchObject({ value: { variant: "catalog" } })
    expect((await run(host, "cycleVariant")).body).toMatchObject({ value: { variant: "connections" } })
  })
})

const listOf = (name: string) => (fixture(name).ops["integration.list"] as { connections: Array<Record<string, unknown>> }).connections
const record = (name: string, provider: string) => listOf(name).find((c) => c.provider === provider)!

describe("connections", () => {
  test("detail shows health, account, sharing and the tool catalog from integration.tools.list", async () => {
    const host = await pane()
    await tap(host, "m", "orbit-labs")
    expect(callsOf(host, "integration.tools.list")[0]!.params).toEqual({ connection: "conn_github00000000000000" })
    const all = texts(host, "m")
    expect(all).toContain("Shared with team")
    expect(all).toContain("3 repositories")
    expect(all).toContain("github.issue.comment")
    expect(all).toContain("Set by your team")
  })

  test("a teammate's team-shared connection: no Sign In Again, Share or Disconnect for a member, and the app says who can", async () => {
    const host = await pane("connections", fixture("reauth").ops)
    await tap(host, "m", "orbit-team")
    const all = texts(host, "m")
    expect(all).toContain("Built-in list")
    expect(all).not.toContain("Sign In Again")
    expect(all).not.toContain("Disconnect")
    expect(all).not.toContain("Make Private")
    expect(all).toContain("The person who connected it or a team admin can sign in again.")
    expect(all).toContain("Only the person who connected it or a team admin can disconnect it.")
  })

  test("re-auth (team admin): Sign In Again runs integration.reauth with the tap's gesture and keeps the connection", async () => {
    const slack = record("admin", "slack")
    const host = await pane("connections", fixture("admin").ops, { "integration.reauth": ok({ connection: { ...slack, status: "pending" }, authorize_url: "https://example.com/authorize", opened: true }) })
    await tap(host, "m", "orbit-team")
    expect(texts(host, "m")).toContain("Signing in again keeps this connection, its sharing and its tool rules.")
    await tap(host, "m", "Sign In Again")
    const call = callsOf(host, "integration.reauth")[0]!
    expect(call.params).toEqual({ connection: "conn_slack000000000000000" })
    expect(call.options.gesture).toBe(lastGesture())
    expect(texts(host, "m")).toContain("Approve orbit-team in your browser.")
    expect(texts(host, "m")).toContain("Pending")
  })

  test("a malformed owner answer leaves the list intact", async () => {
    const host = await pane("connections", fixture("admin").ops, { "integration.reauth": ok({ connection: { nope: true }, opened: true }) })
    await tap(host, "m", "orbit-team")
    await tap(host, "m", "Sign In Again")
    expect(texts(host, "m")).toContain("orbit-team")
  })

  test("a missing re-auth op says which op is missing", async () => {
    const host = await pane("connections", fixture("admin").ops)
    await tap(host, "m", "orbit-team")
    await tap(host, "m", "Sign In Again")
    expect(texts(host, "m")).toContain("integration.reauth is not available yet.")
  })

  test("connect: the owner returns a pending connection; the app says whether the approval page opened", async () => {
    const pending = { id: "conn_new0000000000000000", owner: "team_orbit", provider: "github", status: "pending", sharing: "private", account: null, scopes_requested: [], scopes_granted: [], created_by: "usr_me", created_at: 1, updated_at: 1 }
    const host = await pane("gallery", fixture("empty").ops, { "integration.connect": ok({ connection: pending, authorize_url: "https://example.com/authorize" }) })
    await tap(host, "m", "Connect")
    const call = callsOf(host, "integration.connect")[0]!
    expect(call.params).toEqual({ provider: "github", sharing: "private" })
    expect(call.options.gesture).toBe(lastGesture())
    expect(texts(host, "m")).toContain("This cmux cannot open the GitHub approval page from an app yet.")
  })

  test("share by the creator", async () => {
    const shared = { ...record("taskboard", "openapi"), sharing: "team" }
    const host = await pane("connections", fixture("taskboard").ops, { "integration.share": ok(shared) })
    await tap(host, "m", "Taskboard API")
    await tap(host, "m", "Share with Team")
    expect(callsOf(host, "integration.share")[0]!.params).toEqual({ connection: "conn_taskboard00000000000", sharing: "team" })
    expect(texts(host, "m")).toContain("Shared with your team.")
  })
})

describe("revoke: gesture token plus the shell's confirmation sheet", () => {
  test("one tap sends integration.revoke with the tap's gesture; a cancelled sheet keeps the connection", async () => {
    const host = await pane("connections", fixture("taskboard").ops, { "integration.revoke": fail("user.cancelled", "the user cancelled the confirmation") })
    await tap(host, "m", "Taskboard API")
    await tap(host, "m", "Disconnect")
    const call = callsOf(host, "integration.revoke")[0]!
    expect(call.params).toEqual({ connection: "conn_taskboard00000000000" })
    expect(call.options.gesture).toBe(lastGesture())
    expect(texts(host, "m")).toContain("Taskboard API stays connected.")
  })

  test("a confirmed sheet: the owner's revoked record, back to the list", async () => {
    const revoked = { ...record("taskboard", "openapi"), status: "revoked" }
    const host = await pane("connections", fixture("taskboard").ops, { "integration.revoke": ok(revoked) })
    await tap(host, "m", "Taskboard API")
    await tap(host, "m", "Disconnect")
    const all = texts(host, "m")
    expect(all).toContain("Disconnected Taskboard API.")
    expect(all).not.toContain("Taskboard API")
  })

  test("a team admin may disconnect a teammate's team-shared connection; the app says it is audited", async () => {
    const host = await pane("connections", fixture("admin").ops, { "integration.revoke": fail("user.cancelled") })
    await tap(host, "m", "orbit-team")
    expect(texts(host, "m")).toContain("You disconnect it as a team admin. The audit log records it.")
    await tap(host, "m", "Disconnect")
    expect(callsOf(host, "integration.revoke")[0]!.options.gesture).toBe(lastGesture())
  })

  test("today's host refuses revoke for apps: the app says so", async () => {
    const host = await pane("connections", fixture("taskboard").ops, { "integration.revoke": fail("scope.missing") })
    await tap(host, "m", "Taskboard API")
    await tap(host, "m", "Disconnect")
    expect(texts(host, "m")).toContain("This app may not call integration.revoke.")
  })
})

describe("per-tool policy", () => {
  test("team + user rules: the most restrictive wins; a subtree rule never unblocks a destructive tool", async () => {
    const host = await pane("connections", fixture("taskboard").ops)
    await tap(host, "m", "Taskboard API")
    const all = texts(host, "m")
    expect(all).toContain("8 tools · 5 allowed · 2 ask · 1 blocked")
    expect(all).toContain("Default: destructive; only a rule for this tool unblocks it")
    expect(all.filter((s) => s === "Set by your team")).toHaveLength(2) // createTask and listTasks: the user's allow on listTasks loses
    expect(all.filter((s) => s === "Your rule").length).toBeGreaterThanOrEqual(3)
  })

  test("a toggle sends the exact tool address; the owner's rules replace the local edit", async () => {
    const fixtureRules = (fixture("taskboard").ops["integration.tools.list"] as { rules: object[] }).rules
    const host = await pane("connections", fixture("taskboard").ops, {
      "integration.tools.policy.set": (p: Record<string, unknown>) => ({ ok: true, body: { value: { rules: [...fixtureRules, { id: "pol_new", owner: "user", pattern: p.pattern, action: p.action }] } } })
    })
    await tap(host, "m", "Taskboard API")
    await tap(host, "m", "Block") // the first row: Health
    const call = callsOf(host, "integration.tools.policy.set")[0]!
    expect(call.params).toEqual({ connection: "conn_taskboard00000000000", owner: "user", pattern: "taskboard_api.health.getHealth", action: "block" })
    expect(call.options.gesture).toBe(lastGesture())
    expect(texts(host, "m").find((s) => s.startsWith("8 tools"))).toBe("8 tools · 4 allowed · 2 ask · 2 blocked")
  })

  test("without the policy op the edit lasts for the session and says so", async () => {
    const host = await pane("connections", fixture("taskboard").ops)
    await tap(host, "m", "Taskboard API")
    await tap(host, "m", "Block")
    expect(texts(host, "m")).toContain("integration.tools.policy.set is not available yet; this change lasts until cmux restarts.")
    expect(texts(host, "m").find((s) => s.startsWith("8 tools"))).toBe("8 tools · 4 allowed · 2 ask · 2 blocked")
  })

  test("tapping the selected action of your own rule clears it back to the default", async () => {
    const host = await pane("connections", fixture("taskboard").ops)
    await tap(host, "m", "Taskboard API")
    await tap(host, "m", "Block")
    await tap(host, "m", "Block") // Health's Block is selected and is your rule: clear it
    expect(texts(host, "m").find((s) => s.startsWith("8 tools"))).toBe("8 tools · 5 allowed · 2 ask · 1 blocked")
  })
})

describe("MCP exposure", () => {
  test("an opted-in connection shows each listed tool's <namespace>__<path> name; Block tools have none", async () => {
    const host = await pane("connections", fixture("taskboard").ops)
    await tap(host, "m", "Taskboard API")
    const all = texts(host, "m")
    expect(all).toContain("7 tools at /v1/mcp. Block tools are hidden; Ask waits for approval in the feed or the agent.")
    expect(all).toContain("taskboard_api__health-getHealth")
    expect(all).toContain("taskboard_api__tasks-listTasks")
    expect(all.some((s) => s.startsWith("taskboard_api__projects-deleteProject"))).toBe(false)
    for (const s of all.filter((x) => x.includes("__"))) expect(s).toMatch(/^[A-Za-z0-9_-]{1,64}$/)
  })

  test("off by default; On sends integration.mcp.set with the tap's gesture and the owner's record turns names on", async () => {
    const docs = record("docs", "mcp")
    const host = await pane("connections", fixture("docs").ops, { "integration.mcp.set": (p: Record<string, unknown>) => ({ ok: true, body: { value: { ...docs, mcp_exposed: p.exposed } } }) })
    await tap(host, "m", "Docs Server")
    expect(texts(host, "m")).toContain("Off: agents do not see these tools at /v1/mcp.")
    expect(texts(host, "m").some((s) => s.startsWith("docs_server__"))).toBe(false)
    await tap(host, "m", "On")
    const call = callsOf(host, "integration.mcp.set")[0]!
    expect(call.params).toEqual({ connection: "conn_docs0000000000000000", exposed: true })
    expect(call.options.gesture).toBe(lastGesture())
    const all = texts(host, "m")
    expect(all).toContain("docs_server__search_docs")
    expect(all).toContain("docs_server__create_page")
    expect(all).not.toContain("docs_server__create_page_2") // the user's Block rule hides it
    expect(all).not.toContain("docs_server__delete_page") // destructive: Block by default
    expect(all).toContain("2 tools at /v1/mcp. Block tools are hidden; Ask waits for approval in the feed or the agent.")
  })
})

describe("catalog changes", () => {
  test("the record's change notice links to the owner's feed item; nothing polls", async () => {
    const host = await pane("connections", fixture("docs").ops)
    await tap(host, "m", "Docs Server")
    expect(texts(host, "m")).toContain("The API changed on 2026-09-22. New tools start at their defaults; your rules stay.")
    await tap(host, "m", "Open in Feed")
    expect(callsOf(host, "ui.open")[0]!.params).toEqual({ interface: "cmux.feed/1", target: { item: "feed_catalogdocs0000001" } })
    expect(host.timers.size).toBe(0)
  })
})

describe("connection limit (50 per team, generic connections count)", () => {
  test("usage shows on the home screen and the gallery", async () => {
    const host = await pane("connections")
    expect(texts(host, "m")).toContain("9 of 50 connections")
  })

  test("at the limit the add flow refuses before calling the owner", async () => {
    const host = await pane("connections", fixture("limit").ops)
    expect(texts(host, "m")).toContain("50 of 50 connections: disconnect one to add another.")
    await tap(host, "m", "Add")
    // Connect, Add Account and the generic Add buttons are disabled.
    const buttons = (title: string) => visible(host, "m").filter(([, n]) => n.type === "Button" && n.props.title === title)
    expect(buttons("Add Account").length).toBeGreaterThan(0)
    for (const title of ["Add Account", "Connect", "Add"]) for (const [, n] of buttons(title)) expect(`${title}:${n.props.disabled}`).toBe(`${title}:true`)
    // The palette commands take the same paths and refuse without an owner call.
    await run(host, "importApi", { source: SPEC })
    for (const [, n] of buttons("Add API")) expect(n.props.disabled).toBe(true)
    await run(host, "connect", { provider: "linear" })
    expect(callsOf(host, "integration.connect")).toHaveLength(0)
    expect(texts(host, "m")).toContain("Your team has 50 connections, the most it can have. Disconnect one to add another.")
  })

  test("the owner's integration.limit gets the same message", async () => {
    const host = await pane("gallery", fixture("connections").ops, { "integration.connect": fail("integration.limit", "at most 50 connections per team") })
    await tap(host, "m", "Add Account") // GitHub already has one
    expect(texts(host, "m")).toContain("Your team has 50 connections, the most it can have. Disconnect one to add another.")
  })
})

describe("generic import", () => {
  async function importer(name = "connections", extra = {}) {
    const host = await pane("connections", fixture(name).ops, extra)
    await tap(host, "m", "Add")
    await tap(host, "m", "Add") // the OpenAPI card
    return host
  }

  test("pasted OpenAPI JSON is read on this Mac with no op call, with defaults per tool and every auth kind", async () => {
    const host = await importer()
    const before = host.calls.length
    await submit(host, "m", "Spec URL or JSON", SPEC)
    expect(host.calls.length).toBe(before)
    const all = texts(host, "m")
    expect(all).toContain("Taskboard API 2.4.0")
    expect(all).toContain("8 tools: 4 allowed (reads), 3 ask first (changes), 1 blocked (destructive)")
    for (const kind of ["Bearer token", "API key in X-Api-Key", "Sign in with OAuth", "User name and password", "Custom headers", "OAuth client credentials", "No sign-in"]) expect(all).toContain(kind)
    expect(all.filter((s) => s === "From the spec")).toHaveLength(3)
    expect(all).toContain("cmux asks for the secret in its own secure window. This app never sees it.")
    expect(all).toContain("Generic API import adapted from executor (MIT License, © 2026 Rhys Sullivan).")
  })

  test("Add sends the source, digest and chosen auth kind, never a secret; the host's sheet decides", async () => {
    const host = await importer("connections", { "integration.connect": fail("user.cancelled") })
    await submit(host, "m", "Spec URL or JSON", SPEC)
    await tap(host, "m", "API key in X-Api-Key")
    await tap(host, "m", "Add API")
    const call = callsOf(host, "integration.connect")[0]!
    expect(call.params).toMatchObject({ provider: "openapi", source: { document: SPEC }, auth: { kind: "api_key", headers: ["X-Api-Key"] }, sharing: "private" })
    expect(call.params.catalog.namespace).toBe("taskboard_api")
    expect(call.options.gesture).toBe(lastGesture())
    expect(JSON.stringify(call.params.auth)).not.toMatch(/token|secret|password/i)
    expect(texts(host, "m")).toContain("Cancelled. Nothing changed.")
  })

  test("MCP: OAuth with dynamic client registration is offered first; stdio is refused", async () => {
    const host = await importer()
    await submit(host, "m", "Spec URL or JSON", JSON.stringify({ tools: [{ name: "search_docs", annotations: { readOnlyHint: true } }] }))
    expect(texts(host, "m")).toContain("Sign in with OAuth (registers cmux with the server)")
    await submit(host, "m", "Spec URL or JSON", "npx -y docs-server")
    expect(texts(host, "m")).toContain("Local (stdio) MCP servers are not supported. Use the server's Streamable HTTP URL.")
    await submit(host, "m", "Spec URL or JSON", JSON.stringify({ mcpServers: { docs: { command: "uvx", args: ["docs-server"] } } }))
    expect(texts(host, "m")).toContain("Local (stdio) MCP servers are not supported. Use the server's Streamable HTTP URL.")
    expect(callsOf(host, "integration.catalog.preview")).toHaveLength(0)
  })

  test("a URL goes to the gateway preview; bad input says what to paste", async () => {
    const host = await importer()
    await submit(host, "m", "Spec URL or JSON", "https://specs.taskboard.example.com/openapi.json")
    expect(callsOf(host, "integration.catalog.preview")[0]!.params).toEqual({ source: { url: "https://specs.taskboard.example.com/openapi.json" } })
    expect(texts(host, "m")).toContain("integration.catalog.preview is not available yet.")
    await submit(host, "m", "Spec URL or JSON", '{"swagger":"2.0"}')
    expect(texts(host, "m")).toContain("Swagger 2.0 is not supported. Convert it to OpenAPI 3 first.")
    await submit(host, "m", "Spec URL or JSON", "petstore")
    expect(texts(host, "m")).toContain("Paste a spec URL, or the JSON of a spec, an introspection result or an MCP tool list.")
  })

  test("the importApi command previews the same way", async () => {
    const host = await pane()
    const r = await run(host, "importApi", { source: SPEC })
    expect(r.body).toMatchObject({ value: { opened: false } })
    expect(texts(host, "m")).toContain("Taskboard API 2.4.0")
    expect((await run(host, "connect", { provider: "nope" })).body).toMatchObject({ code: "invalid_params" })
    expect((await run(host, "connect", { provider: "gmail" })).body).toMatchObject({ code: "invalid_params" }) // coming, not connectable
  })
})

describe("egress pre-check (same codes as the gateway)", () => {
  async function importer(name = "connections", extra = {}) {
    const host = await pane("connections", fixture(name).ops, extra)
    await tap(host, "m", "Add")
    await tap(host, "m", "Add")
    return host
  }

  test("private, link-local, ULA and credential URLs are refused before any call", async () => {
    const host = await importer()
    await submit(host, "m", "Spec URL or JSON", "http://169.254.169.254/latest/meta-data")
    expect(texts(host, "m")).toContain("169.254.169.254 is a private, loopback or link-local address. cmux only connects to public hosts.")
    await submit(host, "m", "Spec URL or JSON", "https://[fd00::1]/openapi.json")
    expect(texts(host, "m")).toContain("fd00::1 is a private, loopback or link-local address. cmux only connects to public hosts.")
    await submit(host, "m", "Spec URL or JSON", "http://localhost:8080/openapi.json")
    expect(texts(host, "m")).toContain("localhost is a private, loopback or link-local address. cmux only connects to public hosts.")
    await submit(host, "m", "Spec URL or JSON", "https://user:pw@api.example.com/openapi.json")
    expect(texts(host, "m")).toContain("Remove the user name and password from the URL. Pick a sign-in method below instead.")
    expect(callsOf(host, "integration.catalog.preview")).toHaveLength(0)
  })

  test("the gateway's own refusals show as the owner returns them (after DNS, size, time)", async () => {
    const host = await importer("egress")
    await submit(host, "m", "Spec URL or JSON", "https://specs.internal-mirror.example.com/openapi.json")
    expect(callsOf(host, "integration.catalog.preview")).toHaveLength(1)
    expect(texts(host, "m")).toContain("specs.internal-mirror.example.com is a private, loopback or link-local address. cmux only connects to public hosts.")
    for (const [code, text] of [
      ["egress.too_large", "The document is larger than 10 MB."],
      ["egress.timeout", "The server did not answer within 30 seconds."],
      ["catalog.too_large", "This API has more tools than cmux can store (the catalog is over 2 MB)."]
    ] as const) {
      const h = await importer("connections", { "integration.catalog.preview": fail(code) })
      await submit(h, "m", "Spec URL or JSON", "https://specs.taskboard.example.com/openapi.json")
      expect(texts(h, "m")).toContain(text)
    }
  })

  test("generic_hosts: the add flow shows the allowlist and refuses other hosts; an allowed spec can be added", async () => {
    const host = await importer("managed")
    expect(texts(host, "m")).toContain("Your team allows APIs on: *.taskboard.example.com")
    await submit(host, "m", "Spec URL or JSON", "https://api.other.example.com/openapi.json")
    expect(texts(host, "m")).toContain("Your team does not allow APIs on api.other.example.com.")
    expect(callsOf(host, "integration.catalog.preview")).toHaveLength(0)
    await submit(host, "m", "Spec URL or JSON", SPEC) // servers: eu.taskboard.example.com
    expect(texts(host, "m")).not.toContain("Your team does not allow APIs on eu.taskboard.example.com.")
  })

  test("a pasted spec whose API host is private or not allowed cannot be added", async () => {
    const spec = JSON.parse(SPEC) as { servers: Array<{ url: string }> }
    spec.servers = [{ url: "http://10.0.0.5:8080/api" }]
    const host = await importer()
    await submit(host, "m", "Spec URL or JSON", JSON.stringify(spec))
    expect(texts(host, "m")).toContain("10.0.0.5 is a private, loopback or link-local address. cmux only connects to public hosts.")
    await tap(host, "m", "Add API")
    expect(callsOf(host, "integration.connect")).toHaveLength(0)
  })
})

describe("team policy", () => {
  test("a managed policy blocks providers it does not allow; Calendar and Gmail are coming", async () => {
    const host = await pane("gallery", fixture("managed").ops)
    const all = texts(host, "m")
    expect(all).toContain("Team policy managed by single sign-on")
    expect(all.filter((s) => s === "Blocked by team").length).toBe(3) // Slack, GraphQL and MCP
    expect(all.filter((s) => s === "Coming").length).toBe(2)
  })
})

describe("sidebar section", () => {
  test("attention first, then a summary", async () => {
    const host = makeHost({}, fixture("connections").ops)
    host.mount("s", "renderSection")
    await host.settle(20)
    expect(texts(host, "s")).toEqual(["orbit-team", "Needs sign-in", "4 connected", "1 waiting for approval"])
  })

  test("empty: one row to connect", async () => {
    const host = makeHost({}, fixture("empty").ops)
    host.mount("s", "renderSection")
    await host.settle(20)
    expect(texts(host, "s")).toEqual(["Connect an app", "GitHub, Linear, Slack or any API"])
  })
})

describe("localization", () => {
  const en = JSON.parse(readFileSync(join(import.meta.dir, "../strings/en.json"), "utf8")) as Record<string, string>
  const ja = JSON.parse(readFileSync(join(import.meta.dir, "../strings/ja.json"), "utf8")) as Record<string, string>
  const used = scanCalls(join(import.meta.dir, "../src"))

  test("every key in src has English and Japanese, and English matches the call site", () => {
    for (const [key, english] of used) {
      expect(en[key]).toBe(english)
      expect(ja[key]).toBeString()
    }
    expect(Object.keys(en).sort()).toEqual(Object.keys(ja).sort())
  })

  test("placeholders survive translation", () => {
    for (const [key, value] of Object.entries(en)) {
      const want = [...value.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort()
      const got = [...(ja[key] ?? "").matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort()
      expect(`${key}:${got.join(",")}`).toBe(`${key}:${want.join(",")}`)
    }
  })
})
