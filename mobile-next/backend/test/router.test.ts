import { describe, expect, it, vi } from "vitest";
import { handle, type Deps } from "../src/app";
import type { Db } from "../src/db";
import type { Env } from "../src/env";
import { Router } from "../src/http";
import { signAccessToken } from "../src/jwt";

const env = {
  JWT_SECRET: "s",
  APPLE_AUDIENCE: "dev.cmux.next.mobile",
  EMAIL_FROM: "x@example.com",
  TEST_EMAIL_DOMAIN: "test.cmux.dev",
} as unknown as Env;

const user = { id: "u1", email: "a@test.cmux.dev", display_name: null, created_at: "2026-10-12 00:00:00.000" };

function fakeDeps(): Deps & { db: Db & { calls: string[] } } {
  const calls: string[] = [];
  const db = {
    calls,
    rows: vi.fn(async (sql: string) => (calls.push(sql), [])),
    one: vi.fn(async (sql: string, values?: unknown[]) => {
      calls.push(sql);
      if (sql.startsWith("SELECT * FROM users WHERE id") && values?.[0] === "u1") return user;
      return null;
    }),
    exec: vi.fn(async (sql: string) => (calls.push(sql), { rowsAffected: 1 })),
  } as unknown as Db & { calls: string[] };
  return {
    db,
    onlineHostIds: async () => [],
    disconnect: async () => {},
    connectSignal: async () => new Response("signal"),
  };
}

const req = (method: string, path: string, init: RequestInit = {}) =>
  new Request(`https://w.example${path}`, { method, ...init });

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
    const { token } = await signAccessToken("s", "u1", 60);
    const r = await handle(req("GET", "/v1/me", { headers: { authorization: `Bearer ${token}` } }), env, fakeDeps());
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ id: "u1", email: "a@test.cmux.dev", display_name: null, created_at: "2026-10-12T00:00:00.000Z" });
  });

  it("a user token for a deleted user is 401", async () => {
    const { token } = await signAccessToken("s", "gone", 60);
    const r = await handle(req("GET", "/v1/me", { headers: { authorization: `Bearer ${token}` } }), env, fakeDeps());
    expect(r.status).toBe(401);
  });

  it("host-only routes reject user tokens and unknown host tokens", async () => {
    const { token } = await signAccessToken("s", "u1", 60);
    expect((await handle(req("GET", "/v1/host/me", { headers: { authorization: `Bearer ${token}` } }), env, fakeDeps())).status).toBe(401);
    expect((await handle(req("GET", "/v1/host/me", { headers: { authorization: "Bearer cnh_unknown" } }), env, fakeDeps())).status).toBe(401);
  });

  it("signal requires an upgrade, a peer id and a valid token", async () => {
    const { token } = await signAccessToken("s", "u1", 60);
    const ws = { upgrade: "websocket" };
    expect((await handle(req("GET", `/v1/signal?token=${token}&peer=p1`), env, fakeDeps())).status).toBe(426);
    expect((await handle(req("GET", `/v1/signal?token=${token}&peer=bad%20id`, { headers: ws }), env, fakeDeps())).status).toBe(400);
    expect((await handle(req("GET", `/v1/signal?token=nope&peer=p1`, { headers: ws }), env, fakeDeps())).status).toBe(401);
    const ok = await handle(req("GET", `/v1/signal?token=${token}&peer=p1`, { headers: ws }), env, fakeDeps());
    expect(await ok.text()).toBe("signal");
  });

  it("validates JSON bodies", async () => {
    const r = await handle(req("POST", "/v1/auth/email/start", { body: "{nope" }), env, fakeDeps());
    expect(r.status).toBe(400);
    const r2 = await handle(req("POST", "/v1/auth/email/start", { body: JSON.stringify({ email: "bad" }) }), env, fakeDeps());
    expect(((await r2.json()) as { error: { code: string } }).error.code).toBe("invalid_email");
  });

  it("non-test email without a send binding is 503 email_unavailable", async () => {
    const r = await handle(req("POST", "/v1/auth/email/start", { body: JSON.stringify({ email: "a@example.com" }) }), env, fakeDeps());
    expect(r.status).toBe(503);
    expect(((await r.json()) as { error: { code: string } }).error.code).toBe("email_unavailable");
  });

  it("ice without TURN secrets is STUN only", async () => {
    const { token } = await signAccessToken("s", "u1", 60);
    const r = await handle(req("GET", "/v1/ice", { headers: { authorization: `Bearer ${token}` } }), env, fakeDeps());
    expect(await r.json()).toEqual({ ice_servers: [{ urls: ["stun:stun.cloudflare.com:3478"] }], ttl: 86400 });
  });
});
