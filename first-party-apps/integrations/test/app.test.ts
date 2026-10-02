import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { fixture, lastGesture, makeHost, run, submit, tap, texts } from "./harness.ts"
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
    expect(all).toContain("Not set up yet") // Gmail is not configured on this server
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

  test("a change event re-reads the list; nothing polls", async () => {
    const host = await pane("connections")
    host.emit("integration.changed", {})
    await host.settle(20)
    expect(callsOf(host, "integration.list")).toHaveLength(2)
    expect(host.timers.size).toBe(0)
  })

  test("cycleVariant walks the three designs", async () => {
    const host = await pane("connections")
    expect((await run(host, "cycleVariant")).body).toMatchObject({ value: { variant: "gallery" } })
    expect((await run(host, "cycleVariant")).body).toMatchObject({ value: { variant: "catalog" } })
    expect((await run(host, "cycleVariant")).body).toMatchObject({ value: { variant: "connections" } })
  })
})

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

  test("needs re-auth: Sign In Again runs integration.reauth with the tap's gesture; built-in tools without tools.list", async () => {
    const slack = (fixture("reauth").ops["integration.list"] as { connections: Array<{ provider: string }> }).connections.find((c) => c.provider === "slack")!
    const host = await pane("connections", fixture("reauth").ops, { "integration.reauth": ok({ connection: { ...slack, status: "pending" }, opened: true }) })
    await tap(host, "m", "orbit-team")
    expect(texts(host, "m")).toContain("Built-in list")
    expect(texts(host, "m")).toContain("slack.post_as_bot")
    expect(texts(host, "m")).not.toContain("Disconnect") // created by a teammate: only the creator disconnects
    await tap(host, "m", "Sign In Again")
    const call = callsOf(host, "integration.reauth")[0]!
    expect(call.params).toEqual({ connection: "conn_slack000000000000000" })
    expect(call.options.gesture).toBe(lastGesture())
    expect(texts(host, "m")).toContain("Approve Slack in your browser.")
    expect(texts(host, "m")).toContain("Pending")
  })

  test("a malformed owner answer leaves the list intact", async () => {
    const host = await pane("connections", fixture("reauth").ops, { "integration.reauth": ok({ connection: { nope: true }, opened: true }) })
    await tap(host, "m", "orbit-team")
    await tap(host, "m", "Sign In Again")
    expect(texts(host, "m")).toContain("orbit-team")
  })

  test("a missing re-auth op says which op is missing", async () => {
    const host = await pane("connections", fixture("reauth").ops)
    await tap(host, "m", "orbit-team")
    await tap(host, "m", "Sign In Again")
    expect(texts(host, "m")).toContain("integration.reauth is not available yet.")
  })

  test("connect: the owner returns a pending connection; the app says whether the approval page opened", async () => {
    const pending = { ...fixture("connections").ops["integration.list"] as object, id: "conn_new0000000000000000", provider: "github", status: "pending", sharing: "private", account: null, scopes_granted: [], created_by: "usr_me" }
    const host = await pane("gallery", fixture("empty").ops, { "integration.connect": ok({ connection: pending, authorize_url: "https://example.com/authorize" }) })
    await tap(host, "m", "Connect")
    const call = callsOf(host, "integration.connect")[0]!
    expect(call.params).toEqual({ provider: "github", sharing: "private" })
    expect(call.options.gesture).toBe(lastGesture())
    expect(texts(host, "m")).toContain("This cmux cannot open the GitHub approval page from an app yet.")
  })

  test("share and disconnect: owner ops, disconnect needs a second tap", async () => {
    const shared = { ...(fixture("taskboard").ops["integration.list"] as { connections: object[] }).connections[4]!, sharing: "team" }
    const host = await pane("connections", fixture("taskboard").ops, { "integration.share": ok(shared), "integration.revoke": fail("auth.forbidden") })
    await tap(host, "m", "Taskboard API")
    await tap(host, "m", "Share with Team")
    expect(callsOf(host, "integration.share")[0]!.params).toEqual({ connection: "conn_taskboard00000000000", sharing: "team" })
    expect(texts(host, "m")).toContain("Shared with your team.")
    await tap(host, "m", "Disconnect")
    expect(callsOf(host, "integration.revoke")).toHaveLength(0)
    await tap(host, "m", "Disconnect?")
    expect(callsOf(host, "integration.revoke")[0]!.params).toEqual({ connection: "conn_taskboard00000000000" })
    expect(texts(host, "m")).toContain("Only the person who connected it can do this.")
  })
})

describe("per-tool policy", () => {
  test("a team rule wins over a looser user rule; destructive stays blocked by default", async () => {
    const host = await pane("connections", fixture("taskboard").ops)
    await tap(host, "m", "Taskboard API")
    const all = texts(host, "m")
    expect(all).toContain("8 tools · 4 allowed · 3 ask · 1 blocked")
    expect(all).toContain("Default: destructive")
    expect(all.filter((s) => s === "Set by your team")).toHaveLength(2) // createTask and listTasks
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
    expect(texts(host, "m").find((s) => s.startsWith("8 tools"))).toBe("8 tools · 3 allowed · 3 ask · 2 blocked")
    expect(texts(host, "m")).not.toContain("integration.tools.policy.set is not available yet; this change lasts until cmux restarts.")
  })

  test("without the policy op the edit lasts for the session and says so", async () => {
    const host = await pane("connections", fixture("taskboard").ops)
    await tap(host, "m", "Taskboard API")
    await tap(host, "m", "Block")
    expect(texts(host, "m")).toContain("integration.tools.policy.set is not available yet; this change lasts until cmux restarts.")
    expect(texts(host, "m").find((s) => s.startsWith("8 tools"))).toBe("8 tools · 3 allowed · 3 ask · 2 blocked")
  })

  test("tapping the selected action of your own rule clears it back to the default", async () => {
    const host = await pane("connections", fixture("taskboard").ops)
    await tap(host, "m", "Taskboard API")
    await tap(host, "m", "Block")
    await tap(host, "m", "Block") // Health's Block is selected and is your rule: clear it
    expect(texts(host, "m").find((s) => s.startsWith("8 tools"))).toBe("8 tools · 4 allowed · 3 ask · 1 blocked")
  })
})

describe("generic import", () => {
  async function importer(extra = {}) {
    const host = await pane("connections", fixture("connections").ops, extra)
    await tap(host, "m", "Add")
    await tap(host, "m", "Add") // the OpenAPI card
    return host
  }

  test("pasted OpenAPI JSON is read on this Mac with no op call, with defaults per tool", async () => {
    const host = await importer()
    const before = host.calls.length
    await submit(host, "m", "Spec URL or JSON", SPEC)
    expect(host.calls.length).toBe(before)
    const all = texts(host, "m")
    expect(all).toContain("Taskboard API 2.4.0")
    expect(all).toContain("8 tools: 4 allowed (reads), 3 ask first (changes), 1 blocked (destructive)")
    expect(all).toContain("Bearer token")
    expect(all).toContain("API key in X-Api-Key")
    expect(all).toContain("Sign in with OAuth")
    expect(all).toContain("Generic API import adapted from executor (MIT License, © 2026 Rhys Sullivan).")
  })

  test("Add sends the source, digest and chosen auth method, never a secret", async () => {
    const host = await importer({ "integration.connect": fail("validation.invalid", "provider: expected github, linear or slack") })
    await submit(host, "m", "Spec URL or JSON", SPEC)
    await tap(host, "m", "API key in X-Api-Key")
    await tap(host, "m", "Add API")
    const call = callsOf(host, "integration.connect")[0]!
    expect(call.params).toMatchObject({ provider: "openapi", source: { document: SPEC }, auth: { kind: "api_key", headers: ["X-Api-Key"] }, sharing: "private" })
    expect(call.params.catalog.namespace).toBe("taskboard_api")
    expect(JSON.stringify(call.params.auth)).not.toMatch(/token|secret|password/i)
    expect(texts(host, "m")).toContain("This server cannot connect OpenAPI APIs yet.")
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
  })
})

describe("team policy", () => {
  test("a managed policy blocks providers it does not allow and says who manages it", async () => {
    const host = await pane("gallery", fixture("managed").ops)
    const all = texts(host, "m")
    expect(all).toContain("Team policy managed by single sign-on")
    expect(all.filter((s) => s === "Blocked by team").length).toBe(6) // Slack, Calendar, Gmail and the three generic kinds
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
