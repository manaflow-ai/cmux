import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { fileURLToPath } from "node:url";
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
const vectors = JSON.parse(readFileSync(fileURLToPath(new URL("../../backend/catalog/cloud-vectors.json", import.meta.url)), "utf8")) as {
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
let server: Server;
let port = 0;

/** Rewrites the allowlisted https origin to the local fake server; the agent never learns the fake URL. */
const fakeFetch: typeof fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
  const url = new URL(String(input));
  if (url.origin !== DEV) throw new Error(`unexpected origin ${url.origin}`);
  return fetch(`http://127.0.0.1:${port}${url.pathname}`, init);
}) as typeof fetch;

const b64uToBytes = (s: string) => Uint8Array.from(Buffer.from(s, "base64url"));

async function route(pathname: string, body: Record<string, any>, authorization: string | null): Promise<{ status: number; body: unknown }> {
  seen.push({ path: pathname, auth: authorization, body });
  if (pathname === "/v1/cloud/bind") {
    const r = bindVector.responses[Math.min(bindCalls++, bindVector.responses.length - 1)];
    if (bindCalls === 1) registeredJwk = body.install_public_jwk;
    return { status: r.http.status, body: r.body };
  }
  if (pathname === "/v1/auth/challenge") {
    return { status: 200, body: { install: body.install, nonce: "nonce-1", expires_at: Date.now() + 60_000, message_prefix: `cmux-auth-v1\n${challengePrefixEnv}\n${body.install}\n` } };
  }
  if (pathname === "/v1/auth/token") {
    const key = await crypto.subtle.importKey("jwk", { ...registeredJwk!, ext: true }, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    const message = new TextEncoder().encode(`cmux-auth-v1\ndevelopment\n${body.install}\nnonce-1`);
    const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, b64uToBytes(body.signature), message);
    if (!ok) return { status: 403, body: { _tag: "Forbidden", code: "auth.forbidden", message: "bad signature" } };
    return { status: 200, body: { access_token: "tok-1", token_type: "Bearer", expires_at: Date.now() + 3_600_000, user: body.user, team: bindVector.params.team, install: body.install, grant: "grant_v000000000000000004" } };
  }
  if (pathname === "/v1/ops") return opsScript.shift() ?? { status: 200, body: vector("vm.status.report").responses[0].body };
  return { status: 404, body: { message: "not found" } };
}

beforeAll(async () => {
  server = createServer((req: IncomingMessage, res: ServerResponse) => {
    let raw = "";
    req.setEncoding("utf8");
    req.on("data", (chunk: string) => (raw += chunk));
    req.on("end", () => {
      void route(new URL(req.url ?? "/", "http://x").pathname, JSON.parse(raw || "{}") as Record<string, any>, req.headers.authorization ?? null).then((answer) => {
        res.writeHead(answer.status, { "content-type": "application/json" });
        res.end(JSON.stringify(answer.body));
      });
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  port = (server.address() as AddressInfo).port;
});
afterAll(() => new Promise<void>((resolve) => server.close(() => resolve())));

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

describe("per-clone machine-id and the daemon block of bind (coordinator 2026-10-05)", () => {
  test("machine-id is regenerated when the MMDS instance id changes, kept otherwise, written to both machine-id files 0444", async () => {
    const { ensureMachineId } = await import("../../images/cmux-vm/guest/vm-agent");
    const store = new MemoryStore();
    store.write("/etc/machine-id", "0123456789abcdef0123456789abcdef\n", 0o444);
    let n = 0;
    const random = () => (++n).toString(16).padStart(32, "a");
    expect(ensureMachineId(store, "i-aaa", random)).toBe(true);
    const first = store.read("/etc/machine-id")!;
    expect(first).toMatch(/^[0-9a-f]{32}\n$/);
    expect(first).not.toBe("0123456789abcdef0123456789abcdef\n");
    expect(store.read("/var/lib/dbus/machine-id")).toBe(first);
    expect(store.modeOf("/etc/machine-id")).toBe(0o444);
    expect(ensureMachineId(store, "i-aaa", random)).toBe(false);
    expect(store.read("/etc/machine-id")).toBe(first);
    expect(ensureMachineId(store, "i-bbb", random)).toBe(true);
    expect(store.read("/etc/machine-id")).not.toBe(first);
  });

  test("bind's daemon block comes from the live daemon identify: version + build, Cloud-gated capabilities, never empty, at most 32", async () => {
    const { mkdtempSync } = await import("node:fs");
    const { tmpdir } = await import("node:os");
    const { createServer: createUnixServer } = await import("node:net");
    const { resolveDaemonInfo } = await import("../../images/cmux-vm/guest/vm-agent");
    const sock = `${mkdtempSync(path.join(tmpdir(), "d-"))}/cloud.sock`;
    const caps = ["attach-identity-v1", "fs-v1", "loopback-forward-v1", ...Array.from({ length: 70 }, (_, i) => `cap-${i}-v1`)];
    const daemonServer = createUnixServer((s) => {
      s.on("data", (d) => {
        const req = JSON.parse(String(d).trim()) as { id: number; cmd: string };
        expect(req.cmd).toBe("identify");
        s.end(`${JSON.stringify({ id: req.id, ok: true, data: { app: "cmux-tui", version: "0.41.0", build_commit: "0123456789abcdef0123", capabilities: caps } })}\n`);
      });
    });
    await new Promise<void>((resolve) => daemonServer.listen(sock, resolve));
    const store = new MemoryStore();
    store.write("/etc/cmux/daemon-socket", `${sock}\n`, 0o644);
    const live = await resolveDaemonInfo(store, { activitySender: false });
    expect(live.version).toBe("0.41.0+0123456789ab");
    expect(live.capabilities).toEqual(["fs-v1", "loopback-forward-v1", "vm-agent-v1"]);
    expect(live.capabilities).not.toContain("activity");
    const withActivity = await resolveDaemonInfo(store, { activitySender: true });
    expect(withActivity.capabilities).toContain("activity");
    expect(withActivity.capabilities.length).toBeLessThanOrEqual(32);
    await new Promise<void>((resolve) => daemonServer.close(() => resolve()));
  });

  test("no reachable daemon: the bake-recorded /etc/cmux/daemon.json, never an empty list", async () => {
    const { resolveDaemonInfo } = await import("../../images/cmux-vm/guest/vm-agent");
    const store = new MemoryStore();
    store.write("/etc/cmux/daemon-socket", "/nonexistent/cloud.sock\n", 0o644);
    store.write("/etc/cmux/daemon.json", JSON.stringify({ version: "0.40.0+aaaaaaaaaaaa", capabilities: ["loopback-forward-v1", "vm-agent-v1"] }), 0o644);
    expect(await resolveDaemonInfo(store, { activitySender: false })).toEqual({ version: "0.40.0+aaaaaaaaaaaa", capabilities: ["loopback-forward-v1", "vm-agent-v1"] });
    store.remove("/etc/cmux/daemon.json");
    await expect(resolveDaemonInfo(store, { activitySender: false })).rejects.toThrow(/daemon/);
  });
});
