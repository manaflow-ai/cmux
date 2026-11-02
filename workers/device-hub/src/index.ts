import { openString, sealString, signEs256, verifyEs256Jws } from "./crypto";
import { ORIGIN_HEADER, STACK_TOKEN_HEADER, STACK_TOKEN_SEAL_INFO, USER_HEADER, type Env } from "./env";
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

/** Verifies `Authorization: Bearer <session>`; returns the user id and the opened Stack token. */
async function requireSession(request: Request, env: Env): Promise<{ userId: string; stackToken: string | null }> {
  const auth = request.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(\S+)$/i.exec(auth);
  if (!m) throw unauthorized("missing session");
  const payload = await verifyEs256Jws(env.SESSION_KEY, m[1]!);
  if (!payload || payload.iss !== SESSION_ISSUER || typeof payload.sub !== "string" || !payload.sub) throw unauthorized("bad session");
  if (typeof payload.exp !== "number" || payload.exp * 1000 <= Date.now()) throw unauthorized("session expired");
  // Sessions from before the relay check carry no Stack token. They still work
  // (the app's socket would otherwise stay refused until the session ends),
  // but get no cmux relay: the billing check fails closed without a token.
  // They are gone within the 1 h session lifetime.
  if (payload.stk === undefined) return { userId: payload.sub, stackToken: null };
  const stackToken = typeof payload.stk === "string" ? await openString(env.SESSION_KEY, STACK_TOKEN_SEAL_INFO, payload.stk) : null;
  if (!stackToken) throw unauthorized("bad session");
  return { userId: payload.sub, stackToken };
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
  const ws = SESSION_WS.exec(path);
  if (ws) {
    // Admitted by the ticket and the device signature; the Session DO checks both.
    const headers = new Headers(request.headers);
    headers.delete(USER_HEADER);
    headers.delete(ORIGIN_HEADER);
    headers.delete(STACK_TOKEN_HEADER);
    const stub = env.SESSION_DO.get(env.SESSION_DO.idFromName(ws[1]!));
    return stub.fetch(new Request(request.url, { method: request.method, headers }));
  }
  if (!path.startsWith("/v1/")) throw notFound();
  const { userId, stackToken } = await requireSession(request, env);
  const headers = new Headers(request.headers);
  headers.set(USER_HEADER, userId);
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
