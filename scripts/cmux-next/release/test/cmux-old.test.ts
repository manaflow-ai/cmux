/** cmux-old.ts: request extraction from a tag's Swift, decoder shapes, the signed-in replay (fake Stack + fake origin), web revisions. */
import { afterAll, describe, expect, it } from "bun:test"
import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { ABSENT, agentCredentials, authenticatedReplay, extractRequests, generate, newestSpec, pathTemplate, readGaps, readReview, relate, replay, shapeProblems, SPEC_DIR, structShape, webRevisions, type Review, type Spec } from "../cmux-old.ts"
import { compatProblems } from "../compat.ts"
import { writeReceipt } from "../receipts.ts"
import { REPO_ROOT } from "../trees.ts"

const AUTH_FILES: Record<string, string> = {
  "Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/Coordinator/AuthConfig.swift": 'let c = CMUXAuthConfig(\n    developmentProjectId: "dev-project",\n    productionProjectId: "prod-project",\n    developmentPublishableClientKey: "pck_dev",\n    productionPublishableClientKey: "pck_prod"\n)\n',
  "Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/Client/StackAuthClient.swift": 'public init(baseURL: String = "https://api.stack-auth.com") {}\n',
  "vendor/stack-auth-swift-sdk-prerelease/Sources/StackAuth/StackClientApp.swift": 'public func signInWithCredential(email: String, password: String) async throws {\n    let (data, _) = try await client.sendRequest(\n        path: "/auth/password/sign-in",\n        method: "POST"\n    )\n}\n',
  "vendor/stack-auth-swift-sdk-prerelease/Sources/StackAuth/APIClient.swift": 'guard let url = URL(string: "\\(baseUrl)/api/v1\\(path)") else { throw E() }\n',
}

const CLIENT = `
public actor TeamsClient {
    public func detail(teamID: String) async throws -> TeamDetail {
        let team = try Self.pathSegment(teamID)
        let (data, http) = try await request("GET", path: "/api/teams/\\(team)")
        try ensureOK(http, data: data)
        return try Self.decoder.decode(TeamDetail.self, from: data)
    }

    public func accept(id: String) async throws {
        let (data, http) = try await request(
            "POST",
            path: "/api/teams/invitations/\\(try Self.pathSegment(id))/accept",
            jsonBody: ["note": "x", "count": 2]
        )
        try ensureOK(http, data: data)
    }

    public func exec(id: String, command: String) async throws {
        var body: [String: Any] = ["command": command]
        if command.isEmpty { body["timeoutMs"] = 5 }
        _ = try await request("POST", path: "/api/vm/\\(id)/exec", jsonBody: body)
    }

    private func request(_ method: String, path: String, jsonBody: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        // "/api/in-a-comment" is not a request
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \\(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let value = http.value(forHTTPHeaderField: "X-Read-Only") { _ = value }
        return try await session.data(for: req)
    }
}

public struct TeamDetail: Decodable {
    public let id: String
    public let name: String?
    public let members: [Member]
    public var computed: Int { 1 }
    public let constant = 3
    static let shared = 0
    enum CodingKeys: String, CodingKey {
        case id, name = "display_name"
        case members
    }
}

public struct Member: Decodable {
    let userId: String
    let role: Role
    let joined: Date
}

public enum Role: String, Decodable { case admin, member }
`

const OTHERS = `
final class Uploader {
    func capture(_ batch: [Event]) async -> Bool {
        await post(path: "/api/analytics/events", body: batch)
    }
    private func post(path: String, body: some Encodable) async -> Bool {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return true
    }
}

final class Registry {
    private func publish(_ registration: Registration) async -> Bool {
        comps.path = comps.path + "/api/devices"
        var req = URLRequest(url: comps.url!)
        req.httpMethod = registration.routes.isEmpty ? "PATCH" : "POST"
        return true
    }
    nonisolated private static func pushURL() -> URL? {
        components.path = components.path + "/api/notifications/push/e2e"
        return components.url
    }
    func send() async {
        guard let url = Self.pushURL() else { return }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
    }
    func label(_ path: String) -> String {
        switch path {
        case "/api/vm": return "list"
        default: return "other"
        }
    }
}

final class WhatsNew {
    static let requestPath = "/api/whats-new"
    init(base: String) { url = URL(string: base + Self.requestPath) }
}

final class Push {
    func recipients() async {
        components.path = components.path + "/api/device-tokens"
        components.queryItems = [URLQueryItem(name: "all", value: "true")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \\(token)", forHTTPHeaderField: "Authorization")
        let r = try? JSONDecoder().decode(Recipients.self, from: data)
    }
}

struct Recipients: Decodable { let recipients: [String] }

struct Envelope: Decodable {
    let items: [String]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([String].self, forKey: .items)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
        total = try? c.decode(Int.self, forKey: .total)
    }
}
`

const lineOf = (text: string, needle: string) => text.split("\n").findIndex((l) => l.includes(needle)) + 1
const OTHERS_FILE = "Packages/Cloud/Sources/Cloud/Others.swift"
const LABEL_SITE = `${OTHERS_FILE}:${lineOf(OTHERS, 'case "/api/vm"')}`
const WHATS_NEW_SITE = `${OTHERS_FILE}:${lineOf(OTHERS, "static let requestPath")}`
const REVIEW: Review = {
  skip: { [LABEL_SITE]: "telemetry label switch (no request)" },
  methods: { [WHATS_NEW_SITE]: { methods: ["GET"], reason: "the URL is loaded with session.data(from:)" } },
  responses: { "GET /api/whats-new": { shape: { visibleEntryIds: ["string"] }, source: WHATS_NEW_SITE } },
  fill: { team: "team" },
}

const fixtureRepo = () => {
  const repo = mkdtempSync(join(tmpdir(), "cmuxold-repo-"))
  const git = (...a: Array<string>) => execFileSync("git", ["-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", ...a], { encoding: "utf8" })
  git("init", "-q")
  const files: Record<string, string> = { ...AUTH_FILES, "Packages/Cloud/Sources/Cloud/Client.swift": CLIENT, "Packages/Cloud/Sources/Cloud/Others.swift": OTHERS, "Packages/Cloud/Tests/CloudTests/T.swift": 'let t = "/api/test-only"\n', "Packages/Cloud/README.md": '"/api/docs-only"\n' }
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(dirname(join(repo, path)), { recursive: true })
    writeFileSync(join(repo, path), text)
  }
  git("add", ".")
  git("commit", "-qm", "r")
  git("tag", "v1.0.0")
  return repo
}

describe("request extraction from a release tag", () => {
  const repo = fixtureRepo()
  it("finds each request's real method: call argument, helper, function, ternary, URL helper, review", () => {
    const { requests, skipped } = extractRequests(repo, "v1.0.0", REVIEW)
    expect(requests.map((r) => `${r.method} ${r.path}`)).toEqual([
      "POST /api/analytics/events",
      "GET /api/device-tokens",
      "PATCH /api/devices",
      "POST /api/devices",
      "POST /api/notifications/push/e2e",
      "GET /api/teams/{team}",
      "POST /api/teams/invitations/{id}/accept",
      "POST /api/vm/{id}/exec",
      "GET /api/whats-new",
    ])
    expect(skipped).toEqual([{ source: LABEL_SITE, reason: "telemetry label switch (no request)" }])
  })
  it("records the header names the client sets (not the ones it reads) and the JSON body keys", () => {
    const { requests } = extractRequests(repo, "v1.0.0", REVIEW)
    const byKey = Object.fromEntries(requests.map((r) => [`${r.method} ${r.path}`, r]))
    expect([...byKey["GET /api/teams/{team}"]!.headers].sort()).toEqual(["Authorization", "X-Stack-Refresh-Token"])
    expect([...byKey["POST /api/analytics/events"]!.headers]).toEqual(["Content-Type"])
    expect(byKey["POST /api/teams/invitations/{id}/accept"]!.body).toEqual({ keys: ["note", "count"] })
    expect(byKey["POST /api/vm/{id}/exec"]!.body).toEqual({ keys: ["command", "timeoutMs?"] })
    expect(byKey["GET /api/device-tokens"]!.query).toBe("all=true")
  })
  it("refuses an unresolved literal and a stale review entry", () => {
    let message = ""
    try {
      extractRequests(repo, "v1.0.0", {})
    } catch (e) {
      message = (e as Error).message
    }
    expect(message).toContain(`unresolved "/api/" literal (add a skip or methods entry to the review file): ${LABEL_SITE}`)
    expect(message).toContain(WHATS_NEW_SITE)
    expect(message).not.toContain("in-a-comment")
    expect(() => extractRequests(repo, "v1.0.0", { ...REVIEW, skip: { ...REVIEW.skip, [`${OTHERS_FILE}:999`]: "gone" } })).toThrow(/review entry skip .*:999 matches no/)
  })
  it("path templates name parameters and drop the query", () => {
    expect(pathTemplate("/api/teams/\\(team)/members/\\(try Self.pathSegment(user.id))?expand=1")).toEqual({ path: "/api/teams/{team}/members/{id}", params: ["team", "id"] })
  })
  it("derives a read's response shape from its Decodable struct: CodingKeys, optionals, nested types, raw enums", () => {
    const spec = generate(repo, "v1.0.0", REVIEW)
    const team = spec.requests.find((r) => r.method === "GET" && r.path === "/api/teams/{team}")!
    expect(team.mode).toBe("read")
    expect(team.fill).toEqual({ team: "team" })
    expect(team.response).toEqual({ id: "string", "display_name?": "string", members: [{ userId: "string", role: "string", joined: "string" }] })
    expect(team.responseFrom).toContain("Decodable TeamDetail")
    expect(spec.requests.find((r) => r.path === "/api/whats-new")!.response).toEqual({ visibleEntryIds: ["string"] })
    expect(spec.requests.filter((r) => r.mode === "shape-only").map((r) => `${r.method} ${r.path}`)).toContain("POST /api/vm/{id}/exec")
    expect(spec.auth).toEqual({ api: "https://api.stack-auth.com", signInPath: "/api/v1/auth/password/sign-in", projectId: "dev-project", publishableClientKey: "pck_dev", sources: expect.any(Array) })
  })
  it("reads a custom init(from:) for decode and decodeIfPresent keys", () => {
    const file = readFileSync(join(repo, "Packages/Cloud/Sources/Cloud/Others.swift"), "utf8")
    expect(structShape("Envelope", { file, others: () => [] })).toEqual({ items: ["string"], "cursor?": "string", "total?": "integer" })
  })
  it("is deterministic and fails when a read has no shape or a parameter has no fill", () => {
    expect(JSON.stringify(generate(repo, "v1.0.0", REVIEW))).toBe(JSON.stringify(generate(repo, "v1.0.0", REVIEW)))
    expect(() => generate(repo, "v1.0.0", { ...REVIEW, responses: {} })).toThrow(/GET \/api\/whats-new: no Decodable type/)
    expect(() => generate(repo, "v1.0.0", { ...REVIEW, fill: {} })).toThrow(/no fill source for path parameter \{team\}/)
  })
})

describe("response shapes", () => {
  it("needs required keys and types, accepts absent or null optionals and either alternative name", () => {
    const shape = { id: "string", "name?": "string", "vmId|vm_id": "string", items: [{ n: "integer" }], meta: "object", any: "any" }
    expect(shapeProblems(shape, { id: "a", name: null, vm_id: "v", items: [{ n: 1 }], meta: {}, any: 0 })).toEqual([])
    expect(shapeProblems(shape, { id: 1, items: [{ n: 1.5 }], meta: [], any: null })).toEqual([
      "$.id: expected string, got number",
      "$.vmId|vm_id: missing (the decoder requires it)",
      "$.items[0].n: expected integer, got number",
      "$.meta: expected object, got array",
      "$.any: missing (the decoder requires it)",
    ])
  })
})

describe("agent credentials", () => {
  const dotenv = "CMUX_DOGFOOD_STACK_EMAIL=me@example.com\nCMUX_DOGFOOD_STACK_PASSWORD=personal-secret\nexport CMUX_UITEST_STACK_EMAIL=\"agent@example.com\"\nCMUX_UITEST_STACK_PASSWORD=agent-secret\n"
  it("takes only the agent profile, environment first", () => {
    expect(agentCredentials({}, dotenv)).toEqual({ email: "agent@example.com", password: "agent-secret" })
    expect(agentCredentials({ CMUX_UITEST_STACK_EMAIL: "env@example.com", CMUX_UITEST_STACK_PASSWORD: "p" }, dotenv)).toEqual({ email: "env@example.com", password: "p" })
  })
  it("refuses the personal profile and never puts a value in an error", () => {
    const bad = "CMUX_DOGFOOD_STACK_EMAIL=me@example.com\nCMUX_UITEST_STACK_EMAIL=me@example.com\nCMUX_UITEST_STACK_PASSWORD=pw-value\n"
    expect(() => agentCredentials({}, bad)).toThrow(/personal profile/)
    try {
      agentCredentials({}, bad)
    } catch (e) {
      expect(String(e)).not.toContain("me@example.com")
      expect(String(e)).not.toContain("pw-value")
    }
    expect(() => agentCredentials({}, "CMUX_DOGFOOD_STACK_EMAIL=a\nCMUX_DOGFOOD_STACK_PASSWORD=b\n")).toThrow(/CMUX_UITEST_STACK_EMAIL and CMUX_UITEST_STACK_PASSWORD/)
  })
})

describe("signed-in replay against a fake Stack and a fake origin", () => {
  const seen: Array<{ method: string; path: string; auth: string | null; refresh: string | null; team: string | null }> = []
  const state = { project: "dev-project", dropMembers: false, signedOut: 0, vmRoute: true }
  const server = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url)
      const path = url.pathname
      seen.push({ method: req.method, path, auth: req.headers.get("authorization"), refresh: req.headers.get("x-stack-refresh-token"), team: req.headers.get("x-cmux-team-id") })
      // Stack
      if (path === "/api/v1/auth/password/sign-in") {
        const body = (await req.json()) as { email: string; password: string }
        const ok = req.headers.get("x-stack-project-id") === "dev-project" && req.headers.get("x-stack-publishable-client-key") === "pck_dev" && req.headers.get("x-stack-access-type") === "client" && body.email === "agent@example.com" && body.password === "agent-secret"
        return ok ? Response.json({ access_token: "acc-1", refresh_token: "ref-1", user_id: "u1" }) : Response.json({ code: "EMAIL_PASSWORD_MISMATCH" }, { status: 400 })
      }
      if (path === "/api/v1/users/me") return req.headers.get("x-stack-access-token") === "acc-1" ? Response.json({ id: "u1", selected_team_id: "team-1" }) : new Response("no", { status: 401 })
      if (path === "/api/v1/auth/sessions/current" && req.method === "DELETE") {
        state.signedOut++
        return Response.json({ success: true })
      }
      // origin
      if (path === "/handler/sign-in") return new Response(`<html>${state.project}</html>`, { headers: { "content-type": "text/html" } })
      const signedIn = req.headers.get("authorization") === "Bearer acc-1" && req.headers.get("x-stack-refresh-token") === "ref-1"
      if (path === "/api/whats-new") return Response.json({ visibleEntryIds: [] })
      if (path === "/api/device-tokens") return !signedIn ? Response.json({ error: "unauthorized" }, { status: 401 }) : url.searchParams.get("all") === "true" ? Response.json({ recipients: [] }) : Response.json({ error: "invalid_bundle_id" }, { status: 400 })
      if (path === "/api/vm" && req.method === "GET") return state.vmRoute ? (signedIn ? Response.json({ vms: [] }) : Response.json({ error: "unauthorized" }, { status: 401 })) : new Response("<html>404</html>", { status: 404, headers: { "content-type": "text/html" } })
      if (path.startsWith("/api/teams/")) {
        if (!signedIn) return Response.json({ error: "unauthorized" }, { status: 401 })
        if (path === "/api/teams/team-1" && req.headers.get("x-cmux-team-id") === "team-1") return Response.json(state.dropMembers ? { id: "team-1" } : { id: "team-1", members: [] })
        return Response.json({ error: "team_not_found" }, { status: 404 })
      }
      if (path.startsWith("/api/vm/") && req.method === "GET") return signedIn ? Response.json({ error: "not_found" }, { status: 404 }) : Response.json({ error: "unauthorized" }, { status: 401 })
      if (path === "/api/vm/tunnel" && req.method === "POST") return Response.json({ error: "unauthorized" }, { status: 401 })
      return new Response("<html>404</html>", { status: 404, headers: { "content-type": "text/html" } })
    },
  })
  afterAll(() => server.stop(true))
  const origin = `http://127.0.0.1:${server.port}`
  const spec: Spec = {
    schema: 2,
    tag: "v1.0.0",
    sha: "abc",
    generated_from: "test",
    auth: { api: origin, signInPath: "/api/v1/auth/password/sign-in", projectId: "dev-project", publishableClientKey: "pck_dev", sources: [] },
    skipped: [],
    requests: [
      { method: "GET", path: "/api/vm", params: [], headers: ["Authorization"], sources: [], via: "t", mode: "read", response: { vms: [{ id: "string" }] } },
      { method: "GET", path: "/api/teams/{team}", params: ["team"], headers: ["Authorization"], sources: [], via: "t", mode: "read", response: { id: "string", members: ["object"] }, fill: { team: "team" } },
      { method: "GET", path: "/api/vm/{encodedID}/stats", params: ["encodedID"], headers: ["Authorization"], sources: [], via: "t", mode: "read", response: "object", fill: { encodedID: "vm" } },
      { method: "GET", path: "/api/whats-new", params: [], headers: [], sources: [], via: "t", mode: "read", anonymous: true, response: { visibleEntryIds: ["string"] } },
      { method: "POST", path: "/api/vm/tunnel", params: [], headers: ["Authorization"], sources: [], via: "t", mode: "shape-only", reason: "changes state" },
      { method: "GET", path: "/api/device-tokens", query: "all=true", params: [], headers: ["Authorization"], sources: [], via: "t", mode: "read", response: { recipients: ["object"] } },
    ],
  }
  const creds = { email: "agent@example.com", password: "agent-secret" }

  it("signs in like the tag, sends the client's headers, checks shapes, never sends credentials to a shape-only request, and signs out", async () => {
    seen.length = 0
    const r = await authenticatedReplay(spec, origin, creds)
    expect(r.failures).toEqual([])
    expect(r.authenticated).toBe(true)
    expect(r.counts).toMatchObject({ "read-2xx": 3, "read-absent-id": 1, "public-read": 1, "shape-only": 1, fail: 0 })
    expect(r.shapeOnly).toEqual(["POST /api/vm/tunnel"])
    expect(r.warnings.join()).toContain("no machine")
    const team = seen.find((s) => s.path === "/api/teams/team-1")!
    expect(team).toMatchObject({ auth: "Bearer acc-1", refresh: "ref-1", team: "team-1" })
    expect(seen.find((s) => s.path === `/api/vm/${ABSENT}/stats`)?.auth).toBe("Bearer acc-1")
    expect(seen.filter((s) => s.path === "/api/vm/tunnel").map((s) => s.auth)).toEqual([null])
    expect(seen.find((s) => s.path === "/api/whats-new")?.auth).toBeNull()
    expect(state.signedOut).toBe(1)
  })
  it("fails a signed-in read whose JSON lacks a key the decoder needs, and a route that became a page 404", async () => {
    Object.assign(state, { dropMembers: true, vmRoute: false })
    const r = await authenticatedReplay(spec, origin, creds)
    Object.assign(state, { dropMembers: false, vmRoute: true })
    expect(r.failures.join("\n")).toContain("GET /api/teams/{team}: response shape: $.members: missing")
    expect(r.failures.join("\n")).toContain("GET /api/vm: answered 404 signed in; v1.0.0 needs 2xx [<html>404</html>]")
  })
  it("refuses to sign in when the origin serves another Stack project, and when the password is wrong", async () => {
    state.project = "prod-project"
    const r = await authenticatedReplay(spec, origin, creds)
    state.project = "dev-project"
    expect(r.ok).toBe(false)
    expect(r.authenticated).toBe(false)
    expect(r.failures.join()).toContain("does not serve the Stack project dev-project")
    await expect(authenticatedReplay(spec, origin, { ...creds, password: "wrong" })).rejects.toThrow(/sign-in for the agent profile answered 400 EMAIL_PASSWORD_MISMATCH/)
  })
  it("without credentials it probes routes only and says so", async () => {
    const r = await replay(spec, origin)
    expect(r.authenticated).toBe(false)
    expect(r.failures).toEqual([])
    expect(r.counts).toMatchObject({ "unauthenticated-read": 4, "public-read": 1, "shape-only": 1 })
  })
})

describe("staging and production web revisions", () => {
  const graph: Record<string, Array<string>> = { new: ["old"], old: [], side: ["old"] }
  const isAncestor = (a: string, b: string): boolean | undefined => (b in graph ? b === a || graph[b]!.some((p) => isAncestor(a, p)) : undefined)
  it("names staging same, newer, older, diverged or unknown", () => {
    expect(relate("old", "old", isAncestor)).toBe("same")
    expect(relate("new", "old", isAncestor)).toBe("newer")
    expect(relate("old", "new", isAncestor)).toBe("older")
    expect(relate("new", "side", isAncestor)).toBe("diverged")
    expect(relate(undefined, "old", isAncestor)).toBe("unknown")
    expect(relate("x", "old", isAncestor)).toBe("unknown")
  })
  it("reads both hosts and records an unreadable one", () => {
    const r = webRevisions("/nonexistent", (host) => (host === "cmux.com" ? { host, sha: "old" } : { host, error: "vercel api exited 1" }), isAncestor)
    expect(r.relation).toBe("unknown")
    expect(r.staging.error).toBe("vercel api exited 1")
    expect(webRevisions("/nonexistent", (host) => ({ host, sha: host === "cmux.com" ? "old" : "new" }), isAncestor).relation).toBe("newer")
  })
})

describe("the committed spec", () => {
  const spec = newestSpec()!
  it("is v0.65.0, schema 2, regenerated byte for byte from the tag and its review file", () => {
    expect(spec.tag).toBe("v0.65.0")
    expect(spec.schema).toBe(2)
    // origin's v0.65.0 (the GitHub release, build 108); an earlier local copy of the tag named 499779c6c2c0.
    expect(spec.sha).toBe("dda24fbd2250dfacf41bf5e8e3d20d488acf6182")
    const fresh = generate(REPO_ROOT, "v0.65.0", readReview("v0.65.0"))
    expect(`${JSON.stringify(fresh, null, 2)}\n`).toBe(readFileSync(join(SPEC_DIR, "v0.65.0.json"), "utf8"))
  })
  it("records the shipped POST routes as POST (no 405 GETs), and every read has a response shape", () => {
    const keys = new Set(spec.requests.map((r) => `${r.method} ${r.path}`))
    for (const k of ["POST /api/vm/{encodedID}/exec", "POST /api/teams/invitations/{invitation}/accept", "POST /api/feedback", "POST /api/analytics/events", "POST /api/vm/{id}/pause", "PUT /api/vm/{encodedID}/network"]) expect(keys).toContain(k)
    expect(spec.requests.find((r) => r.method === "GET" && r.path === "/api/device-tokens")!.query).toBe("all=true")
    for (const k of ["GET /api/vm/{encodedID}/exec", "GET /api/feedback", "GET /api/analytics/events", "GET /api/vm/base/open"]) expect(keys).not.toContain(k)
    for (const r of spec.requests) {
      if (r.mode === "read") expect(r.response).toBeDefined()
      else expect(r.reason?.length ?? 0).toBeGreaterThan(10)
    }
    expect(spec.auth.projectId).toBe("454ecd03-1db2-4050-845e-4ce5b0cd9895")
    for (const g of readGaps()) expect(g.reason.length).toBeGreaterThan(10)
  })
  it("production refuses a smoke of an older release, an unauthenticated smoke, and one taken while staging was behind", () => {
    const dir = mkdtempSync(join(tmpdir(), "cmuxold-receipts-"))
    const now = Date.parse("2026-10-09T12:00:00Z")
    const at = new Date(now - 3600_000).toISOString()
    const revisions = { staging: { host: "s", sha: "a" }, production: { host: "p", sha: "a" }, relation: "same", source: "t" }
    writeReceipt(dir, { action: "compat-static", tree: "compat", target: "production", result: "pass", at, setHash: "k", release: "v0.65.0", by: "t" })
    writeReceipt(dir, { action: "compat-smoke", tree: "compat", target: "production", result: "pass", at, setHash: "k", release: "v0.65.0", authenticated: true, revisions, by: "t" })
    expect(compatProblems(dir, "k", "production", now, "v0.65.0")).toEqual([])
    expect(compatProblems(dir, "k", "production", now, "v0.66.0").join()).toContain("latest stable release is v0.66.0")
    writeReceipt(dir, { action: "compat-smoke", tree: "compat", target: "production", result: "pass", at, setHash: "k2", release: "v0.65.0", authenticated: false, revisions, by: "t" })
    writeReceipt(dir, { action: "compat-static", tree: "compat", target: "production", result: "pass", at, setHash: "k2", release: "v0.65.0", by: "t" })
    expect(compatProblems(dir, "k2", "production", now, "v0.65.0").join()).toContain("not signed in")
    writeReceipt(dir, { action: "compat-smoke", tree: "compat", target: "production", result: "pass", at, setHash: "k3", release: "v0.65.0", authenticated: true, revisions: { ...revisions, relation: "older" }, by: "t" })
    writeReceipt(dir, { action: "compat-static", tree: "compat", target: "production", result: "pass", at, setHash: "k3", release: "v0.65.0", by: "t" })
    expect(compatProblems(dir, "k3", "production", now, "v0.65.0").join()).toContain("older relative to production")
  })
})
