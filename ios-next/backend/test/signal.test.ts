import { exports as workerExports } from "cloudflare:workers";
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

/** Integration tests through the real Worker entry, Durable Object and WebSockets. */

const worker = (workerExports as unknown as { default: Fetcher }).default;
const BASE = "https://mobile.test";
let seq = 0;

async function api(method: string, path: string, opts: { body?: unknown; token?: string } = {}) {
  const headers: Record<string, string> = {};
  if (opts.body !== undefined) headers["content-type"] = "application/json";
  if (opts.token) headers.authorization = `Bearer ${opts.token}`;
  const res = await worker.fetch(`${BASE}${path}`, {
    method,
    headers,
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
  });
  const text = await res.text();
  return { status: res.status, json: text ? JSON.parse(text) : null };
}

async function login() {
  const email = `bot${++seq}-${crypto.randomUUID().slice(0, 8)}@test.cmux.dev`;
  const res = await api("POST", "/v1/auth/test", { body: { email, secret: "test-login-secret" } });
  expect(res.status).toBe(200);
  return res.json as { accessToken: string; refreshToken: string; user: { id: string } };
}

async function pairHost(accessToken: string, name = "Mac") {
  const start = await api("POST", "/v1/hosts/pair/start", { body: { name, os: "macOS" } });
  const approve = await api("POST", "/v1/hosts/pair/approve", { token: accessToken, body: { userCode: start.json.userCode } });
  const poll = await api("POST", "/v1/hosts/pair/poll", { body: { deviceCode: start.json.deviceCode } });
  expect(poll.json.status).toBe("approved");
  return { hostId: approve.json.host.id as string, hostToken: poll.json.hostToken as string };
}

class Peer {
  frames: any[] = [];
  waiters: { pred: (f: any) => boolean; resolve: (f: any) => void }[] = [];
  closed: { code: number; reason: string } | null = null;
  private closeWaiters: (() => void)[] = [];

  constructor(readonly ws: WebSocket) {
    ws.addEventListener("message", (e) => {
      const f = JSON.parse(String(e.data));
      const i = this.waiters.findIndex((w) => w.pred(f));
      if (i >= 0) this.waiters.splice(i, 1)[0]!.resolve(f);
      else this.frames.push(f);
    });
    ws.addEventListener("close", (e) => {
      this.closed = { code: e.code, reason: e.reason };
      for (const w of this.closeWaiters) w();
    });
  }

  next(pred: (f: any) => boolean = () => true): Promise<any> {
    const i = this.frames.findIndex(pred);
    if (i >= 0) return Promise.resolve(this.frames.splice(i, 1)[0]);
    return new Promise((resolve) => this.waiters.push({ pred, resolve }));
  }

  send(frame: unknown) {
    this.ws.send(JSON.stringify(frame));
  }

  waitClosed(): Promise<void> {
    if (this.closed) return Promise.resolve();
    return new Promise((r) => this.closeWaiters.push(r));
  }
}

async function connect(token: string, via: "query" | "header" = "header"): Promise<Peer> {
  const url = via === "query" ? `${BASE}/v1/signal?token=${encodeURIComponent(token)}` : `${BASE}/v1/signal`;
  const headers: Record<string, string> = { upgrade: "websocket" };
  if (via === "header") headers.authorization = `Bearer ${token}`;
  const res = await worker.fetch(url, { headers });
  expect(res.status).toBe(101);
  const ws = res.webSocket!;
  const peer = new Peer(ws);
  ws.accept();
  return peer;
}

describe("signaling", () => {
  it("rejects unauthenticated and non-WebSocket requests", async () => {
    expect((await worker.fetch(`${BASE}/v1/signal`, { headers: { upgrade: "websocket" } })).status).toBe(401);
    const user = await login();
    expect((await api("GET", "/v1/signal", { token: user.accessToken })).status).toBe(426);
  });

  it("relays offer, answer, candidates and bye between a phone and a host, with presence", async () => {
    const user = await login();
    const { hostId, hostToken } = await pairHost(user.accessToken, "Studio");

    const phone = await connect(user.accessToken, "header");
    const welcome = await phone.next((f) => f.type === "welcome");
    expect(welcome.peerId).toMatch(/^p_/);
    expect(welcome.hosts).toEqual([{ hostId, online: false }]);

    // Deprecated query form still works.
    const host = await connect(hostToken, "query");
    const hostWelcome = await host.next((f) => f.type === "welcome");
    expect(hostWelcome.hosts).toEqual([{ hostId, online: true }]);
    expect(await phone.next((f) => f.type === "presence")).toEqual({ type: "presence", hostId, online: true });

    const hosts = await api("GET", "/v1/hosts", { token: user.accessToken });
    expect(hosts.json.hosts[0]).toMatchObject({ id: hostId, online: true });
    expect(hosts.json.hosts[0].lastSeenAt).toEqual(expect.any(Number));

    phone.send({ type: "offer", to: hostId, sessionId: "s_1", sdp: "v=0 offer" });
    const offer = await host.next((f) => f.type === "offer");
    expect(offer).toEqual({ type: "offer", to: hostId, sessionId: "s_1", sdp: "v=0 offer", from: welcome.peerId, family: expect.stringMatching(/^rf_/) });
    // The family is the phone token's `fam`, not anything the phone sends.
    phone.send({ type: "offer", to: hostId, sessionId: "s_1b", sdp: "x", family: "rf_spoofed" });
    expect((await host.next((f) => f.type === "offer" && f.sessionId === "s_1b")).family).toBe(offer.family);

    host.send({ type: "answer", to: welcome.peerId, sessionId: "s_1", sdp: "v=0 answer" });
    expect(await phone.next((f) => f.type === "answer")).toEqual({ type: "answer", to: welcome.peerId, sessionId: "s_1", sdp: "v=0 answer", from: hostId });

    phone.send({ type: "candidate", to: hostId, sessionId: "s_1", candidate: "candidate:1 1 udp 1 1.2.3.4 5 typ host", sdpMid: "0", sdpMLineIndex: 0 });
    expect(await host.next((f) => f.type === "candidate")).toMatchObject({ from: welcome.peerId, sdpMid: "0", sdpMLineIndex: 0 });
    host.send({ type: "candidate", to: welcome.peerId, sessionId: "s_1", candidate: "candidate:2", sdpMid: "0", sdpMLineIndex: 0 });
    expect(await phone.next((f) => f.type === "candidate")).toMatchObject({ from: hostId, candidate: "candidate:2" });

    host.send({ type: "bye", to: welcome.peerId, sessionId: "s_1" });
    expect(await phone.next((f) => f.type === "bye")).toEqual({ type: "bye", to: welcome.peerId, sessionId: "s_1", from: hostId });

    // Ping is answered without waking the room.
    phone.send({ type: "ping" });
    expect(await phone.next((f) => f.type === "pong")).toEqual({ type: "pong" });

    host.ws.close(1000, "bye");
    expect(await phone.next((f) => f.type === "presence")).toEqual({ type: "presence", hostId, online: false });
    const after = await api("GET", "/v1/hosts", { token: user.accessToken });
    expect(after.json.hosts[0].online).toBe(false);
    phone.ws.close(1000);
  });

  it("reports host_offline, peer_offline, direction and validation errors", async () => {
    const user = await login();
    const { hostId, hostToken } = await pairHost(user.accessToken);
    const phone = await connect(user.accessToken);
    const welcome = await phone.next((f) => f.type === "welcome");

    phone.send({ type: "offer", to: hostId, sessionId: "s_2", sdp: "x" });
    expect(await phone.next((f) => f.type === "error")).toMatchObject({ code: "host_offline", sessionId: "s_2" });

    phone.send({ type: "answer", to: hostId, sessionId: "s_3", sdp: "x" });
    expect(await phone.next((f) => f.type === "error")).toMatchObject({ code: "forbidden", sessionId: "s_3" });

    phone.send({ type: "offer", to: hostId, sdp: "x" });
    expect(await phone.next((f) => f.type === "error")).toMatchObject({ code: "bad_request" });

    phone.send({ type: "dance", to: hostId, sessionId: "s_4" });
    expect(await phone.next((f) => f.type === "error")).toMatchObject({ code: "bad_request", sessionId: "s_4" });

    phone.ws.send("not json");
    expect(await phone.next((f) => f.type === "error")).toMatchObject({ code: "bad_request" });

    const host = await connect(hostToken);
    await host.next((f) => f.type === "welcome");
    host.send({ type: "offer", to: welcome.peerId, sessionId: "s_5", sdp: "x" });
    expect(await host.next((f) => f.type === "error")).toMatchObject({ code: "forbidden" });
    host.send({ type: "answer", to: "p_gone", sessionId: "s_6", sdp: "x" });
    expect(await host.next((f) => f.type === "error")).toMatchObject({ code: "peer_offline", sessionId: "s_6" });
    // A phone cannot be addressed as a host and vice versa.
    phone.send({ type: "candidate", to: welcome.peerId, sessionId: "s_7", candidate: "c" });
    expect(await phone.next((f) => f.type === "error")).toMatchObject({ code: "host_offline", sessionId: "s_7" });
    phone.ws.close(1000);
    host.ws.close(1000);
  });

  it("isolates users and replaces a reconnecting host", async () => {
    const alice = await login();
    const bob = await login();
    const { hostId, hostToken } = await pairHost(alice.accessToken);
    const bobPhone = await connect(bob.accessToken);
    expect((await bobPhone.next((f) => f.type === "welcome")).hosts).toEqual([]);

    const alicePhone = await connect(alice.accessToken);
    await alicePhone.next((f) => f.type === "welcome");
    const host1 = await connect(hostToken);
    await alicePhone.next((f) => f.type === "presence" && f.online);

    // Bob cannot reach Alice's host.
    bobPhone.send({ type: "offer", to: hostId, sessionId: "s_x", sdp: "x" });
    expect(await bobPhone.next((f) => f.type === "error")).toMatchObject({ code: "host_offline" });

    const host2 = await connect(hostToken);
    await host1.waitClosed();
    expect(host1.closed?.code).toBe(4001);
    await alicePhone.next((f) => f.type === "presence" && f.online);
    alicePhone.send({ type: "offer", to: hostId, sessionId: "s_y", sdp: "x" });
    expect(await host2.next((f) => f.type === "offer")).toMatchObject({ sessionId: "s_y" });

    // Deleting the host disconnects it and tells phones.
    expect((await api("DELETE", `/v1/hosts/${hostId}`, { token: alice.accessToken })).status).toBe(200);
    await host2.waitClosed();
    expect(host2.closed?.code).toBe(4003);
    expect(await alicePhone.next((f) => f.type === "presence" && !f.online)).toMatchObject({ hostId, online: false });
    expect(bobPhone.frames.filter((f) => f.type === "presence")).toEqual([]);
    alicePhone.ws.close(1000);
    bobPhone.ws.close(1000);
  });

  it("closes phone sockets with 4002 when their access token expires", async () => {
    const user = await login();
    const { hostToken } = await pairHost(user.accessToken);
    const phone = await connect(user.accessToken);
    await phone.next((f) => f.type === "welcome");
    const host = await connect(hostToken);
    await host.next((f) => f.type === "welcome");

    const ns = (env as unknown as { SIGNAL_ROOM: DurableObjectNamespace }).SIGNAL_ROOM;
    const stub = ns.get(ns.idFromName(user.user.id));
    // The room armed an alarm for the phone token's expiry (15 min).
    const alarm = await runInDurableObject(stub, async (_i, state: DurableObjectState) => state.storage.getAlarm());
    expect(alarm).toEqual(expect.any(Number));
    expect(alarm! - Date.now()).toBeGreaterThan(14 * 60 * 1000);
    // Pretend the token expired, then fire the alarm.
    await runInDurableObject(stub, async (_i, state: DurableObjectState) => {
      for (const ws of state.getWebSockets("role:phone")) ws.serializeAttachment({ ...ws.deserializeAttachment(), expiresAt: Date.now() - 1 });
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    await phone.waitClosed();
    expect(phone.closed?.code).toBe(4002);
    // Hosts have no expiry and stay connected.
    expect(host.closed).toBeNull();
    host.ws.close(1000);
  });

  it("closes every socket with 4004 when the account is deleted", async () => {
    const user = await login();
    const { hostToken } = await pairHost(user.accessToken);
    const phone = await connect(user.accessToken);
    await phone.next((f) => f.type === "welcome");
    const host = await connect(hostToken);
    await host.next((f) => f.type === "welcome");
    expect((await api("DELETE", "/v1/me", { token: user.accessToken })).status).toBe(200);
    expect(await host.next((f) => f.type === "revoked")).toEqual({ type: "revoked", family: expect.stringMatching(/^rf_/) });
    await host.waitClosed();
    await phone.waitClosed();
    expect(host.closed?.code).toBe(4004);
    expect(phone.closed?.code).toBe(4004);
    // The deleted host token no longer authenticates.
    expect((await worker.fetch(`${BASE}/v1/signal`, { headers: { upgrade: "websocket", authorization: `Bearer ${hostToken}` } })).status).toBe(401);
  });

  it("tells hosts when a sign-in family is revoked (logout, reuse) and closes that family's phones with 4005", async () => {
    const user = await login();
    const { hostId, hostToken } = await pairHost(user.accessToken);
    const host = await connect(hostToken);
    await host.next((f) => f.type === "welcome");

    // Logout.
    const phone = await connect(user.accessToken);
    const welcome = await phone.next((f) => f.type === "welcome");
    phone.send({ type: "offer", to: hostId, sessionId: "s_l", sdp: "x" });
    const family = (await host.next((f) => f.type === "offer")).family;
    expect((await api("POST", "/v1/auth/logout", { token: user.accessToken, body: { refreshToken: user.refreshToken } })).status).toBe(200);
    expect(await host.next((f) => f.type === "revoked")).toEqual({ type: "revoked", family });
    await phone.waitClosed();
    expect(phone.closed?.code).toBe(4005);
    expect(welcome.peerId).toMatch(/^p_/);

    // Reuse detection on a second sign-in of the same account.
    const again = await api("POST", "/v1/auth/test", { body: { email: (await api("GET", "/v1/me", { token: user.accessToken })).json.user.email, secret: "test-login-secret" } });
    const rotated = await api("POST", "/v1/auth/refresh", { body: { refreshToken: again.json.refreshToken } });
    expect((await api("POST", "/v1/auth/refresh", { body: { refreshToken: rotated.json.refreshToken } })).status).toBe(200);
    // Replaying the first token after its successor rotated is reuse.
    expect((await api("POST", "/v1/auth/refresh", { body: { refreshToken: again.json.refreshToken } })).status).toBe(401);
    const revoked = await host.next((f) => f.type === "revoked");
    expect(revoked.family).not.toBe(family);
    expect(revoked.family).toMatch(/^rf_/);
    host.ws.close(1000);
  });
});
