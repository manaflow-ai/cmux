import { openString, sealString, signEs256, verifyEs256Jws } from "./crypto";
import { spaceOf, userObjectName } from "./buildSpace";
import { HOST_RELAY_HEADER, ORIGIN_HEADER, SCOPE_HEADER, SESSION_DEVICE_HEADER, SPACE_HEADER, STACK_TOKEN_HEADER, STACK_TOKEN_SEAL_INFO, USER_HEADER, type Env } from "./env";
import { ApiError, badRequest, errorResponse, json, notFound, unauthorized } from "./errors";
import { DEVICE_ID } from "./deviceAuth";
import { hubUserFor, recordPlatformAlias, verifyMachineCredential } from "./machine";
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

/** The session's build space claim (`bsp`): present only for a dev space, so a default-space session is as before. */
const spaceClaim = (space: string) => (space ? { bsp: space } : {});

async function authStack(request: Request, env: Env, space: string): Promise<Response> {
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
  const session = await signEs256(env.SESSION_KEY, { iss: SESSION_ISSUER, sub: userId, iat, exp, stk, ...spaceClaim(space) });
  // So a machine this person joins can sign in as them later (machine.ts). A failure only
  // delays that: the next sign-in records it.
  await recordPlatformAlias(env, projectId, sub).catch(() => undefined);
  return json({ session, userId, stackUserId: sub, projectId, expiresAt: exp * 1000 });
}

/**
 * Machine sign-in (PROTOCOL.md, Machine sign-in): a machine the person joined
 * to cmux signs in with its cmux-platform machine credential, `POST
 * /v1/auth/machine {credential, deviceId}`. The hub asks cmux-platform whose
 * it is (machine.ts) and answers a `machine` session for that one device: it
 * may register it and turn its sharing on or off, and otherwise only what a
 * host session may. It ends with the credential, at most in an hour, and
 * carries no Stack token, so it gets no cmux relay. It never anchors, so the
 * machine renews only by signing in again: cmux-platform is asked each time,
 * and a revoked credential's last session ends within the hour.
 */
async function authMachine(request: Request, env: Env, space: string): Promise<Response> {
  const body = await readJson(request);
  if (typeof body.credential !== "string" || !body.credential) throw badRequest("credential is required");
  if (typeof body.deviceId !== "string" || !DEVICE_ID.test(body.deviceId)) throw badRequest("deviceId is required");
  const now = Date.now();
  const machine = await verifyMachineCredential(body.credential, env, now);
  const userId = await hubUserFor(env, machine.projectId, machine.platformUserId);
  if (!userId) {
    throw new ApiError(403, "account_not_on_hub", "the person who joined this machine has not signed in to cmux screen sharing yet; sign in once in cmux on a Mac or iPhone, then join again");
  }
  const iat = Math.floor(now / 1000);
  const exp = Math.min(iat + SESSION_TTL_S, Math.floor(machine.expiresAt / 1000));
  if (exp <= iat) throw unauthorized("machine credential expired");
  const session = await signEs256(env.SESSION_KEY, { iss: SESSION_ISSUER, sub: userId, iat, exp, scp: "machine", did: body.deviceId, mid: machine.machineId, tid: machine.teamId, ...spaceClaim(space) });
  // The owner is the person who joined it (`ownerKind: "user"`): same-account is decided from
  // that authenticated owner, as for any of their devices.
  return json({ session, userId, scope: "machine", ownerKind: "user", machineId: machine.machineId, teamId: machine.teamId, expiresAt: exp * 1000 });
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
async function authDevice(request: Request, env: Env, space: string): Promise<Response> {
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
  // The User DO of the space that anchored this device: another space's never did.
  const stub = env.USER_DO.get(env.USER_DO.idFromName(userObjectName(space, userId)));
  const answer = await stub.fetch(new Request("https://user.do/internal/renew-device", { method: "POST", headers, body: raw }));
  if (!answer.ok) return answer;
  const { deviceId, relay } = (await answer.json()) as { deviceId: string; relay: boolean };
  const iat = Math.floor(Date.now() / 1000);
  const exp = iat + SESSION_TTL_S;
  const session = await signEs256(env.SESSION_KEY, { iss: SESSION_ISSUER, sub: userId, iat, exp, scp: "host", did: deviceId, rel: relay ? 1 : 0, ...spaceClaim(space) });
  return json({ session, userId, scope: "host", expiresAt: exp * 1000 });
}

interface SessionClaims {
  userId: string;
  /** The build space the session was signed in to (`bsp`; "" for the default space). */
  space: string;
  stackToken: string | null;
  /** `host` for a device-key renewal, `machine` for a machine sign-in, else `full`. */
  scope: "full" | "host" | "machine";
  device: string | null;
  hostRelay: boolean;
}

/**
 * Verifies `Authorization: Bearer <session>`; returns the user id, the opened Stack token and the scope.
 * The session must be of the request's build space (`space`): one signed in to another space, or to the default
 * space, is refused as an account refusal (401), so the app signs in again, with its own header.
 */
async function requireSession(request: Request, env: Env, space: string): Promise<SessionClaims> {
  const auth = request.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(\S+)$/i.exec(auth);
  if (!m) throw unauthorized("missing session");
  const payload = await verifyEs256Jws(env.SESSION_KEY, m[1]!);
  if (!payload || payload.iss !== SESSION_ISSUER || typeof payload.sub !== "string" || !payload.sub) throw unauthorized("bad session");
  if (typeof payload.exp !== "number" || payload.exp * 1000 <= Date.now()) throw unauthorized("session expired");
  if ((payload.bsp ?? "") !== space) throw unauthorized("this session is for another build space");
  if (payload.scp === "host") {
    if (typeof payload.did !== "string" || !payload.did) throw unauthorized("bad session");
    return { userId: payload.sub, space, stackToken: null, scope: "host", device: payload.did, hostRelay: payload.rel === 1 };
  }
  if (payload.scp === "machine") {
    if (typeof payload.did !== "string" || !payload.did) throw unauthorized("bad session");
    return { userId: payload.sub, space, stackToken: null, scope: "machine", device: payload.did, hostRelay: false };
  }
  // Sessions from before the relay check carry no Stack token. They still work
  // (the app's socket would otherwise stay refused until the session ends),
  // but get no cmux relay: the billing check fails closed without a token.
  // They are gone within the 1 h session lifetime.
  if (payload.stk === undefined) return { userId: payload.sub, space, stackToken: null, scope: "full", device: null, hostRelay: false };
  const stackToken = typeof payload.stk === "string" ? await openString(env.SESSION_KEY, STACK_TOKEN_SEAL_INFO, payload.stk) : null;
  if (!stackToken) throw unauthorized("bad session");
  return { userId: payload.sub, space, stackToken, scope: "full", device: null, hostRelay: false };
}

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;
  if (path === "/v1/health" && request.method === "GET") {
    return json({ ok: true, service: "device-hub", protocol: 1, time: Date.now() });
  }
  // Before auth or any read: a malformed space, or a dev space on a hub that serves none, ends here.
  const space = spaceOf(request, env);
  if (path === "/v1/auth/stack") {
    if (request.method !== "POST") throw new ApiError(405, "bad_request", "method not allowed");
    return authStack(request, env, space);
  }
  if (path === "/v1/auth/device") {
    if (request.method !== "POST") throw new ApiError(405, "bad_request", "method not allowed");
    return authDevice(request, env, space);
  }
  if (path === "/v1/auth/machine") {
    if (request.method !== "POST") throw new ApiError(405, "bad_request", "method not allowed");
    return authMachine(request, env, space);
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
    headers.delete(SPACE_HEADER);
    const stub = env.SESSION_DO.get(env.SESSION_DO.idFromName(ws[1]!));
    return stub.fetch(new Request(request.url, { method: request.method, headers }));
  }
  if (!path.startsWith("/v1/")) throw notFound();
  const { userId, stackToken, scope, device, hostRelay } = await requireSession(request, env, space);
  const headers = new Headers(request.headers);
  headers.set(USER_HEADER, userId);
  headers.set(SPACE_HEADER, space);
  headers.set(SCOPE_HEADER, scope);
  if (device) headers.set(SESSION_DEVICE_HEADER, device);
  else headers.delete(SESSION_DEVICE_HEADER);
  headers.set(HOST_RELAY_HEADER, hostRelay ? "1" : "0");
  headers.set(ORIGIN_HEADER, publicOrigin(env, url));
  if (stackToken) headers.set(STACK_TOKEN_HEADER, stackToken);
  else headers.delete(STACK_TOKEN_HEADER);
  // The space's own User DO: a dev build's devices, sessions and audit never mix with another build's.
  const stub = env.USER_DO.get(env.USER_DO.idFromName(userObjectName(space, userId)));
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
