import { openString, sealString, signEs256, verifyEs256Jws } from "./crypto";
import { HOST_RELAY_HEADER, ORIGIN_HEADER, SCOPE_HEADER, SESSION_DEVICE_HEADER, STACK_TOKEN_HEADER, STACK_TOKEN_SEAL_INFO, USER_HEADER, type Env } from "./env";
import { ApiError, badRequest, errorResponse, json, notFound, unauthorized } from "./errors";
import { STACK_API, allowedStackProjects, verifyStackAccessToken } from "./stack";

// The main module may export only handlers and Durable Object classes.

export { SessionDO } from "./sessionDo";
export { UserDO } from "./userDo";

const SESSION_TTL_S = 3600;
const SESSION_ISSUER = "device-hub";

const SESSION_WS = /^\/v1\/sessions\/([0-9a-f-]{36})\/ws$/;

/** Public origin for signalURL: PUBLIC_BASE_URL, else the request's own origin. */
function publicOrigin(env: Env, url: URL): string {
  const base = env.PUBLIC_BASE_URL?.trim();
  return (base ? base : url.origin).replace(/\/+$/, "");
}

async function readJson(request: Request): Promise<Record<string, unknown>> {
  try {
    const body = await request.json();
    if (body && typeof body === "object" && !Array.isArray(body)) return body as Record<string, unknown>;
  } catch {
    // fall through
  }
  throw badRequest("body must be a JSON object");
}

async function authStack(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (typeof body.token !== "string" || !body.token) throw badRequest("token is required");
  const now = Date.now();
  const { projectId, sub, exp: stackExp } = await verifyStackAccessToken(body.token, allowedStackProjects(env), env.STACK_API_URL || STACK_API, now);
  // Namespaced so users of different Stack projects (prod, dev) never share a User DO.
  const userId = `${projectId}:${sub}`;
  const iat = Math.floor(now / 1000);
  // The session ends with the Stack token it carries, so the relay check always
  // has a live token; the app exchanges a fresh one when the session ends.
  const exp = Math.min(iat + SESSION_TTL_S, Math.floor(stackExp));
  if (exp <= iat) throw unauthorized("access token expired");
  // The Stack token rides in the session only sealed (AES-GCM under a key
  // derived from SESSION_KEY): the cmux relay check asks cmux billing with it.
  const stk = await sealString(env.SESSION_KEY, STACK_TOKEN_SEAL_INFO, body.token);
  const session = await signEs256(env.SESSION_KEY, { iss: SESSION_ISSUER, sub: userId, iat, exp, stk });
  return json({ session, userId, stackUserId: sub, projectId, expiresAt: exp * 1000 });
}

/** The user ids /v1/auth/stack mints: `<projectId>:<sub>`. */
const USER_ID = /^[A-Za-z0-9_-]{1,100}:[A-Za-z0-9_-]{1,200}$/;

/**
 * Device-key renewal (PROTOCOL.md, Device renewal): an anchored macOS device
 * (cmux Remote, with the cmux app quit) signs `POST /v1/auth/device {userId}`
 * with its device key and gets a host-scoped session for an hour. No Stack
 * token is involved; the User DO checks the signature, the replay window and
 * the anchor.
 */
async function authDevice(request: Request, env: Env): Promise<Response> {
  const raw = new Uint8Array(await request.arrayBuffer());
  let userId: unknown;
  try {
    userId = (JSON.parse(new TextDecoder().decode(raw)) as Record<string, unknown>).userId;
  } catch {
    throw badRequest("body must be a JSON object");
  }
  if (typeof userId !== "string" || !USER_ID.test(userId)) throw badRequest("userId is required");
  const headers = new Headers();
  for (const name of ["x-device-id", "x-device-ts", "x-device-sig"]) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  const stub = env.USER_DO.get(env.USER_DO.idFromName(userId));
  const answer = await stub.fetch(new Request("https://user.do/internal/renew-device", { method: "POST", headers, body: raw }));
  if (!answer.ok) return answer;
  const { deviceId, relay } = (await answer.json()) as { deviceId: string; relay: boolean };
  const iat = Math.floor(Date.now() / 1000);
  const exp = iat + SESSION_TTL_S;
  const session = await signEs256(env.SESSION_KEY, { iss: SESSION_ISSUER, sub: userId, iat, exp, scp: "host", did: deviceId, rel: relay ? 1 : 0 });
  return json({ session, userId, scope: "host", expiresAt: exp * 1000 });
}

interface SessionClaims {
  userId: string;
  stackToken: string | null;
  /** `host` for a device-key renewal, else `full`. */
  scope: "full" | "host";
  device: string | null;
  hostRelay: boolean;
}

/** Verifies `Authorization: Bearer <session>`; returns the user id, the opened Stack token and the scope. */
async function requireSession(request: Request, env: Env): Promise<SessionClaims> {
  const auth = request.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(\S+)$/i.exec(auth);
  if (!m) throw unauthorized("missing session");
  const payload = await verifyEs256Jws(env.SESSION_KEY, m[1]!);
  if (!payload || payload.iss !== SESSION_ISSUER || typeof payload.sub !== "string" || !payload.sub) throw unauthorized("bad session");
  if (typeof payload.exp !== "number" || payload.exp * 1000 <= Date.now()) throw unauthorized("session expired");
  if (payload.scp === "host") {
    if (typeof payload.did !== "string" || !payload.did) throw unauthorized("bad session");
    return { userId: payload.sub, stackToken: null, scope: "host", device: payload.did, hostRelay: payload.rel === 1 };
  }
  // Sessions from before the relay check carry no Stack token. They still work
  // (the app's socket would otherwise stay refused until the session ends),
  // but get no cmux relay: the billing check fails closed without a token.
  // They are gone within the 1 h session lifetime.
  if (payload.stk === undefined) return { userId: payload.sub, stackToken: null, scope: "full", device: null, hostRelay: false };
  const stackToken = typeof payload.stk === "string" ? await openString(env.SESSION_KEY, STACK_TOKEN_SEAL_INFO, payload.stk) : null;
  if (!stackToken) throw unauthorized("bad session");
  return { userId: payload.sub, stackToken, scope: "full", device: null, hostRelay: false };
}

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;
  if (path === "/v1/health" && request.method === "GET") {
    return json({ ok: true, service: "device-hub", protocol: 1, time: Date.now() });
  }
  if (path === "/v1/auth/stack") {
    if (request.method !== "POST") throw new ApiError(405, "bad_request", "method not allowed");
    return authStack(request, env);
  }
  if (path === "/v1/auth/device") {
    if (request.method !== "POST") throw new ApiError(405, "bad_request", "method not allowed");
    return authDevice(request, env);
  }
  const ws = SESSION_WS.exec(path);
  if (ws) {
    // Admitted by the ticket and the device signature; the Session DO checks both.
    const headers = new Headers(request.headers);
    headers.delete(USER_HEADER);
    headers.delete(ORIGIN_HEADER);
    headers.delete(STACK_TOKEN_HEADER);
    headers.delete(SCOPE_HEADER);
    headers.delete(SESSION_DEVICE_HEADER);
    headers.delete(HOST_RELAY_HEADER);
    const stub = env.SESSION_DO.get(env.SESSION_DO.idFromName(ws[1]!));
    return stub.fetch(new Request(request.url, { method: request.method, headers }));
  }
  if (!path.startsWith("/v1/")) throw notFound();
  const { userId, stackToken, scope, device, hostRelay } = await requireSession(request, env);
  const headers = new Headers(request.headers);
  headers.set(USER_HEADER, userId);
  headers.set(SCOPE_HEADER, scope);
  if (device) headers.set(SESSION_DEVICE_HEADER, device);
  else headers.delete(SESSION_DEVICE_HEADER);
  headers.set(HOST_RELAY_HEADER, hostRelay ? "1" : "0");
  headers.set(ORIGIN_HEADER, publicOrigin(env, url));
  if (stackToken) headers.set(STACK_TOKEN_HEADER, stackToken);
  else headers.delete(STACK_TOKEN_HEADER);
  const stub = env.USER_DO.get(env.USER_DO.idFromName(userId));
  return stub.fetch(new Request(request.url, { method: request.method, headers, body: request.body }));
}

export default {
  async fetch(request, env) {
    try {
      return await route(request, env);
    } catch (err) {
      return errorResponse(err);
    }
  },
} satisfies ExportedHandler<Env>;
