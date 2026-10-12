// cmux-next-native signaling Worker.
// Contract: native-mobile/ARCHITECTURE.md, "Signaling (Worker)".
import { connect, type Connection } from "@planetscale/database";
import { HostSignal } from "./signal";

export { HostSignal };

export interface Env {
  HOST_SIGNAL: DurableObjectNamespace;
  APPLE_AUDIENCES: string;
  DB_HOST: string;
  DB_USERNAME: string;
  DB_PASSWORD: string;
  TURN_KEY_ID: string;
  TURN_KEY_API_TOKEN: string;
  DEV_LOGIN_SECRET: string;
}

const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const PAIRING_TTL_MS = 10 * 60 * 1000;
const ICE_TTL_S = 86400;
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

// ---------- helpers ----------

class HttpError extends Error {
  constructor(public status: number, public code: string, message?: string) {
    super(message ?? code);
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

export function db(env: Env): Connection {
  return connect({ host: env.DB_HOST, username: env.DB_USERNAME, password: env.DB_PASSWORD });
}

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function randomId(): string {
  return hex(crypto.getRandomValues(new Uint8Array(16)));
}

function randomToken(): string {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sha256Hex(s: string): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))));
}

async function safeEqual(a: string, b: string): Promise<boolean> {
  const [ha, hb] = await Promise.all([sha256Hex(a), sha256Hex(b)]);
  let diff = 0;
  for (let i = 0; i < ha.length; i++) diff |= ha.charCodeAt(i) ^ hb.charCodeAt(i);
  return diff === 0 && a.length === b.length;
}

async function readJson(req: Request): Promise<Record<string, unknown>> {
  try {
    const v = await req.json();
    if (v && typeof v === "object" && !Array.isArray(v)) return v as Record<string, unknown>;
  } catch {}
  throw new HttpError(400, "bad_json", "request body must be a JSON object");
}

function str(body: Record<string, unknown>, key: string, max = 255, required = true): string | undefined {
  const v = body[key];
  if (v === undefined || v === null || v === "") {
    if (required) throw new HttpError(400, "missing_field", `${key} is required`);
    return undefined;
  }
  if (typeof v !== "string" || v.length > max) throw new HttpError(400, "bad_field", `${key} must be a string`);
  return v;
}

function bearer(req: Request, allowQuery = false): string | null {
  const h = req.headers.get("authorization");
  if (h && /^bearer\s+/i.test(h)) return h.replace(/^bearer\s+/i, "").trim() || null;
  if (allowQuery) return new URL(req.url).searchParams.get("token");
  return null;
}

function newPairingCode(): string {
  const b = crypto.getRandomValues(new Uint8Array(8));
  return Array.from(b, (x) => CROCKFORD[x & 31]).join("");
}

function formatCode(code: string): string {
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

function normalizeCode(input: string): string {
  return input
    .toUpperCase()
    .replace(/[\s-]/g, "")
    .replace(/O/g, "0")
    .replace(/[IL]/g, "1");
}

// ---------- auth ----------

interface User {
  id: string;
  email: string | null;
  display_name: string | null;
  created_at: number;
}

interface HostRow {
  id: string;
  user_id: string | null;
  name: string;
  platform: string;
  created_at: number;
  paired_at: number | null;
  last_seen: number | null;
}

function userJson(u: User) {
  return { id: u.id, email: u.email, display_name: u.display_name, created_at: Number(u.created_at) };
}

async function userFromToken(env: Env, token: string | null): Promise<User | null> {
  if (!token) return null;
  const hash = await sha256Hex(token);
  const r = await db(env).execute(
    "SELECT u.id, u.email, u.display_name, u.created_at FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ? AND s.expires_at > ?",
    [hash, Date.now()],
  );
  return (r.rows[0] as User | undefined) ?? null;
}

async function hostFromSecret(env: Env, secret: string | null): Promise<HostRow | null> {
  if (!secret) return null;
  const hash = await sha256Hex(secret);
  const r = await db(env).execute(
    "SELECT id, user_id, name, platform, created_at, paired_at, last_seen FROM hosts WHERE secret_hash = ?",
    [hash],
  );
  return (r.rows[0] as HostRow | undefined) ?? null;
}

async function requireUser(env: Env, req: Request): Promise<User> {
  const u = await userFromToken(env, bearer(req));
  if (!u) throw new HttpError(401, "unauthorized", "valid session token required");
  return u;
}

async function requireHost(env: Env, req: Request): Promise<HostRow> {
  const h = await hostFromSecret(env, bearer(req));
  if (!h) throw new HttpError(401, "unauthorized", "valid host secret required");
  return h;
}

async function createSession(env: Env, userId: string): Promise<{ token: string; expires_at: number }> {
  const token = randomToken();
  const now = Date.now();
  const expires_at = now + SESSION_TTL_MS;
  await db(env).execute("INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)", [
    await sha256Hex(token),
    userId,
    now,
    expires_at,
  ]);
  return { token, expires_at };
}

// ---------- Apple identity token ----------

interface Jwk extends JsonWebKey {
  kid: string;
}
let appleKeys: { keys: Jwk[]; fetchedAt: number } | null = null;

async function appleJwks(force = false): Promise<Jwk[]> {
  if (!force && appleKeys && Date.now() - appleKeys.fetchedAt < 6 * 3600 * 1000) return appleKeys.keys;
  const r = await fetch("https://appleid.apple.com/auth/keys");
  if (!r.ok) throw new HttpError(502, "apple_keys_unavailable");
  const body = (await r.json()) as { keys: Jwk[] };
  appleKeys = { keys: body.keys, fetchedAt: Date.now() };
  return body.keys;
}

function b64urlDecode(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

interface AppleClaims {
  iss: string;
  aud: string | string[];
  exp: number;
  iat: number;
  sub: string;
  email?: string;
}

async function verifyAppleToken(env: Env, token: string): Promise<AppleClaims> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new HttpError(401, "invalid_token");
  let header: { alg: string; kid: string };
  let claims: AppleClaims;
  try {
    header = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[0])));
    claims = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[1])));
  } catch {
    throw new HttpError(401, "invalid_token");
  }
  if (header.alg !== "RS256") throw new HttpError(401, "invalid_token", "unsupported alg");
  let jwk = (await appleJwks()).find((k) => k.kid === header.kid);
  if (!jwk) jwk = (await appleJwks(true)).find((k) => k.kid === header.kid);
  if (!jwk) throw new HttpError(401, "invalid_token", "unknown key id");
  const key = await crypto.subtle.importKey(
    "jwk",
    { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    b64urlDecode(parts[2]),
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  if (!ok) throw new HttpError(401, "invalid_token", "bad signature");
  const now = Math.floor(Date.now() / 1000);
  if (claims.iss !== "https://appleid.apple.com") throw new HttpError(401, "invalid_token", "bad issuer");
  const audiences = (env.APPLE_AUDIENCES || "dev.cmux.next.native,dev.cmux.next.native.dev")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  const auds = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!auds.some((a) => audiences.includes(a))) throw new HttpError(401, "invalid_token", "bad audience");
  if (typeof claims.exp !== "number" || claims.exp + 60 < now) throw new HttpError(401, "invalid_token", "expired");
  if (typeof claims.iat === "number" && claims.iat - 300 > now) throw new HttpError(401, "invalid_token", "issued in future");
  if (!claims.sub) throw new HttpError(401, "invalid_token", "missing sub");
  return claims;
}

// ---------- handlers ----------

async function authApple(env: Env, req: Request): Promise<Response> {
  const body = await readJson(req);
  const claims = await verifyAppleToken(env, str(body, "identity_token", 8192)!);
  const displayName = str(body, "display_name", 255, false) ?? null;
  const conn = db(env);
  const existing = await conn.execute("SELECT id, email, display_name, created_at FROM users WHERE apple_sub = ?", [claims.sub]);
  let user = existing.rows[0] as User | undefined;
  if (!user) {
    const id = randomId();
    const now = Date.now();
    const email = claims.email?.toLowerCase() ?? null;
    try {
      await conn.execute("INSERT INTO users (id, apple_sub, email, display_name, created_at) VALUES (?, ?, ?, ?, ?)", [
        id,
        claims.sub,
        email,
        displayName,
        now,
      ]);
      user = { id, email, display_name: displayName, created_at: now };
    } catch {
      // Email already bound to another account: create without email.
      await conn.execute("INSERT INTO users (id, apple_sub, email, display_name, created_at) VALUES (?, ?, NULL, ?, ?)", [
        id,
        claims.sub,
        displayName,
        now,
      ]);
      user = { id, email: null, display_name: displayName, created_at: now };
    }
  } else if (displayName && !user.display_name) {
    await conn.execute("UPDATE users SET display_name = ? WHERE id = ?", [displayName, user.id]);
    user.display_name = displayName;
  }
  const s = await createSession(env, user.id);
  return json({ user: userJson(user), session_token: s.token, expires_at: s.expires_at });
}

async function authDev(env: Env, req: Request): Promise<Response> {
  const body = await readJson(req);
  const email = str(body, "email", 320)!.trim().toLowerCase();
  const secret = str(body, "secret", 1024)!;
  if (!env.DEV_LOGIN_SECRET || !(await safeEqual(secret, env.DEV_LOGIN_SECRET))) {
    throw new HttpError(403, "forbidden", "dev login not allowed");
  }
  if (!/^[a-z0-9._+-]+@test\.cmux\.dev$/.test(email)) throw new HttpError(403, "forbidden", "dev login not allowed");
  const conn = db(env);
  let user = (await conn.execute("SELECT id, email, display_name, created_at FROM users WHERE email = ?", [email]))
    .rows[0] as User | undefined;
  if (!user) {
    const id = randomId();
    const now = Date.now();
    await conn.execute("INSERT INTO users (id, email, display_name, created_at) VALUES (?, ?, ?, ?)", [
      id,
      email,
      email.split("@")[0],
      now,
    ]);
    user = { id, email, display_name: email.split("@")[0], created_at: now };
  }
  const s = await createSession(env, user.id);
  return json({ user: userJson(user), session_token: s.token, expires_at: s.expires_at });
}

async function issuePairingCode(env: Env, hostId: string): Promise<{ code: string; expires_at: number }> {
  const conn = db(env);
  await conn.execute("DELETE FROM pairing_codes WHERE host_id = ? OR expires_at < ?", [hostId, Date.now() - PAIRING_TTL_MS]);
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = newPairingCode();
    const now = Date.now();
    try {
      await conn.execute("INSERT INTO pairing_codes (code, host_id, created_at, expires_at) VALUES (?, ?, ?, ?)", [
        code,
        hostId,
        now,
        now + PAIRING_TTL_MS,
      ]);
      return { code: formatCode(code), expires_at: now + PAIRING_TTL_MS };
    } catch {
      // primary key collision, retry
    }
  }
  throw new HttpError(500, "pairing_code_failed");
}

async function registerHost(env: Env, req: Request): Promise<Response> {
  const body = await readJson(req);
  const name = str(body, "name", 255)!;
  const platform = str(body, "platform", 64)!;
  // Optional: a signed-in user registering a host owns it immediately.
  const user = await userFromToken(env, bearer(req));
  const id = randomId();
  const secret = randomToken();
  const now = Date.now();
  await db(env).execute(
    "INSERT INTO hosts (id, user_id, name, platform, secret_hash, created_at, paired_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    [id, user?.id ?? null, name, platform, await sha256Hex(secret), now, user ? now : null],
  );
  const pc = await issuePairingCode(env, id);
  return json({ host_id: id, host_secret: secret, pairing_code: pc.code, pairing_expires_at: pc.expires_at }, 201);
}

async function hostPairingCode(env: Env, req: Request): Promise<Response> {
  const host = await requireHost(env, req);
  const pc = await issuePairingCode(env, host.id);
  return json({ pairing_code: pc.code, expires_at: pc.expires_at });
}

async function presence(env: Env, hostId: string): Promise<{ online: boolean; last_seen: number | null }> {
  const stub = env.HOST_SIGNAL.get(env.HOST_SIGNAL.idFromName(hostId));
  const r = await stub.fetch(`https://signal/presence?host_id=${hostId}`);
  return (await r.json()) as { online: boolean; last_seen: number | null };
}

async function hostJson(env: Env, h: HostRow) {
  let p: { online: boolean; last_seen: number | null } = { online: false, last_seen: null };
  try {
    p = await presence(env, h.id);
  } catch {}
  const dbSeen = h.last_seen === null ? null : Number(h.last_seen);
  return {
    id: h.id,
    name: h.name,
    platform: h.platform,
    created_at: Number(h.created_at),
    paired_at: h.paired_at === null ? null : Number(h.paired_at),
    online: p.online,
    last_seen: p.last_seen ?? dbSeen,
  };
}

async function pair(env: Env, req: Request): Promise<Response> {
  const user = await requireUser(env, req);
  const body = await readJson(req);
  const code = normalizeCode(str(body, "code", 32)!);
  if (!/^[0-9A-HJKMNP-TV-Z]{8}$/.test(code)) throw new HttpError(400, "bad_code", "code must be 8 Crockford base32 symbols");
  const conn = db(env);
  const now = Date.now();
  const claimed = await conn.execute(
    "UPDATE pairing_codes SET used_at = ? WHERE code = ? AND used_at IS NULL AND expires_at > ?",
    [now, code, now],
  );
  if (claimed.rowsAffected !== 1) throw new HttpError(404, "invalid_code", "pairing code is invalid, used or expired");
  const row = (await conn.execute("SELECT host_id FROM pairing_codes WHERE code = ?", [code])).rows[0] as
    | { host_id: string }
    | undefined;
  if (!row) throw new HttpError(404, "invalid_code");
  const previous = (await conn.execute("SELECT user_id FROM hosts WHERE id = ?", [row.host_id])).rows[0] as
    | { user_id: string | null }
    | undefined;
  if (!previous) throw new HttpError(404, "host_not_found");
  await conn.execute("UPDATE hosts SET user_id = ?, paired_at = ? WHERE id = ?", [user.id, now, row.host_id]);
  if (previous.user_id && previous.user_id !== user.id) await kickUser(env, row.host_id, previous.user_id);
  const host = (await conn.execute(
    "SELECT id, user_id, name, platform, created_at, paired_at, last_seen FROM hosts WHERE id = ?",
    [row.host_id],
  )).rows[0] as HostRow;
  return json({ host: await hostJson(env, host) });
}

async function listHosts(env: Env, req: Request): Promise<Response> {
  const user = await requireUser(env, req);
  const r = await db(env).execute(
    "SELECT id, user_id, name, platform, created_at, paired_at, last_seen FROM hosts WHERE user_id = ? ORDER BY created_at",
    [user.id],
  );
  const hosts = await Promise.all((r.rows as HostRow[]).map((h) => hostJson(env, h)));
  return json({ hosts });
}

async function kickUser(env: Env, hostId: string, userId: string): Promise<void> {
  const stub = env.HOST_SIGNAL.get(env.HOST_SIGNAL.idFromName(hostId));
  await stub.fetch(`https://signal/kick?user_id=${userId}`, { method: "POST" });
}

async function unpairHost(env: Env, req: Request, hostId: string): Promise<Response> {
  const user = await requireUser(env, req);
  const r = await db(env).execute("UPDATE hosts SET user_id = NULL, paired_at = NULL WHERE id = ? AND user_id = ?", [
    hostId,
    user.id,
  ]);
  if (r.rowsAffected !== 1) throw new HttpError(404, "host_not_found");
  await kickUser(env, hostId, user.id);
  return json({ ok: true });
}

async function ice(env: Env, req: Request): Promise<Response> {
  const token = bearer(req);
  const ok = (await userFromToken(env, token)) ?? (await hostFromSecret(env, token));
  if (!ok) throw new HttpError(401, "unauthorized");
  const r = await fetch(
    `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate-ice-servers`,
    {
      method: "POST",
      headers: { authorization: `Bearer ${env.TURN_KEY_API_TOKEN}`, "content-type": "application/json" },
      body: JSON.stringify({ ttl: ICE_TTL_S }),
    },
  );
  if (!r.ok) throw new HttpError(502, "turn_unavailable", `TURN credential service returned ${r.status}`);
  const body = (await r.json()) as { iceServers: RTCIceServerLike | RTCIceServerLike[] };
  const servers = Array.isArray(body.iceServers) ? body.iceServers : [body.iceServers];
  const hasStun = servers.some((s) => [s.urls].flat().includes("stun:stun.cloudflare.com:3478"));
  const iceServers = hasStun ? servers : [{ urls: ["stun:stun.cloudflare.com:3478"] }, ...servers];
  return json({ iceServers, ttl: ICE_TTL_S, expires_at: Date.now() + ICE_TTL_S * 1000 });
}

interface RTCIceServerLike {
  urls: string | string[];
  username?: string;
  credential?: string;
}

async function pushRegister(env: Env, req: Request): Promise<Response> {
  const user = await requireUser(env, req);
  const body = await readJson(req);
  const token = str(body, "apns_token", 255)!;
  const environment = str(body, "environment", 16, false) ?? "production";
  if (environment !== "production" && environment !== "sandbox") throw new HttpError(400, "bad_field", "environment");
  const bundleId = str(body, "bundle_id", 255, false) ?? null;
  const now = Date.now();
  await db(env).execute(
    "INSERT INTO devices (id, user_id, apns_token, environment, bundle_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) " +
      "ON DUPLICATE KEY UPDATE user_id = VALUES(user_id), environment = VALUES(environment), bundle_id = VALUES(bundle_id), updated_at = VALUES(updated_at)",
    [randomId(), user.id, token, environment, bundleId, now, now],
  );
  return json({ ok: true });
}

async function signal(env: Env, req: Request, hostId: string): Promise<Response> {
  if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") throw new HttpError(426, "upgrade_required");
  if (!/^[0-9a-f]{32}$/.test(hostId)) throw new HttpError(404, "host_not_found");
  const token = bearer(req, true);
  let role: "host" | "phone";
  let userId = "";
  const host = await hostFromSecret(env, token);
  if (host) {
    if (host.id !== hostId) throw new HttpError(403, "forbidden", "host secret does not match host id");
    role = "host";
  } else {
    const user = await userFromToken(env, token);
    if (!user) throw new HttpError(401, "unauthorized");
    const owned = await db(env).execute("SELECT id FROM hosts WHERE id = ? AND user_id = ?", [hostId, user.id]);
    if (owned.rows.length !== 1) throw new HttpError(403, "forbidden", "host is not paired with this user");
    role = "phone";
    userId = user.id;
  }
  const headers = new Headers(req.headers);
  headers.set("x-signal-role", role);
  headers.set("x-signal-user", userId);
  headers.set("x-signal-host", hostId);
  const stub = env.HOST_SIGNAL.get(env.HOST_SIGNAL.idFromName(hostId));
  return stub.fetch(new Request("https://signal/connect", { headers }));
}

// ---------- router ----------

async function route(req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url);
  const p = url.pathname.replace(/\/+$/, "") || "/";
  const m = req.method;
  if (p === "/healthz" && m === "GET") return json({ ok: true, service: "cmux-next-native" });
  if (p === "/v1/auth/apple" && m === "POST") return authApple(env, req);
  if (p === "/v1/auth/dev" && m === "POST") return authDev(env, req);
  if (p === "/v1/me" && m === "GET") return json({ user: userJson(await requireUser(env, req)) });
  if (p === "/v1/hosts/register" && m === "POST") return registerHost(env, req);
  if (p === "/v1/hosts/pairing-code" && m === "POST") return hostPairingCode(env, req);
  if (p === "/v1/hosts" && m === "GET") return listHosts(env, req);
  const hostMatch = p.match(/^\/v1\/hosts\/([0-9a-f]{32})$/);
  if (hostMatch && m === "DELETE") return unpairHost(env, req, hostMatch[1]);
  if (p === "/v1/pair" && m === "POST") return pair(env, req);
  if (p === "/v1/ice" && m === "GET") return ice(env, req);
  if (p === "/v1/push/register" && m === "POST") return pushRegister(env, req);
  const sig = p.match(/^\/v1\/signal\/([^/]+)$/);
  if (sig && m === "GET") return signal(env, req, sig[1]);
  throw new HttpError(404, "not_found");
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    try {
      return await route(req, env);
    } catch (e) {
      if (e instanceof HttpError) return json({ error: { code: e.code, message: e.message } }, e.status);
      console.error("unhandled", e instanceof Error ? e.stack : String(e));
      return json({ error: { code: "internal", message: "internal error" } }, 500);
    }
  },
} satisfies ExportedHandler<Env>;
