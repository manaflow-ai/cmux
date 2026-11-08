import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { select, main } from "./cloud-selftest";
import { ACTIONS, resolve, turnErrorCode, type ActionDef, type RunCtx } from "./cloud-selftest/actions";
import { Actor, apiResult, cliErrorCode, cliJson, helpNamesVerb } from "./cloud-selftest/actors";
import { interpolate, judge, mismatch, scenarioOutcome, writeReport, type Scenario } from "./cloud-selftest/engine";
import { startLocalStub } from "./cloud-selftest/faults";
import { cmuxTeamId, cmuxUserId, selftestEmail, stackFixtures, workerFixtures, type Fixtures, type FixtureTeam, type FixtureUser } from "./cloud-selftest/fixtures";
import { actorRoles, lintScenarios, pendingLanes, runScenario, type Abilities } from "./cloud-selftest/runner";
import { SCENARIOS } from "./cloud-selftest/scenarios";
import { STACK } from "./cloud-journey";

const tmp = mkdtempSync(path.join(tmpdir(), "selftest-test-"));
afterAll(() => rmSync(tmp, { recursive: true, force: true }));

describe("catalogue", () => {
  test("every scenario lints clean: known actions, declared actors, one role per actor name, an owner for every team", () => {
    expect(lintScenarios(SCENARIOS)).toEqual([]);
    const roles = actorRoles(SCENARIOS);
    expect(roles.get("owner")).toBe("owner");
    expect(roles.get("outsider")).toBeNull();
  });

  test("a scenario that gives one actor two roles, or members without an owner, is refused", () => {
    const bad: Scenario[] = [
      { name: "a", summary: "", covers: ["x"], tags: [], actors: [{ name: "member", team_role: "member" }, { name: "owner", team_role: "owner" }], steps: [] },
      { name: "b", summary: "", covers: ["x"], tags: [], actors: [{ name: "member", team_role: "admin" }], steps: [{ actor: "ghost", action: "nope" }] },
    ];
    const problems = lintScenarios(bad);
    expect(problems).toContain("b step 0: no action nope");
    expect(problems).toContain("b step 0: actor ghost is not declared");
    expect(problems).toContain("b: has team members but no owner");
    expect(problems.some((p) => p.includes("actor member is member in one scenario and admin in b"))).toBe(true);
  });

  test("the catalogue covers the UPDATE 1 edge cases and the multiplayer surface", () => {
    const covered = new Set(SCENARIOS.flatMap((s) => s.covers));
    for (const want of [
      "owner offline / Mac asleep", "VM asleep or waking", "VM restarted mid-turn", "two people prompting at once",
      "member removed mid-session (access revoked live)", "guest vs member vs admin vs non-member", "expired/revoked tokens",
      "gateway offline", "gateway reconnecting", "two gateways for one owner", "provider rate-limit and auth errors surfaced with clear copy",
      "reassigning while a turn runs", "following then losing access", "transfer while a turn is running", "large transcripts",
      "network drop and resume without losing or duplicating messages", "idempotent retries", "login-free VM (no credential files on the VM)",
      "Cloud chat share", "teammate attach + steer", "team list", "links", "team shared key path",
    ]) expect(covered.has(want)).toBe(true);
  });

  test("lanes: shared chats wait on C, follow and reassign on D, team keys on E; the team list runs today on its route", () => {
    const lanes = (n: string) => pendingLanes(SCENARIOS.find((s) => s.name === n)!);
    expect(lanes("share.cloud_chat_guest")).toEqual(["C"]);
    expect(lanes("chat.reassign_transfer_mid_turn")).toEqual(["C", "D"]);
    expect(lanes("team_keys.shared_path")).toEqual(["E"]);
    expect(lanes("team.list")).toEqual([]);
    expect(lanes("vm.login_free")).toEqual(["A"]);
  });

  test("select by names or tag; an unknown name is refused", () => {
    expect(select(SCENARIOS, "team.list,auth.expired_revoked").map((s) => s.name)).toEqual(["team.list", "auth.expired_revoked"]);
    expect(select(SCENARIOS, undefined, "fast").every((s) => s.tags.includes("fast"))).toBe(true);
    expect(() => select(SCENARIOS, "no.such")).toThrow("no scenario no.such");
  });
});

describe("matching", () => {
  test("subset objects, lists, and the operators", () => {
    const v = { teams: [{ id: "t1", role: "member", extra: 1 }], n: 3, s: "cmux://cloud/session/a/b/c", empty: [] };
    expect(mismatch(v, { teams: { $contains: { id: "t1", role: "member" } } })).toBeNull();
    expect(mismatch(v, { teams: { $contains: { id: "t2" } } })).toContain("no item matches");
    expect(mismatch(v, { teams: { $not: { $contains: { id: "t2" } } } })).toBeNull();
    expect(mismatch(v, { n: { $gte: 3 }, s: { $re: "^cmux://cloud/session/" }, empty: [], missing: { $absent: true } })).toBeNull();
    expect(mismatch(v, { teams: { $len: 2 } })).toContain("expected 2 items");
    expect(mismatch(v, { n: { $oneOf: [1, 2] } })).toContain("none of");
    expect(mismatch(v, { teams: [{ id: "t1" }] })).toBeNull();
    expect(mismatch(v, { n: 4 })).toBe("$.n: expected 4, got 3");
  });

  test("judge: ok, a given error code, a list of codes, and an unexpected success", () => {
    expect(judge({ ok: true, json: {}, transport: "api" })).toBeNull();
    expect(judge({ ok: false, code: "team.not_member", json: {}, transport: "api" }, { error: "team.not_member" })).toBeNull();
    expect(judge({ ok: false, code: "auth.forbidden", json: {}, transport: "api" }, { error: ["team.not_member", "auth.forbidden"] })).toBeNull();
    expect(judge({ ok: true, json: {}, transport: "api" }, { error: "auth.unauthenticated" })).toContain("succeeded, expected error auth.unauthenticated");
    expect(judge({ ok: false, code: "x.y", json: {}, transport: "cli" })).toContain("failed x.y");
  });

  test("interpolate: whole values keep their type, embedded ones become text, unknown names throw", () => {
    const vars = { team: "team_1", owner: { user: "user_1" }, n: 5 };
    expect(interpolate({ a: "${n}", b: "cloud:${team}/vm/${owner.user}", c: ["${team}"] }, vars)).toEqual({ a: 5, b: "cloud:team_1/vm/user_1", c: ["team_1"] });
    expect(() => interpolate("${nope}", vars)).toThrow("no variable ${nope}");
  });

  test("a scenario's verdict: fail beats pending beats skip beats pass", () => {
    const r = (o: any) => ({ scenario: "s", index: 0, label: "", actor: "", action: "", outcome: o, ms: 0, detail: "" });
    expect(scenarioOutcome([r("pass"), r("pending"), r("fail")])).toBe("fail");
    expect(scenarioOutcome([r("pass"), r("pending"), r("skip")])).toBe("pending");
    expect(scenarioOutcome([r("pass"), r("skip")])).toBe("skip");
    expect(scenarioOutcome([r("pass")])).toBe("pass");
  });

  test("answers to codes: API errors, CLI JSON and stderr, turn errors", () => {
    expect(apiResult(403, JSON.stringify({ ok: false, error: { code: "team.not_member", message: "not a member" } }))).toMatchObject({ ok: false, code: "team.not_member" });
    expect(apiResult(200, JSON.stringify({ ok: false, error: { code: "auth.forbidden" } })).code).toBe("auth.forbidden");
    expect(apiResult(500, "boom").code).toBe("http.500");
    // The auth layer's refusal is the tagged error itself, its code at the top (live dev answer, 2026-11-07).
    expect(apiResult(401, JSON.stringify({ _tag: "Unauthenticated", code: "auth.unauthenticated", message: "missing or invalid bearer token" }))).toMatchObject({ ok: false, code: "auth.unauthenticated", message: "missing or invalid bearer token" });
    expect(cliJson('status line\n{"a":1}\n')).toEqual({ a: 1 });
    expect(cliErrorCode({ error: { code: "share.revoked" } }, "", 1)).toBe("share.revoked");
    expect(cliErrorCode(null, "error: cloud.app_not_running: start cmux", 1)).toBe("cloud.app_not_running");
    expect(cliErrorCode(null, "no", 3)).toBe("cli.exit_3");
    expect(turnErrorCode('{"kind":"turn_error","error":"inference.gateway_offline: Your model gateway is offline"}')).toBe("inference.gateway_offline");
    expect(turnErrorCode("API Error: 429 rate_limit_error")).toBe("provider.rate_limited");
    expect(turnErrorCode("401 authentication_error")).toBe("provider.auth");
    // The daemon's classification wins over words elsewhere in the failure (a live dev turn, 2026-11-07).
    expect(turnErrorCode('{"error":"overloaded? no: Not logged in · Please run /login","errorKind":"auth.signed_out"}')).toBe("auth.signed_out");
  });

  test("a verb is present only when its own help names it (an unknown verb gets the noun's overview, exit 0)", () => {
    const overview = "USAGE\n  cmux vm <action> [--target machine:MACHINE_ID]\n  cmux vm ls | status | pause | resume | rm";
    expect(helpNamesVerb(overview, ["cloud", "team", "list"])).toBe(false);
    expect(helpNamesVerb("usage: cmux vm machine-status --target machine:MACHINE_ID", ["cloud", "machine-status"])).toBe(true);
    expect(helpNamesVerb("cmux: usage: cmux machine access new --target\n       cmux machine access exec --target machine:VM_ID", ["machine", "access", "exec"])).toBe(true);
    // `inference gateway status` printing the gateway's own help is not the status verb.
    expect(helpNamesVerb("Usage:\n  cmux inference gateway [--api URL] [--team TEAM]", ["inference", "gateway", "status"])).toBe(false);
    expect(helpNamesVerb("Usage:\n  cmux inference gateway [--api URL] [--team TEAM]", ["inference", "gateway"])).toBe(true);
    expect(helpNamesVerb("error: unknown command cloud share", ["cloud", "share", "chat"])).toBe(false);
  });

  test("the report carries no secret", () => {
    const d = mkdtempSync(path.join(tmp, "report-"));
    writeReport(d, { backend: { name: "dev", api: "https://x" }, started_at: "", meta: {}, scenarios: [{ name: "s", outcome: "fail", ms: 1, reason: "token sekret-value-123 leaked", pending_lanes: [], covers: [], steps: [] }] }, ["sekret-value-123"]);
    expect(readFileSync(path.join(d, "journey.json"), "utf8")).not.toContain("sekret-value-123");
    expect(readFileSync(path.join(d, "summary.md"), "utf8")).not.toContain("sekret-value-123");
  });
});

/** A fake API: sessions by token, one shared team with roles, a member removable live. */
function fakeApi() {
  const users = new Map<string, string>(); // token -> user
  const roles = new Map<string, string>(); // user -> role in TEAM
  let TEAM = "";
  const server = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      const token = (req.headers.get("authorization") ?? "").replace(/^Bearer /, "");
      const user = users.get(token);
      const deny = (status: number, code: string) => Response.json({ ok: false, error: { code, message: code } }, { status });
      if (!user) return deny(401, "auth.unauthenticated");
      const body: any = await req.json().catch(() => ({}));
      const team = req.headers.get("x-cmux-team");
      if (team && team !== TEAM) return deny(403, "auth.forbidden");
      if (team && !roles.has(user)) return deny(403, "team.not_member");
      if (url.pathname === "/v1/ops" && body.op === "user.ensure") return Response.json({ ok: true, value: { id: user } });
      if (url.pathname === "/v1/read" && body.op === "user.teams.list")
        return Response.json({ ok: true, value: { teams: [{ id: `personal_${user}`, kind: "personal", role: "owner" }, ...(roles.has(user) ? [{ id: TEAM, kind: "stack", role: roles.get(user) }] : [])] } });
      if (url.pathname === "/v1/read" && body.op === "team.members.list") return Response.json({ ok: true, value: { members: [...roles].map(([u, role]) => ({ user: u, role })) } });
      if (url.pathname === "/v1/read" && body.op === "cloud.machine.list") return Response.json({ ok: true, value: { machines: [] } });
      return deny(404, "not.found");
    },
  });
  const fixtures: Fixtures = {
    kind: "worker",
    mutable: true,
    synced: true,
    async user(actor) {
      const u = { email: selftestEmail("t", actor), stack_user: `su_${actor}`, access_token: `tok_${actor}_${Math.random().toString(36).slice(2)}` };
      users.set(u.access_token, `user_${actor}`);
      return u;
    },
    async team(owner) {
      TEAM = "team_fake";
      roles.set(users.get(owner.access_token)!, "owner");
      return { stack_team: "st_fake", team: TEAM };
    },
    async setRole(_t: FixtureTeam, u: FixtureUser, role) {
      roles.set(users.get(u.access_token)!, role);
    },
    async remove(_t: FixtureTeam, u: FixtureUser) {
      roles.delete(users.get(u.access_token)!);
    },
    async revokeSessions(u) {
      users.delete(u.access_token);
      return 1;
    },
    async cleanup() {
      return { users: 0, teams: 0 };
    },
  };
  return { url: `http://127.0.0.1:${server.port}`, server, fixtures };
}

const ctxFor = (api: string, fixtures: Fixtures, cmux: string | null = null, driver: RunCtx["driver"] = "auto"): RunCtx => ({
  cmux, driver, api, run: "t1", dir: mkdtempSync(path.join(tmp, "run-")), actors: new Map(), vars: { run: "t1" }, fixtures, users: new Map(), team: null, stub: null, gateways: new Map(), secrets: [], machines: new Set(),
});
const ALL: Abilities = { "fixtures.mutate": true, machine: "--no-machines", gateway: "no", stub: "no", cmux: true };

describe("runner against a fake API", () => {
  let api: ReturnType<typeof fakeApi>;
  beforeAll(() => {
    api = fakeApi();
  });
  afterAll(() => api.server.stop(true));

  test("a role the backend cannot express skips the scenario once, and is not provisioned again", async () => {
    let made = 0;
    const fixtures: Fixtures = {
      ...api.fixtures,
      user: async (name: string) => (name === "admin" && made++, api.fixtures.user(name)),
      setRole: async (t: FixtureTeam, u: FixtureUser, role: string) => {
        if (role === "admin") throw new Error("fixtures.role_unavailable: the sign-in project defines no cmux:admin team permission");
        return api.fixtures.setRole(t, u, role as any);
      },
    } as Fixtures;
    const ctx = ctxFor(api.url, fixtures);
    const s = SCENARIOS.find((x) => x.name === "team.role_matrix")!;
    const first = await runScenario(s, ctx, ALL);
    const second = await runScenario({ ...s, name: "again" }, ctx, ALL);
    expect([first.outcome, second.outcome]).toEqual(["skip", "skip"]);
    expect(first.reason).toContain("fixtures.role_unavailable");
    expect(made).toBe(1);
  });

  test("team.list, team.role_matrix and team.member_removed_live pass through the routes, owner first, each actor its own token", async () => {
    const ctx = ctxFor(api.url, api.fixtures);
    for (const name of ["team.list", "team.role_matrix", "team.member_removed_live", "identity.isolated"]) {
      const rec = await runScenario(SCENARIOS.find((s) => s.name === name)!, ctx, ALL);
      expect({ name, outcome: rec.outcome, reason: rec.reason }).toEqual({ name, outcome: "pass", reason: "" });
      // The team routes run today, and the record says the CLI verb is still to come.
      if (name === "team.list") expect(rec.steps[0]!.detail).toContain("PENDING-D");
    }
    const homes = new Set([...ctx.actors.values()].map((a) => a.home));
    expect(homes.size).toBe(ctx.actors.size);
  });

  test("a scenario that needs machines is skipped with the reason; a lane verb that is missing is PENDING", async () => {
    const ctx = ctxFor(api.url, api.fixtures);
    const vm = await runScenario(SCENARIOS.find((s) => s.name === "vm.login_free")!, ctx, ALL);
    expect(vm.outcome).toBe("skip");
    expect(vm.reason).toContain("machine: --no-machines");
    const keys = await runScenario(SCENARIOS.find((s) => s.name === "team_keys.shared_path")!, ctx, ALL);
    expect({ outcome: keys.outcome, reason: keys.reason }).toMatchObject({ outcome: "pending" });
    expect(keys.pending_lanes).toEqual(["E"]);
    expect(keys.steps[0]!.detail).toMatch(/^PENDING-E/);
    expect(keys.steps.slice(1).every((s) => s.outcome === "skip")).toBe(true);
  });

  test("a failing expectation fails the scenario and stops it; a within_ms wait converges", async () => {
    const ctx = ctxFor(api.url, api.fixtures);
    const s: Scenario = {
      name: "t.fail", summary: "", covers: ["x"], tags: [], actors: [{ name: "owner", team_role: "owner" }, { name: "outsider", team_role: null }],
      steps: [{ actor: "outsider", action: "team.members", args: { team: "${team}" }, expect: { ok: true } }, { actor: "owner", action: "team.list" }],
    };
    const rec = await runScenario(s, ctx, ALL);
    expect(rec.outcome).toBe("fail");
    expect(rec.steps[0]!.detail).toContain("failed team.not_member");
    expect(rec.steps[1]!.outcome).toBe("skip");
  });

  test("simultaneous steps run at once and join", async () => {
    const ctx = ctxFor(api.url, api.fixtures);
    const s: Scenario = {
      name: "t.conc", summary: "", covers: ["x"], tags: [], actors: [{ name: "owner", team_role: "owner" }, { name: "member", team_role: "member" }],
      steps: [{ actor: "owner", action: "team.list", concurrent: true }, { actor: "member", action: "team.list", concurrent: true }, { actor: "owner", action: "team.members" }],
    };
    const rec = await runScenario(s, ctx, ALL);
    expect(rec.outcome).toBe("pass");
    expect(rec.steps.map((x) => x.index)).toEqual([0, 1, 2]);
  });

  test("the CLI transport: the verb runs as the actor with only its own environment (no caller CMUX_* leaks in)", async () => {
    const bin = path.join(tmp, "fake-cmux");
    writeFileSync(bin, `#!/bin/sh
case "$*" in
  "cloud team list --help") echo "usage: cmux cloud team list [--json]"; exit 0 ;;
  *--help) echo "unknown command" >&2; exit 2 ;;
  "--json cloud team list") printf '{"teams":[{"id":"%s","role":"via-cli"}],"actor":"%s","home":"%s","surface":"%s","token":"%s"}\\n' "$CMUX_CLOUD_TEAM" "$CMUX_SELFTEST_ACTOR" "$HOME" "\${CMUX_SURFACE_ID:-}" "$CMUX_CLOUD_ACCESS_TOKEN" ;;
  *) echo '{"ok":false,"error":{"code":"fake.unknown"}}'; exit 1 ;;
esac
`);
    chmodSync(bin, 0o755);
    process.env.CMUX_SURFACE_ID = "surface-of-the-caller";
    try {
      const ctx = ctxFor(api.url, api.fixtures, bin);
      const s: Scenario = {
        name: "t.cli", summary: "", covers: ["x"], tags: [], actors: [{ name: "owner", team_role: "owner" }, { name: "member", team_role: "member" }],
        steps: [{ actor: "member", action: "team.list", expect: { json: { teams: [{ id: "team_fake", role: "via-cli" }], actor: "member", surface: "" } } }],
      };
      const rec = await runScenario(s, ctx, ALL);
      expect(rec.outcome).toBe("pass");
      expect(rec.steps[0]!.transport).toBe("cli");
      // --driver api forces the route even where the verb exists.
      const forced = await runScenario({ ...s, steps: [{ actor: "member", action: "team.list", expect: { json: { teams: { $contains: { role: "member" } } } } }] }, ctxFor(api.url, api.fixtures, bin, "api"), ALL);
      expect(forced.steps.at(-1)!.transport).toBe("api");
    } finally {
      delete process.env.CMUX_SURFACE_ID;
    }
  });

  test("resolve: cli > route > PENDING on the lane; skip for a base verb with no cmux", () => {
    const ctx = ctxFor(api.url, api.fixtures, "/bin/cmux");
    const actor = new Actor({ name: "x" }, ctx.dir, ctx.api);
    const both: ActionDef = { lane: "D", summary: "", verb: ["v"], cli: () => ["v"], api: async () => ({ ok: true, json: {}, transport: "api" }) };
    expect(resolve(both, {}, ctx, actor, () => true).kind).toBe("cli");
    expect(resolve(both, {}, ctx, actor, () => false).kind).toBe("api");
    expect(resolve({ ...both, api: undefined }, {}, ctx, actor, () => false)).toMatchObject({ kind: "pending", lane: "D" });
    expect(resolve({ ...both, lane: "base", api: undefined }, {}, { ...ctx, cmux: null }, actor, () => false).kind).toBe("skip");
    expect(resolve(ACTIONS["share.create"]!, {}, ctx, actor, () => false)).toMatchObject({ kind: "pending", lane: "C" });
  });
});

describe("fixtures", () => {
  type Call = { method: string; url: string; body: any; headers: Record<string, string> };
  const fakeStack = () => {
    const calls: Call[] = [];
    let n = 0;
    const meta = new Map<string, any>();
    const http = async (method: string, url: string, body: any, headers: Record<string, string>) => {
      calls.push({ method, url, body, headers });
      const p = new URL(url).pathname.replace("/api/v1", "");
      if (method === "POST" && p === "/users") return { status: 201, body: { id: `su${++n}` } };
      if (method === "POST" && p === "/auth/sessions") return { status: 200, body: { access_token: `at${n}`, refresh_token: `rt${n}` } };
      if (method === "POST" && p === "/teams") return { status: 201, body: { id: "st1" } };
      if (method === "GET" && p.startsWith("/teams/")) return { status: 200, body: { server_metadata: meta.get("team") ?? { cmuxSelftest: "run1" } } };
      if (method === "GET" && p.startsWith("/users/")) return { status: 200, body: meta.get(p) ?? { primary_email: `selftest-run1-x@selftest.cmux.invalid`, server_metadata: { cmuxSelftest: "run1" } } };
      if (method === "GET" && p === "/auth/sessions") return { status: 200, body: { items: [{ id: "s1" }, { id: "s2" }] } };
      return { status: 200, body: {} };
    };
    return { calls, http, meta };
  };

  test("stack: refuses the production project and a missing key", () => {
    expect(() => stackFixtures("run1", "k", [], fakeStack().http, STACK.prod.project)).toThrow("fixtures.refused");
    expect(() => stackFixtures("run1", "", [])).toThrow("fixtures.not_configured");
  });

  test("stack: marked users, a team, roles as cmux permissions, revoke, and cleanup of marked things only", async () => {
    const f = fakeStack();
    const secrets: string[] = [];
    const fx = stackFixtures("run1", "server-key", secrets, f.http);
    const owner = await fx.user("owner");
    const member = await fx.user("member");
    expect(owner.email).toBe("selftest-run1-owner@selftest.cmux.invalid");
    expect(f.calls[0]!.body).toMatchObject({ primary_email: owner.email, server_metadata: { cmuxSelftest: "run1" } });
    expect(f.calls[0]!.headers["x-stack-project-id"]).toBe(STACK.dev.project);
    const team = await fx.team(owner, "Self-test");
    expect(team.team).toBe(cmuxTeamId(STACK.dev.project, "st1"));
    await fx.setRole(team, member, "admin");
    const routes = f.calls.map((c) => `${c.method} ${new URL(c.url).pathname.replace("/api/v1", "")}`);
    expect(routes).toContain("POST /team-memberships/st1/su2");
    expect(routes).toContain("POST /team-permissions/st1/su2/cmux%3Aadmin");
    expect(routes).toContain("DELETE /team-permissions/st1/su2/cmux%3Aguest");
    await expect(fx.setRole(team, { ...member, stack_user: "someone-real" }, "member")).rejects.toThrow("fixtures.refused");
    expect(await fx.revokeSessions(member)).toBe(2);
    // A user whose mark is gone (not this run's) is never deleted.
    f.meta.set("/users/su2", { primary_email: "real@person.dev", server_metadata: {} });
    expect(await fx.cleanup()).toEqual({ users: 1, teams: 1 });
    expect(f.calls.filter((c) => c.method === "DELETE" && new URL(c.url).pathname.startsWith("/api/v1/users/")).map((c) => c.url)).toEqual([expect.stringContaining("/users/su1")]);
    expect(secrets).toEqual(expect.arrayContaining(["server-key", "at1", "rt1"]));
  });

  test("stack: a permission not held is fine to take away; an undefined role permission is role_unavailable", async () => {
    const f = fakeStack();
    // As the live service answers: DELETE of a permission the user lacks is 401 TEAM_PERMISSION_NOT_FOUND, and a
    // project without the cmux:admin definition answers 404 PERMISSION_NOT_FOUND to its grant.
    const http = async (method: string, url: string, body: any, headers: Record<string, string>) => {
      const p = new URL(url).pathname;
      if (method === "DELETE" && p.includes("/team-permissions/")) return { status: 401, body: { code: "TEAM_PERMISSION_NOT_FOUND" } };
      if (method === "POST" && p.endsWith("/cmux%3Aadmin")) return { status: 404, body: { code: "PERMISSION_NOT_FOUND" } };
      return f.http(method, url, body, headers);
    };
    const fx = stackFixtures("run1", "server-key", [], http);
    const owner = await fx.user("owner");
    const member = await fx.user("member");
    const team = await fx.team(owner, "Self-test");
    await fx.setRole(team, member, "member");
    await expect(fx.setRole(team, member, "admin")).rejects.toThrow("fixtures.role_unavailable");
  });

  test("worker: one route, the token header, the code of a refusal", async () => {
    const calls: any[] = [];
    const http = async (method: string, url: string, body: any, headers: Record<string, string>) => {
      calls.push({ method, url, body, headers });
      if (body.op === "team") return { status: 403, body: { ok: false, error: { code: "fixtures.refused", message: "not here" } } };
      return { status: 200, body: { ok: true, value: { email: "e", stack_user: "su", access_token: "at", refresh_token: "rt" } } };
    };
    const fx = workerFixtures("run1", "https://api.example", "tok", [], http);
    const u = await fx.user("owner");
    expect(u.stack_user).toBe("su");
    expect(calls[0]).toMatchObject({ url: "https://api.example/v1/dev/fixtures", body: { op: "user", run: "run1", actor: "owner" }, headers: { "x-cmux-dev-fixtures": "tok" } });
    await expect(fx.team(u, "T")).rejects.toThrow("fixtures.refused: team not here");
  });

  test("the cmux ids are the backend's derivations", () => {
    expect(cmuxUserId("p", "u")).toMatch(/^user_[0-9a-f]{20}$/);
    expect(cmuxTeamId("p", "t")).toMatch(/^team_[0-9a-f]{20}$/);
  });
});

describe("local model stub with faults", () => {
  test("a queued 429 answers the next turn request, then the script answers", async () => {
    const d = mkdtempSync(path.join(tmp, "stub-"));
    const stub = await startLocalStub(d, { version: 1, steps: [{ text: "Stub reply {{nonce}}: {{prompt~(\\[st-[^\\]]+\\])}}" }] }, "nonce1");
    try {
      expect(await stub.setFaults([{ status: 429, type: "rate_limit_error", retry_after: 1 }])).toBe(1);
      const turn = { messages: [{ role: "user", content: "[st-7] hi" }], tools: [{ name: "Bash" }] };
      const first = await fetch(`${stub.url}/v1/messages`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(turn) });
      expect(first.status).toBe(429);
      const second = await fetch(`${stub.url}/v1/messages`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(turn) });
      expect(((await second.json()) as any).content[0].text).toBe("Stub reply nonce1: [st-7]");
      expect((await stub.rows()).filter((r) => r.fault).length).toBe(1);
    } finally {
      await stub.stop();
    }
  });
});

describe("entry", () => {
  test("refuses production, and an unknown fixtures setup before any call", async () => {
    expect(await main(["run", "--backend", "prod"])).toBe(2);
    expect(await main(["run", "--backend", "dev", "--fixtures", "worker"])).toBe(2);
  });
  test("list --json names every scenario with what it waits on", async () => {
    const lines: string[] = [];
    const log = console.log;
    console.log = (s: string) => lines.push(s);
    try {
      expect(await main(["list", "--json"])).toBe(0);
    } finally {
      console.log = log;
    }
    const out = JSON.parse(lines.join("\n"));
    expect(out.scenarios.length).toBe(SCENARIOS.length);
    expect(out.actions["team.list"]).toMatchObject({ lane: "D", verb: "cmux cloud team list", route_today: true });
  });
});
