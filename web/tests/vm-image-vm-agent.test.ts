import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import {
  API_ORIGINS,
  BindFileError,
  bindMachine,
  CloudClient,
  type Clock,
  ensureInstallKey,
  EventSender,
  MemoryStore,
  parseBindFile,
  StatusReporter,
} from "../../images/cmux-vm/guest/vm-agent";

// cmux.wire/1 vectors shared with the backend tests (backend/catalog/cloud-vectors.json).
const vectors = JSON.parse(readFileSync(path.resolve(import.meta.dir, "../../backend/catalog/cloud-vectors.json"), "utf8")) as {
  backend_only: Array<{ name: string; params: Record<string, unknown>; responses: Array<{ http: { status: number }; body: unknown }> }>;
  cases: Array<{ name: string; params: Record<string, unknown>; responses: Array<{ http: { status: number }; body: unknown }> }>;
};
const vector = (name: string) => [...vectors.backend_only, ...vectors.cases].find((c) => c.name === name)!;
const bindVector = vector("machine.bind");
const bound = (bindVector.responses[0].body as { value: { machine: string; host: string; epoch: number; install: { id: string; user: string } } }).value;

const DEV = API_ORIGINS.dev;
const bindFileText = JSON.stringify({ team: bindVector.params.team, machine: bound.machine, bind_token: bindVector.params.bind_token, api_origin: DEV, env: "dev" });

/** Manual clock: timers run only when the test advances time. */
class FakeClock implements Clock {
  t = 1_790_000_000_000;
  private timers: Array<{ at: number; fn: () => void; id: number }> = [];
  private next = 1;
  now = () => this.t;
  setTimer = (ms: number, fn: () => void) => {
    const id = this.next++;
    this.timers.push({ at: this.t + ms, fn, id });
    return () => {
      this.timers = this.timers.filter((x) => x.id !== id);
    };
  };
  pending = () => this.timers.map((x) => x.at - this.t).sort((a, b) => a - b);
  advance(ms: number) {
    const end = this.t + ms;
    for (;;) {
      const due = this.timers.filter((x) => x.at <= end).sort((a, b) => a.at - b.at)[0];
      if (!due) break;
      this.timers = this.timers.filter((x) => x.id !== due.id);
      this.t = due.at;
      due.fn();
    }
    this.t = end;
  }
}

type Seen = { path: string; auth: string | null; body: Record<string, any> };
const seen: Seen[] = [];
let registeredJwk: JsonWebKey | null = null;
let bindCalls = 0;
let opsScript: Array<{ status: number; body: unknown }> = [];
let challengePrefixEnv = "development";
let server: ReturnType<typeof Bun.serve>;

/** Rewrites the allowlisted https origin to the local fake server; the agent never learns the fake URL. */
const fakeFetch: typeof fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
  const url = new URL(String(input));
  if (url.origin !== DEV) throw new Error(`unexpected origin ${url.origin}`);
  return fetch(`http://127.0.0.1:${server.port}${url.pathname}`, init);
}) as typeof fetch;

const b64uToBytes = (s: string) => Uint8Array.from(Buffer.from(s, "base64url"));

beforeAll(() => {
  server = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      const body = (await req.json()) as Record<string, any>;
      seen.push({ path: url.pathname, auth: req.headers.get("authorization"), body });
      if (url.pathname === "/v1/cloud/bind") {
        const r = bindVector.responses[Math.min(bindCalls++, bindVector.responses.length - 1)];
        if (bindCalls === 1) registeredJwk = body.install_public_jwk;
        return Response.json(r.body, { status: r.http.status });
      }
      if (url.pathname === "/v1/auth/challenge") {
        return Response.json({ install: body.install, nonce: "nonce-1", expires_at: Date.now() + 60_000, message_prefix: `cmux-auth-v1\n${challengePrefixEnv}\n${body.install}\n` });
      }
      if (url.pathname === "/v1/auth/token") {
        const key = await crypto.subtle.importKey("jwk", { ...registeredJwk!, ext: true }, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
        const message = new TextEncoder().encode(`cmux-auth-v1\ndevelopment\n${body.install}\nnonce-1`);
        const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, b64uToBytes(body.signature), message);
        if (!ok) return Response.json({ _tag: "Forbidden", code: "auth.forbidden", message: "bad signature" }, { status: 403 });
        return Response.json({ access_token: "tok-1", token_type: "Bearer", expires_at: Date.now() + 3_600_000, user: body.user, team: bindVector.params.team, install: body.install, grant: "grant_v000000000000000004" });
      }
      if (url.pathname === "/v1/ops") {
        const next = opsScript.shift() ?? { status: 200, body: vector("vm.status.report").responses[0].body };
        return Response.json(next.body, { status: next.status });
      }
      return new Response("not found", { status: 404 });
    },
  });
});
afterAll(() => server.stop(true));

const wg = async () => ({ publicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" });
const daemon = async () => ({ version: "0.40.0", capabilities: ["terminal", "files"] });

describe("bind file (/var/lib/cmux/bind.json)", () => {
  test("a dev file with the allowlisted origin parses", () => {
    expect(parseBindFile(bindFileText).machine).toBe(bound.machine);
  });
  test("an origin that is not the environment's allowlisted origin is refused", () => {
    for (const [origin, env] of [["https://evil.example", "dev"], [API_ORIGINS.prod, "dev"], ["http://cmux-api-development.debussy.workers.dev", "dev"]] as const) {
      expect(() => parseBindFile(JSON.stringify({ ...JSON.parse(bindFileText), api_origin: origin, env }))).toThrow(BindFileError);
    }
  });
  test("missing fields and unknown environments are refused", () => {
    expect(() => parseBindFile(JSON.stringify({ ...JSON.parse(bindFileText), bind_token: undefined }))).toThrow(BindFileError);
    expect(() => parseBindFile(JSON.stringify({ ...JSON.parse(bindFileText), env: "qa" }))).toThrow(BindFileError);
    expect(() => parseBindFile("{")).toThrow(BindFileError);
  });
});

describe("per-clone install key (ES256 P-256)", () => {
  test("kept for the same instance id, replaced when the MMDS instance id changes", async () => {
    const store = new MemoryStore();
    const a = await ensureInstallKey(store, "i-aaa");
    const b = await ensureInstallKey(store, "i-aaa");
    const c = await ensureInstallKey(store, "i-bbb");
    expect(a.rotated).toBe(true);
    expect(b.rotated).toBe(false);
    expect(b.publicJwk).toEqual(a.publicJwk);
    expect(c.rotated).toBe(true);
    expect(c.publicJwk.x).not.toBe(a.publicJwk.x);
    expect(a.publicJwk).toMatchObject({ kty: "EC", crv: "P-256" });
    expect((a.publicJwk as Record<string, unknown>).d).toBeUndefined();
    expect(store.modeOf("/var/lib/cmux/install/key.json")).toBe(0o600);
  });
});

describe("bind, token, status report and events against a fake server (cloud-vectors.json)", () => {
  const store = new MemoryStore();
  const clock = new FakeClock();
  let client: CloudClient;
  let reporter: StatusReporter;

  test("bind posts the vector's fields plus install_public_jwk, writes bound.json, then removes bind.json", async () => {
    store.write("/var/lib/cmux/bind.json", bindFileText, 0o600);
    const key = await ensureInstallKey(store, "i-aaa");
    const result = await bindMachine({ fetch: fakeFetch, store, key, wg, daemon });
    expect(result.kind).toBe("bound");
    const req = seen.find((s) => s.path === "/v1/cloud/bind")!;
    expect(req.auth).toBeNull();
    expect(Object.keys(req.body).sort()).toEqual(["bind_token", "daemon", "install_public_jwk", "machine", "team", "wg_public_key"]);
    expect(req.body.install_public_jwk).toEqual(key.publicJwk);
    const b = JSON.parse(store.read("/var/lib/cmux/bound.json")!);
    expect(b).toMatchObject({ machine: bound.machine, host: bound.host, epoch: bound.epoch, install: bound.install.id, user: bound.install.user, env: "dev" });
    expect(store.read("/var/lib/cmux/bind.json")).toBeNull();
    expect(store.modeOf("/var/lib/cmux/bound.json")).toBe(0o600);
  });

  test("a spent token is refused and never overwrites bound.json", async () => {
    const before = store.read("/var/lib/cmux/bound.json");
    store.write("/var/lib/cmux/bind.json", bindFileText, 0o600);
    const key = await ensureInstallKey(store, "i-aaa");
    const result = await bindMachine({ fetch: fakeFetch, store, key, wg, daemon });
    expect(result).toMatchObject({ kind: "refused", code: "auth.forbidden" });
    expect(store.read("/var/lib/cmux/bound.json")).toBe(before);
    expect(store.read("/var/lib/cmux/bind.json")).toBeNull();
  });

  test("token: signs the server's prefix + nonce with the install key; refuses a prefix for another environment", async () => {
    const key = await ensureInstallKey(store, "i-aaa");
    client = new CloudClient({ fetch: fakeFetch, bound: JSON.parse(store.read("/var/lib/cmux/bound.json")!), key, clock });
    challengePrefixEnv = "production";
    await expect(client.token()).rejects.toThrow(/prefix/);
    challengePrefixEnv = "development";
    expect(await client.token()).toBe("tok-1");
    const tokenReq = seen.filter((s) => s.path === "/v1/auth/token").at(-1)!;
    expect(tokenReq.body).toMatchObject({ user: bound.install.user, install: bound.install.id, nonce: "nonce-1" });
  });

  test("first report right after bind; changes coalesce to one report per 10 s, latest wins; activity defaults to 0 sessions", async () => {
    seen.length = 0;
    reporter = new StatusReporter({ client, clock, machine: bound.machine, daemon: await daemon(), heartbeatMs: 60_000, random: () => 0.5 });
    reporter.trigger("bind");
    await reporter.settled();
    const first = seen.filter((s) => s.path === "/v1/ops");
    expect(first).toHaveLength(1);
    expect(first[0].auth).toBe("Bearer tok-1");
    expect(first[0].body).toEqual({ op: "cloud.vm.status.report", params: { machine: bound.machine, state: "running", daemon: await daemon(), activity: { active_sessions: 0 } } });
    reporter.update({ active_sessions: 1, last_user_input_at: clock.now() });
    reporter.update({ active_sessions: 2, last_agent_action_at: clock.now() + 1 });
    await reporter.settled();
    expect(seen.filter((s) => s.path === "/v1/ops")).toHaveLength(1);
    clock.advance(10_000);
    await reporter.settled();
    const ops = seen.filter((s) => s.path === "/v1/ops");
    expect(ops).toHaveLength(2);
    expect(ops[1].body.params.activity).toEqual({ active_sessions: 2, last_user_input_at: 1_790_000_000_000, last_agent_action_at: 1_790_000_000_001 });
  });

  test("heartbeat: one deadline timer re-armed after each applied report (no polling)", async () => {
    seen.length = 0;
    expect(clock.pending().filter((ms) => ms > 0)).toEqual([60_000]);
    clock.advance(59_999);
    await reporter.settled();
    expect(seen).toHaveLength(0);
    clock.advance(1);
    await reporter.settled();
    expect(seen.filter((s) => s.path === "/v1/ops")).toHaveLength(1);
    expect(clock.pending()).toEqual([60_000]);
  });

  test("a refused or failed report retries with backoff, honors retry_after_ms, caps at 10 min", async () => {
    seen.length = 0;
    opsScript = [
      { status: 200, body: { ok: false, op: "cloud.vm.status.report", error: { code: "cloud.rate_limited", message: "slow down", retryable: false, details: { retry_after_ms: 4_000 } } } },
      ...Array.from({ length: 12 }, () => ({ status: 503, body: { _tag: "OwnerUnreachable", code: "owner.unreachable", message: "x" } })),
    ];
    reporter.update({ active_sessions: 0 });
    clock.advance(10_000);
    await reporter.settled();
    const delays: number[] = [];
    for (let i = 0; i < 13; i++) {
      // While a report fails, the retry timer is the only timer (the heartbeat re-arms after success).
      expect(clock.pending()).toHaveLength(1);
      const next = clock.pending()[0];
      delays.push(next);
      clock.advance(next);
      await reporter.settled();
    }
    expect(delays[0]).toBeGreaterThanOrEqual(4_000);
    for (let i = 1; i < delays.length; i++) expect(delays[i]).toBeGreaterThanOrEqual(delays[i - 1]);
    expect(delays.at(-1)).toBe(600_000);
    expect(seen.filter((s) => s.path === "/v1/ops").length).toBe(14);
    expect(clock.pending()).toEqual([60_000]);
  });

  test("events: v1 kinds only, sent as cloud.vm.event.emit, rate limit honored", async () => {
    seen.length = 0;
    opsScript = [
      { status: 200, body: vector("vm.event.emit.rate_limited").responses[0].body },
      { status: 200, body: vector("vm.event.emit").responses[0].body },
    ];
    const sender = new EventSender({ client, clock, machine: bound.machine });
    const at = clock.now();
    expect(() => sender.emit("agent.exploded", at, {})).toThrow(/kind/);
    sender.emit("agent.finished", at, { title: "Done", outcome: "success" });
    await sender.settled();
    expect(seen.filter((s) => s.path === "/v1/ops")).toHaveLength(1);
    expect(clock.pending()[0]).toBe(100);
    clock.advance(100);
    await sender.settled();
    const ops = seen.filter((s) => s.path === "/v1/ops");
    expect(ops).toHaveLength(2);
    expect(ops[1].body).toEqual({ op: "cloud.vm.event.emit", params: { machine: bound.machine, kind: "agent.finished", at, data: { title: "Done", outcome: "success" } } });
  });
});
