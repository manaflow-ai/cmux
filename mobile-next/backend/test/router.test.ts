import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { handle, type Deps } from "../src/app";
import type { Env } from "../src/env";
import { Router } from "../src/http";
import { signAccessToken } from "../src/jwt";
import { FakeDb } from "./fakedb";

const env = {
  JWT_SECRET: "s",
  APPLE_AUDIENCE: "dev.cmux.next.mobile",
  EMAIL_FROM: "x@example.com",
  TEST_EMAIL_DOMAIN: "test.cmux.dev",
  TEST_LOGIN_CODE: "424242",
  TEST_LOGIN_EMAILS: "ok@test.cmux.dev, other@test.cmux.dev",
} as unknown as Env;

const created = new Date("2026-10-12T00:00:00.000Z");

function fakeDeps(): Deps & { db: FakeDb; signals: Request[] } {
  const db = new FakeDb();
  for (const [id, email] of [
    ["u1", "a@test.cmux.dev"],
    ["u2", "b@example.com"],
    ["u3", "c@example.com"],
    ["u4", "d@example.com"],
  ] as const)
    db.users.push({ id, email, display_name: id === "u1" ? "Ann" : null, created_at: created, updated_at: created });
  const signals: Request[] = [];
  return {
    db,
    signals,
    onlineHostIds: async () => [],
    disconnect: async () => {},
    connectSignal: async (_userId, request) => (signals.push(request), new Response("signal")),
  };
}

const req = (method: string, path: string, init: RequestInit & { ip?: string } = {}) => {
  const headers = new Headers(init.headers);
  if (init.ip) headers.set("cf-connecting-ip", init.ip);
  return new Request(`https://w.example${path}`, { method, ...init, headers });
};

async function call(deps: Deps, method: string, path: string, opts: { token?: string; body?: unknown; ip?: string; headers?: Record<string, string> } = {}) {
  const headers: Record<string, string> = { ...(opts.headers ?? {}) };
  if (opts.token) headers.authorization = `Bearer ${opts.token}`;
  const r = await handle(
    req(method, path, { headers, ip: opts.ip, body: opts.body === undefined ? undefined : JSON.stringify(opts.body) }),
    env,
    deps,
  );
  const text = await r.text();
  let body: any = text;
  try {
    body = JSON.parse(text);
  } catch {}
  return { status: r.status, body };
}

const userToken = async (id = "u1") => (await signAccessToken("s", id, 86400)).token;

afterEach(() => vi.useRealTimers());

describe("Router", () => {
  it("matches params and reports 405", () => {
    const r = new Router<null>().on("GET", "/v1/hosts/:id", () => new Response());
    const m = r.match("GET", "/v1/hosts/abc");
    expect(m && m !== "method_not_allowed" && m.params).toEqual({ id: "abc" });
    expect(r.match("POST", "/v1/hosts/abc")).toBe("method_not_allowed");
    expect(r.match("GET", "/v1/nope")).toBeNull();
  });
});

describe("handle auth", () => {
  it("404 and 405 use the error envelope", async () => {
    const r = await handle(req("GET", "/nope"), env, fakeDeps());
    expect(r.status).toBe(404);
    expect(await r.json()).toEqual({ error: { code: "not_found", message: "not found" } });
    expect((await handle(req("PUT", "/v1/me"), env, fakeDeps())).status).toBe(405);
  });

  it("rejects missing and invalid bearer tokens without touching the DB", async () => {
    for (const auth of [undefined, "Bearer nope", "Bearer a.b.c", "Basic xyz"]) {
      const deps = fakeDeps();
      const r = await handle(req("GET", "/v1/me", { headers: auth ? { authorization: auth } : {} }), env, deps);
      expect(r.status).toBe(401);
      expect(((await r.json()) as { error: { code: string } }).error.code).toBe("unauthorized");
      expect(deps.db.calls).toEqual([]);
    }
  });

  it("accepts a valid user token", async () => {
    const r = await call(fakeDeps(), "GET", "/v1/me", { token: await userToken() });
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ id: "u1", email: "a@test.cmux.dev", display_name: "Ann", created_at: "2026-10-12T00:00:00.000Z" });
  });

  it("a user token for a deleted user is 401", async () => {
    expect((await call(fakeDeps(), "GET", "/v1/me", { token: await userToken("gone") })).status).toBe(401);
  });

  it("host-only routes reject user tokens and unknown host tokens", async () => {
    expect((await call(fakeDeps(), "GET", "/v1/host/me", { token: await userToken() })).status).toBe(401);
    expect((await call(fakeDeps(), "GET", "/v1/host/me", { token: "cnh_unknown" })).status).toBe(401);
  });

  it("validates JSON bodies", async () => {
    const r = await handle(req("POST", "/v1/auth/email/start", { body: "{nope" }), env, fakeDeps());
    expect(r.status).toBe(400);
    const r2 = await call(fakeDeps(), "POST", "/v1/auth/email/start", { body: { email: "bad" } });
    expect(r2.body.error.code).toBe("invalid_email");
  });

  it("ice without TURN secrets is STUN only", async () => {
    const r = await call(fakeDeps(), "GET", "/v1/ice", { token: await userToken() });
    expect(r.body).toEqual({ ice_servers: [{ urls: ["stun:stun.cloudflare.com:3478"] }], ttl: 86400 });
  });

  it("ice is rate limited per principal", async () => {
    const deps = fakeDeps();
    const token = await userToken();
    for (let i = 0; i < 60; i++) expect((await call(deps, "GET", "/v1/ice", { token })).status).toBe(200);
    expect((await call(deps, "GET", "/v1/ice", { token })).status).toBe(429);
    expect((await call(deps, "GET", "/v1/ice", { token: await userToken("u2") })).status).toBe(200);
  });
});

// ---------------------------------------------------------------- email login

describe("email login", () => {
  it("non-configured addresses, including non-allowlisted test addresses, are 503 email_unavailable", async () => {
    for (const email of ["a@example.com", "random@test.cmux.dev"]) {
      const r = await call(fakeDeps(), "POST", "/v1/auth/email/start", { body: { email } });
      expect(r.status).toBe(503);
      expect(r.body.error.code).toBe("email_unavailable");
    }
  });

  it("an allowlisted test address signs in with the test code; others cannot verify it", async () => {
    const deps = fakeDeps();
    expect((await call(deps, "POST", "/v1/auth/email/start", { body: { email: "OK@test.cmux.dev" } })).status).toBe(200);
    const bad = await call(deps, "POST", "/v1/auth/email/verify", { body: { email: "random@test.cmux.dev", code: "424242" } });
    expect(bad.status).toBe(400);
    const ok = await call(deps, "POST", "/v1/auth/email/verify", { body: { email: "ok@test.cmux.dev", code: "424242" } });
    expect(ok.status).toBe(200);
    expect(ok.body.user.email).toBe("ok@test.cmux.dev");
    expect(ok.body.is_new_user).toBe(true);
  });

  it("concurrent wrong guesses cannot exceed 5 attempts per code", async () => {
    const deps = fakeDeps();
    await call(deps, "POST", "/v1/auth/email/start", { body: { email: "ok@test.cmux.dev" } });
    const results = await Promise.all(
      Array.from({ length: 12 }, () => call(deps, "POST", "/v1/auth/email/verify", { body: { email: "ok@test.cmux.dev", code: "000000" } })),
    );
    expect(results.every((r) => r.status === 400)).toBe(true);
    expect(deps.db.emailCodes[0]!.attempts).toBe(5);
    const right = await call(deps, "POST", "/v1/auth/email/verify", { body: { email: "ok@test.cmux.dev", code: "424242" } });
    expect(right.status).toBe(400);
  });

  it("verify is rate limited per IP", async () => {
    const deps = fakeDeps();
    for (let i = 0; i < 30; i++) {
      const r = await call(deps, "POST", "/v1/auth/email/verify", { ip: "1.2.3.4", body: { email: `x${i}@example.com`, code: "1" } });
      expect(r.status).toBe(400);
    }
    const r = await call(deps, "POST", "/v1/auth/email/verify", { ip: "1.2.3.4", body: { email: "y@example.com", code: "1" } });
    expect(r.status).toBe(429);
  });

  it("30 failed test-code verifications in an hour disable test sign-in for an hour", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-10-12T10:00:00Z"));
    const deps = fakeDeps();
    for (let i = 0; i < 29; i++) deps.db.rateEvents.push({ bucket: "test_code_fail", k: "*", created_at: new Date() });
    await call(deps, "POST", "/v1/auth/email/start", { body: { email: "ok@test.cmux.dev" } });
    expect((await call(deps, "POST", "/v1/auth/email/verify", { body: { email: "ok@test.cmux.dev", code: "000000" } })).status).toBe(400);
    const locked = await call(deps, "POST", "/v1/auth/email/verify", { body: { email: "other@test.cmux.dev", code: "424242" } });
    expect(locked.status).toBe(429);
    const lockedToo = await call(deps, "POST", "/v1/auth/email/verify", { body: { email: "ok@test.cmux.dev", code: "424242" } });
    expect(lockedToo.status).toBe(429);
    vi.setSystemTime(new Date("2026-10-12T11:00:01Z"));
    await call(deps, "POST", "/v1/auth/email/start", { body: { email: "ok@test.cmux.dev" } });
    expect((await call(deps, "POST", "/v1/auth/email/verify", { body: { email: "ok@test.cmux.dev", code: "424242" } })).status).toBe(200);
  });
});

describe("refresh tokens", () => {
  it("reusing a rotated refresh token revokes every refresh token of the user", async () => {
    const deps = fakeDeps();
    await call(deps, "POST", "/v1/auth/email/start", { body: { email: "ok@test.cmux.dev" } });
    const s1 = (await call(deps, "POST", "/v1/auth/email/verify", { body: { email: "ok@test.cmux.dev", code: "424242" } })).body;
    const s2 = await call(deps, "POST", "/v1/auth/refresh", { body: { refresh_token: s1.refresh_token } });
    expect(s2.status).toBe(200);
    const reuse = await call(deps, "POST", "/v1/auth/refresh", { body: { refresh_token: s1.refresh_token } });
    expect(reuse.status).toBe(401);
    expect(reuse.body.error.code).toBe("invalid_refresh_token");
    expect((await call(deps, "POST", "/v1/auth/refresh", { body: { refresh_token: s2.body.refresh_token } })).status).toBe(401);
  });

  it("an unknown refresh token is 401 without revoking anything", async () => {
    const deps = fakeDeps();
    expect((await call(deps, "POST", "/v1/auth/refresh", { body: { refresh_token: "cnr_nope" } })).status).toBe(401);
  });
});

// ---------------------------------------------------------------- pairing

const MAC = { host_name: "Ann's Mac", platform: "macos", app_version: "1.0" };

async function startPairing(deps: Deps) {
  const r = await call(deps, "POST", "/v1/pairing/start", { body: MAC });
  expect(r.status).toBe(200);
  const { pairing_id, code, poll_secret } = r.body as { pairing_id: string; code: string; poll_secret: string };
  const poll = () => call(deps, "GET", `/v1/pairing/${pairing_id}?poll_secret=${encodeURIComponent(poll_secret)}`);
  return { pairing_id, code, poll_secret, poll };
}

describe("pairing with Mac approval", () => {
  it("claim -> awaiting_approval -> approve -> token delivered once", async () => {
    const deps = fakeDeps();
    const p = await startPairing(deps);
    expect(p.code).toMatch(/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$/);
    expect((await p.poll()).body).toEqual({ status: "pending" });

    const display = `${p.code.slice(0, 4)}-${p.code.slice(4)}`.toLowerCase();
    const claim = await call(deps, "POST", "/v1/pairing/claim", { token: await userToken(), body: { code: display } });
    expect(claim.status).toBe(200);
    expect(claim.body.status).toBe("awaiting_approval");
    expect(claim.body.host).toMatchObject({ name: "Ann's Mac", platform: "macos", app_version: "1.0", online: false });
    const hostId = claim.body.host.id;

    expect((await p.poll()).body).toEqual({ status: "awaiting_approval", user: { id: "u1", email: "a@test.cmux.dev", display_name: "Ann" } });
    expect((await call(deps, "GET", "/v1/hosts", { token: await userToken() })).body.hosts).toEqual([]);

    // Nobody can claim it again, including the same user.
    for (const u of ["u2", "u1"]) {
      const again = await call(deps, "POST", "/v1/pairing/claim", { token: await userToken(u), body: { code: p.code } });
      expect(again.status).toBe(404);
    }

    expect((await call(deps, "POST", `/v1/pairing/${p.pairing_id}/approve`, { body: { poll_secret: "cnp_wrong" } })).status).toBe(404);
    expect((await call(deps, "POST", `/v1/pairing/${p.pairing_id}/approve`, { body: {} })).status).toBe(401);
    const approve = await call(deps, "POST", `/v1/pairing/${p.pairing_id}/approve`, { body: { poll_secret: p.poll_secret } });
    expect(approve).toEqual({ status: 200, body: { status: "approved" } });
    expect((await call(deps, "POST", `/v1/pairing/${p.pairing_id}/approve`, { body: { poll_secret: p.poll_secret } })).status).toBe(409);

    const done = await p.poll();
    expect(done.body).toMatchObject({ status: "claimed", host_id: hostId, user: { id: "u1" } });
    expect(done.body.host_token).toMatch(/^cnh_/);
    const again = await p.poll();
    expect(again.status).toBe(410);
    expect(again.body.error.code).toBe("pairing_consumed");

    const hosts = await call(deps, "GET", "/v1/hosts", { token: await userToken() });
    expect(hosts.body.hosts.map((h: any) => h.id)).toEqual([hostId]);
    const me = await call(deps, "GET", "/v1/host/me", { token: done.body.host_token });
    expect(me.body.host.id).toBe(hostId);
  });

  it("concurrent polls after approval mint exactly one token", async () => {
    const deps = fakeDeps();
    const p = await startPairing(deps);
    await call(deps, "POST", "/v1/pairing/claim", { token: await userToken(), body: { code: p.code } });
    await call(deps, "POST", `/v1/pairing/${p.pairing_id}/approve`, { body: { poll_secret: p.poll_secret } });
    const polls = await Promise.all([p.poll(), p.poll(), p.poll()]);
    expect(polls.filter((r) => r.status === 200 && r.body.host_token).length).toBe(1);
    expect(deps.db.hosts.length).toBe(1);
  });

  it("reject ends the pairing and never creates a host", async () => {
    const deps = fakeDeps();
    const p = await startPairing(deps);
    await call(deps, "POST", "/v1/pairing/claim", { token: await userToken(), body: { code: p.code } });
    const rej = await call(deps, "POST", `/v1/pairing/${p.pairing_id}/reject`, { body: { poll_secret: p.poll_secret } });
    expect(rej).toEqual({ status: 200, body: { status: "rejected" } });
    expect((await p.poll()).body).toEqual({ status: "rejected" });
    expect((await call(deps, "POST", `/v1/pairing/${p.pairing_id}/approve`, { body: { poll_secret: p.poll_secret } })).status).toBe(409);
    expect((await call(deps, "POST", "/v1/pairing/claim", { token: await userToken("u2"), body: { code: p.code } })).status).toBe(404);
    expect(deps.db.hosts).toEqual([]);
  });

  it("approve before a claim is 409 and an unclaimed pairing can be cancelled", async () => {
    const deps = fakeDeps();
    const p = await startPairing(deps);
    const early = await call(deps, "POST", `/v1/pairing/${p.pairing_id}/approve`, { body: { poll_secret: p.poll_secret } });
    expect(early.status).toBe(409);
    expect(early.body.error.code).toBe("invalid_pairing_state");
    expect((await call(deps, "POST", `/v1/pairing/${p.pairing_id}/reject`, { body: { poll_secret: p.poll_secret } })).body.status).toBe("rejected");
  });

  it("expired pairings cannot be claimed or approved", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-10-12T10:00:00Z"));
    const deps = fakeDeps();
    const p = await startPairing(deps);
    await call(deps, "POST", "/v1/pairing/claim", { token: await userToken(), body: { code: p.code } });
    vi.setSystemTime(new Date("2026-10-12T10:11:00Z"));
    expect((await p.poll()).status).toBe(410);
    expect((await call(deps, "POST", `/v1/pairing/${p.pairing_id}/approve`, { body: { poll_secret: p.poll_secret } })).status).toBe(410);
  });

  it("claims are limited to 10 per user per 10 minutes", async () => {
    const deps = fakeDeps();
    const token = await userToken();
    for (let i = 0; i < 10; i++)
      expect((await call(deps, "POST", "/v1/pairing/claim", { token, body: { code: "AAAA-AAAA" } })).status).toBe(404);
    expect((await call(deps, "POST", "/v1/pairing/claim", { token, body: { code: "AAAA-AAAA" } })).status).toBe(429);
  });

  it("claims are limited to 30 per IP per 10 minutes", async () => {
    const deps = fakeDeps();
    for (const u of ["u1", "u2", "u3"]) {
      const token = await userToken(u);
      for (let i = 0; i < 10; i++)
        expect((await call(deps, "POST", "/v1/pairing/claim", { token, ip: "9.9.9.9", body: { code: "AAAAAAAA" } })).status).toBe(404);
    }
    const r = await call(deps, "POST", "/v1/pairing/claim", { token: await userToken("u4"), ip: "9.9.9.9", body: { code: "AAAAAAAA" } });
    expect(r.status).toBe(429);
  });

  it("20 failed claims in an hour lock the user out for an hour", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-10-12T10:00:00Z"));
    const deps = fakeDeps();
    const token = await userToken();
    const claim = (code: string) => call(deps, "POST", "/v1/pairing/claim", { token, body: { code } });
    for (let i = 0; i < 10; i++) expect((await claim("AAAAAAAA")).status).toBe(404);
    vi.setSystemTime(new Date("2026-10-12T10:11:00Z"));
    for (let i = 0; i < 10; i++) expect((await claim("AAAAAAAA")).status).toBe(404);
    vi.setSystemTime(new Date("2026-10-12T10:22:00Z"));
    const p = await startPairing(deps);
    const locked = await claim(p.code);
    expect(locked.status).toBe(429);
    vi.setSystemTime(new Date("2026-10-12T11:11:01Z"));
    const p2 = await startPairing(deps);
    expect((await claim(p2.code)).status).toBe(200);
  });
});

// ---------------------------------------------------------------- signaling

describe("signal", () => {
  const ws = { upgrade: "websocket" };

  it("requires an upgrade, a valid token and a valid phone peer id", async () => {
    const token = await userToken();
    expect((await call(fakeDeps(), "GET", `/v1/signal?token=${token}&peer=p1`)).status).toBe(426);
    expect((await call(fakeDeps(), "GET", `/v1/signal?token=${token}&peer=bad%20id`, { headers: ws })).status).toBe(400);
    expect((await call(fakeDeps(), "GET", `/v1/signal?token=nope&peer=p1`, { headers: ws })).status).toBe(401);
    const ok = await call(fakeDeps(), "GET", `/v1/signal?token=${token}&peer=p1`, { headers: ws });
    expect(ok.body).toBe("signal");
  });

  it("accepts the token from the Authorization header and strips it from the forwarded request", async () => {
    const deps = fakeDeps();
    const r = await call(deps, "GET", "/v1/signal?peer=phone-1", { token: await userToken(), headers: ws });
    expect(r.body).toBe("signal");
    const fwd = deps.signals[0]!;
    expect(fwd.headers.get("authorization")).toBeNull();
    expect(fwd.headers.get("x-peer-id")).toBe("phone-1");
    expect(fwd.headers.get("x-peer-kind")).toBe("phone");

    const deps2 = fakeDeps();
    await call(deps2, "GET", `/v1/signal?token=${await userToken()}&peer=phone-1`, { headers: ws });
    expect(new URL(deps2.signals[0]!.url).searchParams.get("token")).toBeNull();
  });

  it("phones cannot use host peer ids or inject internal headers", async () => {
    const token = await userToken();
    for (const peer of ["host-abc", "HOST1", "host"]) {
      const r = await call(fakeDeps(), "GET", `/v1/signal?peer=${peer}`, { token, headers: ws });
      expect(r.status).toBe(400);
      expect(r.body.error.code).toBe("invalid_peer");
    }
    const deps = fakeDeps();
    await call(deps, "GET", "/v1/signal?peer=phone-1", {
      token,
      headers: { ...ws, "x-host-id": "h-evil", "x-peer-name": "evil", "x-peer-kind": "host", "x-user-id": "u2" },
    });
    const fwd = deps.signals[0]!;
    expect(fwd.headers.get("x-host-id")).toBeNull();
    expect(fwd.headers.get("x-peer-name")).toBeNull();
    expect(fwd.headers.get("x-user-id")).toBeNull();
    expect(fwd.headers.get("x-peer-kind")).toBe("phone");
  });

  it("hosts get the server-assigned peer id host-<hostId>", async () => {
    const deps = fakeDeps();
    const p = await startPairing(deps);
    await call(deps, "POST", "/v1/pairing/claim", { token: await userToken(), body: { code: p.code } });
    await call(deps, "POST", `/v1/pairing/${p.pairing_id}/approve`, { body: { poll_secret: p.poll_secret } });
    const { host_id, host_token } = (await p.poll()).body;
    await call(deps, "GET", "/v1/signal?peer=phone-pretend", { token: host_token, headers: ws });
    const fwd = deps.signals[0]!;
    expect(fwd.headers.get("x-peer-id")).toBe(`host-${host_id}`);
    expect(fwd.headers.get("x-peer-kind")).toBe("host");
    expect(fwd.headers.get("x-host-id")).toBe(host_id);
    expect(decodeURIComponent(fwd.headers.get("x-peer-name")!)).toBe("Ann's Mac");
  });

  it("deleted accounts cannot connect", async () => {
    const deps = fakeDeps();
    const r = await call(deps, "GET", "/v1/signal?peer=phone-1", { token: await userToken("gone"), headers: ws });
    expect(r.status).toBe(401);
    expect(deps.signals).toEqual([]);
  });
});

beforeEach(() => vi.useRealTimers());
