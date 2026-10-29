import { env, exports as workerExports } from "cloudflare:workers";
import { expect, vi } from "vitest";
import { base64, base64url, sha256Hex } from "../src/crypto";
import type { Env } from "../src/env";

export const hubEnv = env as unknown as Env;
export const worker = (workerExports as unknown as { default: Fetcher }).default;
export const BASE = "https://hub.test";
export const STACK_PROJECT = "test-project";
export const STACK_DEV_PROJECT = "test-dev-project";
export const STACK_OTHER_PROJECT = "test-unlisted-project";
const enc = new TextEncoder();

// ---- outbound fetch mock (Stack JWKS, cmux billing, Cloudflare TURN) ----

/**
 * What the mocked cmux web backend answers on `GET /api/billing/plan` for a
 * Stack user (by `sub`): the plan fields, an HTTP status, a network failure, or
 * a hang. Users not listed are free.
 */
export type BillingAnswer =
  | { subscriptionPlanId?: string; teamPlanId?: string; authenticated?: boolean; userId?: string }
  | { status: number }
  | "network"
  | "hang"
  | "not-json";
export const billingPlans = new Map<string, BillingAnswer>();
/** Every billing request the hub made: the origin and the Stack token it sent. */
export const billingCalls: { origin: string; accessToken: string | null; sub: string | null }[] = [];

function jwtSub(token: string | null): string | null {
  try {
    const p = token!.split(".")[1]!;
    return JSON.parse(atob(p.replace(/-/g, "+").replace(/_/g, "/"))).sub ?? null;
  } catch {
    return null;
  }
}

async function billingResponse(origin: string, headers: Headers, signal: AbortSignal | null | undefined): Promise<Response> {
  let accessToken: string | null = null;
  try {
    accessToken = JSON.parse(headers.get("x-stack-auth") ?? "null")?.accessToken ?? null;
  } catch {
    accessToken = null;
  }
  const sub = jwtSub(accessToken);
  billingCalls.push({ origin, accessToken, sub });
  const answer: BillingAnswer = (sub && billingPlans.get(sub)) || {};
  if (answer === "network") throw new TypeError("network connection lost");
  if (answer === "hang") {
    return new Promise((_, reject) => {
      signal?.addEventListener("abort", () => reject(signal.reason ?? new Error("aborted")));
    });
  }
  if (answer === "not-json") return new Response("<html>oops</html>", { status: 200, headers: { "content-type": "text/html" } });
  if ("status" in answer) return Response.json({ error: "boom" }, { status: answer.status });
  if (!sub) return Response.json({ authenticated: false, planId: "free", subscriptionPlanId: "free", teamPlanId: "free", user: null });
  return Response.json({
    authenticated: answer.authenticated ?? true,
    planId: answer.subscriptionPlanId && answer.subscriptionPlanId !== "free" ? "pro" : "free",
    subscriptionPlanId: answer.subscriptionPlanId ?? "free",
    isPro: !!answer.subscriptionPlanId && answer.subscriptionPlanId !== "free",
    teamPlanId: answer.teamPlanId ?? "free",
    user: { id: answer.userId ?? sub, displayName: null, primaryEmail: null },
  });
}

let stackKeys: CryptoKeyPair | null = null;
export const outbound: string[] = [];

async function stackKeyPair(): Promise<CryptoKeyPair> {
  if (!stackKeys) stackKeys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  return stackKeys;
}

const realFetch = globalThis.fetch;
let mocked = false;
export function mockOutbound() {
  if (mocked) return;
  mocked = true;
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    outbound.push(url);
    const jwks = /^https:\/\/stack\.test\/api\/v1\/projects\/([^/]+)\/\.well-known\/jwks\.json$/.exec(url);
    if (jwks && [STACK_PROJECT, STACK_DEV_PROJECT, STACK_OTHER_PROJECT].includes(jwks[1]!)) {
      const jwk = await crypto.subtle.exportKey("jwk", (await stackKeyPair()).publicKey);
      return Response.json({ keys: [{ ...jwk, kid: "k1", alg: "ES256" }] });
    }
    const billing = /^(https:\/\/billing(?:-dev)?\.test)\/api\/billing\/plan$/.exec(url);
    if (billing) {
      // workerd throws on `redirect: "error"` (a deployed hub then never gets an answer).
      if (init?.redirect === "error") throw new TypeError("Invalid redirect value, must be one of \"follow\" or \"manual\"");
      const headers = new Headers(input instanceof Request ? input.headers : init?.headers);
      return billingResponse(billing[1]!, headers, init?.signal ?? (input instanceof Request ? input.signal : undefined));
    }
    if (url.startsWith("https://rtc.live.cloudflare.com/v1/turn/keys/turn-key/credentials/generate-ice-servers")) {
      return Response.json({
        iceServers: [
          { urls: ["stun:stun.cloudflare.com:3478"] },
          { urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"], username: "u1", credential: "c1" },
        ],
      });
    }
    return realFetch(input, init);
  });
}

export async function stackToken(claims: Record<string, unknown>, kid = "k1"): Promise<string> {
  const header = base64url(enc.encode(JSON.stringify({ alg: "ES256", kid })));
  const body = base64url(enc.encode(JSON.stringify(claims)));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, (await stackKeyPair()).privateKey, enc.encode(`${header}.${body}`));
  return `${header}.${body}.${base64url(new Uint8Array(sig))}`;
}

export function stackClaims(sub: string, extra: Record<string, unknown> = {}, project = STACK_PROJECT) {
  const now = Math.floor(Date.now() / 1000);
  return { iss: `https://stack.test/api/v1/projects/${project}`, aud: project, sub, iat: now, exp: now + 600, ...extra };
}

export async function rawCall(method: string, path: string, opts: { body?: unknown; headers?: Record<string, string> } = {}) {
  const headers: Record<string, string> = { ...(opts.headers ?? {}) };
  if (opts.body !== undefined) headers["content-type"] = "application/json";
  const res = await worker.fetch(`${BASE}${path}`, { method, headers, body: opts.body === undefined ? undefined : JSON.stringify(opts.body) });
  const text = await res.text();
  return { status: res.status, json: text ? (JSON.parse(text) as any) : null };
}

/** Signs in a fresh (or given) Stack user and returns the hub session. */
/** `sub` is the Stack user id; the returned `userId` is the hub's "<projectId>:<sub>". */
export async function signIn(sub = `user-${crypto.randomUUID()}`, project = STACK_PROJECT) {
  mockOutbound();
  const token = await stackToken(stackClaims(sub, {}, project));
  const res = await rawCall("POST", "/v1/auth/stack", { body: { token } });
  expect(res.status).toBe(200);
  return { userId: res.json.userId as string, session: res.json.session as string, stackToken: token, sub };
}

// ---- WebSocket peer ----

export class Peer {
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
    ws.accept();
  }

  next(pred: (f: any) => boolean = () => true, timeoutMs = 3000): Promise<any> {
    const i = this.frames.findIndex(pred);
    if (i >= 0) return Promise.resolve(this.frames.splice(i, 1)[0]);
    return new Promise((resolve, reject) => {
      const w = { pred, resolve: (f: any) => (clearTimeout(t), resolve(f)) };
      const t = setTimeout(() => {
        this.waiters.splice(this.waiters.indexOf(w), 1);
        reject(new Error(`timed out waiting for a frame; have ${JSON.stringify(this.frames)}`));
      }, timeoutMs);
      this.waiters.push(w);
    });
  }

  /** Returns true if no frame matching `pred` arrives within `ms`. */
  async none(pred: (f: any) => boolean, ms = 150): Promise<boolean> {
    try {
      await this.next(pred, ms);
      return false;
    } catch {
      return true;
    }
  }

  send(frame: unknown) {
    this.ws.send(typeof frame === "string" ? frame : JSON.stringify(frame));
  }

  waitClosed(timeoutMs = 3000): Promise<{ code: number; reason: string }> {
    if (this.closed) return Promise.resolve(this.closed);
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("socket did not close")), timeoutMs);
      this.closeWaiters.push(() => (clearTimeout(t), resolve(this.closed!)));
    });
  }
}

// ---- devices ----

export class Device {
  id = crypto.randomUUID();
  signing!: CryptoKeyPair;
  signingKey!: string;
  agreementKey!: string;
  user: Peer | null = null;

  private constructor(
    readonly account: { userId: string; session: string },
    readonly name: string,
    readonly platform: "macos" | "ios",
  ) {}

  static async create(account: { userId: string; session: string }, name = "Mac", platform: "macos" | "ios" = "macos") {
    const d = new Device(account, name, platform);
    d.signing = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
    d.signingKey = base64(new Uint8Array((await crypto.subtle.exportKey("raw", d.signing.publicKey)) as ArrayBuffer));
    const agreement = (await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"])) as CryptoKeyPair;
    d.agreementKey = base64(new Uint8Array((await crypto.subtle.exportKey("raw", agreement.publicKey)) as ArrayBuffer));
    return d;
  }

  async sign(message: string, key = this.signing.privateKey): Promise<string> {
    return base64(new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(message))));
  }

  async headers(method: string, pathAndQuery: string, bodyText: string, opts: { ts?: number; key?: CryptoKey; id?: string } = {}) {
    const ts = String(opts.ts ?? Math.floor(Date.now() / 1000));
    const bodyHash = bodyText ? await sha256Hex(bodyText) : "";
    const sig = await this.sign(`${method}\n${pathAndQuery}\n${ts}\n${bodyHash}`, opts.key);
    return { "x-device-id": opts.id ?? this.id, "x-device-ts": ts, "x-device-sig": sig };
  }

  /** A device-signed API call. `replay` reuses a prior call's headers verbatim. */
  async call(method: string, path: string, body?: unknown, opts: { ts?: number; key?: CryptoKey; headers?: Record<string, string>; session?: string; extraHeaders?: Record<string, string> } = {}) {
    const bodyText = body === undefined ? "" : JSON.stringify(body);
    const headers: Record<string, string> = { ...(opts.headers ?? (await this.headers(method, path, bodyText, opts))), ...(opts.extraHeaders ?? {}) };
    headers.authorization = `Bearer ${opts.session ?? this.account.session}`;
    if (body !== undefined) headers["content-type"] = "application/json";
    const res = await worker.fetch(`${BASE}${path}`, { method, headers, body: body === undefined ? undefined : bodyText });
    const text = await res.text();
    return { status: res.status, json: text ? (JSON.parse(text) as any) : null, headers };
  }

  async register() {
    const res = await this.call("POST", "/v1/devices", {
      id: this.id,
      name: this.name,
      platform: this.platform,
      signingKey: this.signingKey,
      agreementKey: this.agreementKey,
    });
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    return res;
  }

  async connect(): Promise<Peer> {
    const headers = { ...(await this.headers("GET", "/v1/user/ws", "")), authorization: `Bearer ${this.account.session}`, upgrade: "websocket" };
    const res = await worker.fetch(`${BASE}/v1/user/ws`, { headers });
    expect(res.status, await (res.status === 101 ? Promise.resolve("") : res.clone().text())).toBe(101);
    this.user = new Peer(res.webSocket!);
    return this.user;
  }

  async share(shared = true) {
    const res = await this.call("PUT", `/v1/devices/${this.id}/mac-screen`, { shared });
    expect(res.status).toBe(200);
  }

  /** Opens the signaling socket for a session.ticket push. Returns the HTTP status on failure. */
  async signal(ticketMsg: { signalURL: string; ticket: string }, opts: { ticket?: string; ts?: number; id?: string; key?: CryptoKey } = {}) {
    const u = new URL(ticketMsg.signalURL);
    const pathAndQuery = `${u.pathname}?ticket=${encodeURIComponent(opts.ticket ?? ticketMsg.ticket)}`;
    const headers = { ...(await this.headers("GET", pathAndQuery, "", opts)), upgrade: "websocket" };
    const res = await worker.fetch(`${BASE}${pathAndQuery}`, { headers });
    if (res.status !== 101) return { status: res.status, json: (await res.json()) as any, peer: null };
    return { status: 101, json: null, peer: new Peer(res.webSocket!) };
  }
}

/** One account with a shared, connected Mac host and a connected viewer. */
export async function setup(opts: { userId?: string; share?: boolean; account?: Awaited<ReturnType<typeof signIn>> } = {}) {
  const account = opts.account ?? (await signIn(opts.userId));
  const host = await Device.create(account, "Studio", "macos");
  const viewer = await Device.create(account, "Laptop", "macos");
  await host.register();
  await viewer.register();
  if (opts.share !== false) await host.share(true);
  await host.connect();
  await viewer.connect();
  return { account, host, viewer };
}

/** Viewer requests a session the host's permission auto-approves; returns both tickets. */
export async function approvedSession(host: Device, viewer: Device, scope: "view" | "full" = "view") {
  const perm = await host.call("PUT", `/v1/permissions/${host.id}/${viewer.id}`, { scope });
  expect(perm.status).toBe(200);
  const res = await viewer.call("POST", "/v1/sessions", { hostId: host.id, scope });
  expect(res.status, JSON.stringify(res.json)).toBe(200);
  expect(res.json.session.state).toBe("approved");
  const sid = res.json.session.id as string;
  const vt = await viewer.user!.next((f) => f.type === "session.ticket" && f.sessionId === sid);
  const ht = await host.user!.next((f) => f.type === "session.ticket" && f.sessionId === sid);
  return { sid, vt, ht };
}

export async function auditEvents(d: Device, sessionId?: string): Promise<string[]> {
  const res = await d.call("GET", "/v1/audit?limit=200");
  expect(res.status).toBe(200);
  return (res.json.entries as any[])
    .filter((e) => !sessionId || e.sessionId === sessionId)
    .map((e) => e.event)
    .reverse();
}

export async function waitFor<T>(fn: () => Promise<T>, pred: (v: T) => boolean, timeoutMs = 3000): Promise<T> {
  const start = Date.now();
  for (;;) {
    const v = await fn();
    if (pred(v)) return v;
    if (Date.now() - start > timeoutMs) throw new Error(`waitFor timed out: ${JSON.stringify(v)}`);
    await new Promise((r) => setTimeout(r, 20));
  }
}
