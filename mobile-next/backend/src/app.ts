// HTTP API. `handle` is pure with respect to its dependencies so tests can
// inject a fake database.
import { AppleTokenError, verifyAppleIdentityToken } from "./apple";
import {
  generateEmailCode,
  generatePairingCode,
  generateToken,
  normalizePairingCode,
  PAIRING_CODE_LENGTH,
  sha256Hex,
  timingSafeEqual,
} from "./crypto";
import { iso, type Db } from "./db";
import { sendCode } from "./email";
import type { Env } from "./env";
import {
  errorResponse,
  HttpError,
  json,
  optionalString,
  readJson,
  requireString,
  Router,
} from "./http";
import { iceServers } from "./ice";
import { signAccessToken, verifyAccessToken } from "./jwt";
import { consume, isLocked, recordFailure } from "./ratelimit";

const ACCESS_TTL = 60 * 60;
const REFRESH_TTL_MS = 90 * 24 * 60 * 60 * 1000;
const EMAIL_CODE_TTL_MS = 10 * 60 * 1000;
const PAIRING_TTL_MS = 10 * 60 * 1000;
const MAX_CODE_ATTEMPTS = 5;
const EMAIL_STARTS_PER_EMAIL_10M = 5;
const EMAIL_STARTS_PER_IP_1H = 30;
const PAIRING_STARTS_PER_IP_1H = 30;
const MIN_10 = 10 * 60 * 1000;
const HOUR = 60 * 60 * 1000;
const EMAIL_VERIFIES_PER_IP_10M = 30;
const TEST_CODE_FAILURES_BEFORE_LOCK_1H = 30;
const CLAIMS_PER_USER_10M = 10;
const CLAIMS_PER_IP_10M = 30;
const CLAIM_FAILURES_BEFORE_LOCK_1H = 20;
const ICE_PER_PRINCIPAL_1H = 60;
/** After approval the Mac has this long to collect the host token. */
const APPROVED_TTL_MS = 10 * 60 * 1000;
const LAST_SEEN_RESOLUTION_MS = 5 * 60 * 1000;

export interface Deps {
  db: Db;
  /** Host ids with a live signaling socket for this user. */
  onlineHostIds(userId: string): Promise<string[]>;
  /** Closes sockets for a host (or every socket when hostId is null). */
  disconnect(userId: string, hostId: string | null): Promise<void>;
  /** Forwards an authenticated WebSocket upgrade to the user's room. */
  connectSignal(userId: string, request: Request): Promise<Response>;
}

export type Principal =
  | { kind: "user"; userId: string }
  | { kind: "host"; userId: string; hostId: string; hostName: string };

interface Ctx {
  request: Request;
  url: URL;
  env: Env;
  deps: Deps;
  ip: string | null;
}

interface UserRow {
  id: string;
  email: string | null;
  display_name: string | null;
  created_at: string;
}

interface HostRow {
  id: string;
  user_id: string;
  name: string;
  platform: string;
  app_version: string;
  created_at: string;
  last_seen_at: string | null;
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function normalizeEmail(raw: string): string {
  const email = raw.trim().toLowerCase();
  if (email.length > 320 || !EMAIL_RE.test(email)) throw new HttpError(400, "invalid_email");
  return email;
}

function isTestDomain(env: Env, email: string): boolean {
  return email.endsWith(`@${env.TEST_EMAIL_DOMAIN}`);
}

/** Exact allowlisted test address that signs in with TEST_LOGIN_CODE. */
function isTestLogin(env: Env, email: string): boolean {
  if (!env.TEST_LOGIN_CODE || !isTestDomain(env, email)) return false;
  const allowed = (env.TEST_LOGIN_EMAILS ?? "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
  return allowed.includes(email);
}

function userJson(u: UserRow) {
  return { id: u.id, email: u.email, display_name: u.display_name, created_at: iso(u.created_at) };
}

function hostJson(h: HostRow, online: Set<string>) {
  return {
    id: h.id,
    name: h.name,
    platform: h.platform,
    app_version: h.app_version,
    created_at: iso(h.created_at),
    last_seen_at: iso(h.last_seen_at),
    online: online.has(h.id),
  };
}

function bearer(request: Request): string | null {
  const h = request.headers.get("authorization");
  if (!h) return null;
  const m = /^Bearer\s+(.+)$/i.exec(h);
  return m ? m[1]!.trim() : null;
}

export async function authenticate(env: Env, db: Db, token: string | null | undefined): Promise<Principal | null> {
  if (!token) return null;
  if (token.startsWith("cnh_")) {
    const hash = await sha256Hex(token);
    const host = await db.one<HostRow>("SELECT * FROM hosts WHERE token_hash = ?", [hash]);
    if (!host) return null;
    const now = new Date();
    const stale = new Date(now.getTime() - LAST_SEEN_RESOLUTION_MS);
    await db.exec(
      "UPDATE hosts SET last_seen_at = ? WHERE id = ? AND (last_seen_at IS NULL OR last_seen_at < ?)",
      [now, host.id, stale],
    );
    return { kind: "host", userId: host.user_id, hostId: host.id, hostName: host.name };
  }
  const claims = await verifyAccessToken(env.JWT_SECRET, token);
  return claims ? { kind: "user", userId: claims.sub } : null;
}

async function requirePrincipal(ctx: Ctx, kinds: Principal["kind"][]): Promise<Principal> {
  const p = await authenticate(ctx.env, ctx.deps.db, bearer(ctx.request));
  if (!p || !kinds.includes(p.kind)) throw new HttpError(401, "unauthorized");
  return p;
}

async function requireUser(ctx: Ctx): Promise<{ principal: Principal; user: UserRow }> {
  const principal = await requirePrincipal(ctx, ["user"]);
  const user = await ctx.deps.db.one<UserRow>("SELECT * FROM users WHERE id = ?", [principal.userId]);
  if (!user) throw new HttpError(401, "unauthorized", "account no longer exists");
  return { principal, user };
}

async function issueSession(ctx: Ctx, user: UserRow, isNewUser: boolean) {
  const access = await signAccessToken(ctx.env.JWT_SECRET, user.id, ACCESS_TTL);
  const refresh = generateToken("cnr");
  const now = new Date();
  await ctx.deps.db.exec(
    "INSERT INTO refresh_tokens (id, user_id, token_hash, created_at, expires_at) VALUES (?, ?, ?, ?, ?)",
    [crypto.randomUUID(), user.id, await sha256Hex(refresh), now, new Date(now.getTime() + REFRESH_TTL_MS)],
  );
  return json({
    access_token: access.token,
    access_expires_at: new Date(access.expiresAt * 1000).toISOString(),
    refresh_token: refresh,
    user: userJson(user),
    is_new_user: isNewUser,
  });
}

/** Finds the user for an identity, linking or creating as needed. */
async function upsertIdentity(
  db: Db,
  provider: "email" | "apple",
  subject: string,
  email: string | null,
  displayName: string | null,
): Promise<{ user: UserRow; isNew: boolean }> {
  const identity = await db.one<{ user_id: string }>(
    "SELECT user_id FROM auth_identities WHERE provider = ? AND subject = ?",
    [provider, subject],
  );
  if (identity) {
    const user = await db.one<UserRow>("SELECT * FROM users WHERE id = ?", [identity.user_id]);
    if (user) return { user, isNew: false };
  }
  const now = new Date();
  let user = email ? await db.one<UserRow>("SELECT * FROM users WHERE email = ?", [email]) : null;
  let isNew = false;
  if (!user) {
    const id = crypto.randomUUID();
    await db.exec(
      "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      [id, email, displayName, now, now],
    );
    user = (await db.one<UserRow>("SELECT * FROM users WHERE id = ?", [id]))!;
    isNew = true;
  }
  await db.exec(
    "INSERT IGNORE INTO auth_identities (id, user_id, provider, subject, email, created_at) VALUES (?, ?, ?, ?, ?, ?)",
    [crypto.randomUUID(), user.id, provider, subject, email, now],
  );
  return { user, isNew };
}

// ---------------------------------------------------------------- auth

async function emailStart(ctx: Ctx) {
  const body = await readJson(ctx.request);
  const email = normalizeEmail(requireString(body, "email", { max: 320 }));
  const { db } = ctx.deps;
  const now = Date.now();
  const test = isTestLogin(ctx.env, email);
  // Non-allowlisted test-domain addresses are treated like any address we cannot deliver to.
  if (!test && (isTestDomain(ctx.env, email) || !ctx.env.SEND_EMAIL))
    throw new HttpError(503, "email_unavailable", "email delivery is not configured");

  const perEmail = await db.one<{ n: number }>(
    "SELECT COUNT(*) AS n FROM email_codes WHERE email = ? AND created_at > ?",
    [email, new Date(now - 10 * 60 * 1000)],
  );
  if (Number(perEmail?.n ?? 0) >= EMAIL_STARTS_PER_EMAIL_10M) throw new HttpError(429, "rate_limited");
  if (ctx.ip) {
    const perIp = await db.one<{ n: number }>(
      "SELECT COUNT(*) AS n FROM email_codes WHERE ip = ? AND created_at > ?",
      [ctx.ip, new Date(now - 60 * 60 * 1000)],
    );
    if (Number(perIp?.n ?? 0) >= EMAIL_STARTS_PER_IP_1H) throw new HttpError(429, "rate_limited");
  }

  const code = test ? ctx.env.TEST_LOGIN_CODE! : generateEmailCode();
  if (!test) await sendCode(ctx.env, email, code);
  await db.exec(
    "INSERT INTO email_codes (email, code_hash, ip, created_at, expires_at) VALUES (?, ?, ?, ?, ?)",
    [email, await sha256Hex(`${email}:${code}`), ctx.ip, new Date(now), new Date(now + EMAIL_CODE_TTL_MS)],
  );
  return json({ sent: true, expires_in: EMAIL_CODE_TTL_MS / 1000 });
}

async function emailVerify(ctx: Ctx) {
  const body = await readJson(ctx.request);
  const email = normalizeEmail(requireString(body, "email", { max: 320 }));
  const code = requireString(body, "code", { max: 16 });
  const { db } = ctx.deps;
  const now = new Date();
  if (ctx.ip) await consume(db, "verify_ip", ctx.ip, EMAIL_VERIFIES_PER_IP_10M, MIN_10, now.getTime());
  const invalid = () => new HttpError(400, "invalid_code", "code is invalid or expired");
  const test = isTestLogin(ctx.env, email);
  if (!test && isTestDomain(ctx.env, email)) throw invalid();
  if (test && (await isLocked(db, "test_code_fail", "*", HOUR, now.getTime())))
    throw new HttpError(429, "rate_limited", "test sign-in is temporarily disabled");
  const row = await db.one<{ id: string; code_hash: string }>(
    "SELECT id, code_hash FROM email_codes WHERE email = ? AND consumed_at IS NULL AND expires_at > ? ORDER BY id DESC LIMIT 1",
    [email, now],
  );
  if (!row) throw invalid();
  // Claim an attempt before comparing so concurrent guesses cannot exceed the limit.
  const attempt = await db.exec(
    "UPDATE email_codes SET attempts = attempts + 1 WHERE id = ? AND attempts < ? AND consumed_at IS NULL",
    [row.id, MAX_CODE_ATTEMPTS],
  );
  if (attempt.rowsAffected !== 1) throw invalid();
  if (!timingSafeEqual(row.code_hash, await sha256Hex(`${email}:${code}`))) {
    if (test) await recordFailure(db, "test_code_fail", "*", TEST_CODE_FAILURES_BEFORE_LOCK_1H, HOUR, now.getTime());
    throw invalid();
  }
  const consumed = await db.exec(
    "UPDATE email_codes SET consumed_at = ? WHERE id = ? AND consumed_at IS NULL",
    [now, row.id],
  );
  if (consumed.rowsAffected !== 1) throw new HttpError(400, "invalid_code", "code is invalid or expired");
  const { user, isNew } = await upsertIdentity(db, "email", email, email, null);
  return issueSession(ctx, user, isNew);
}

async function apple(ctx: Ctx) {
  const body = await readJson(ctx.request);
  const identityToken = requireString(body, "identity_token", { max: 8192 });
  const rawNonce = requireString(body, "raw_nonce", { max: 512 });
  const given = optionalString(body, "given_name", 50);
  const family = optionalString(body, "family_name", 50);
  const audiences = ctx.env.APPLE_AUDIENCE.split(",").map((s) => s.trim()).filter(Boolean);
  let identity;
  try {
    identity = await verifyAppleIdentityToken(identityToken, rawNonce, audiences);
  } catch (err) {
    if (err instanceof AppleTokenError) throw new HttpError(401, "invalid_identity_token", err.message);
    throw err;
  }
  const displayName = [given, family].filter(Boolean).join(" ") || null;
  const linkEmail = identity.emailVerified ? identity.email : null;
  const { user, isNew } = await upsertIdentity(ctx.deps.db, "apple", identity.sub, linkEmail, displayName);
  if (!user.display_name && displayName) {
    await ctx.deps.db.exec("UPDATE users SET display_name = ?, updated_at = ? WHERE id = ?", [displayName, new Date(), user.id]);
    user.display_name = displayName;
  }
  return issueSession(ctx, user, isNew);
}

async function refresh(ctx: Ctx) {
  const body = await readJson(ctx.request);
  const token = requireString(body, "refresh_token", { max: 256 });
  const { db } = ctx.deps;
  const now = new Date();
  const hash = await sha256Hex(token);
  const row = await db.one<{ id: string; user_id: string; revoked_at: string | null; expires_at: string }>(
    "SELECT id, user_id, revoked_at, expires_at FROM refresh_tokens WHERE token_hash = ?",
    [hash],
  );
  if (!row) throw new HttpError(401, "invalid_refresh_token");
  // Reuse of a rotated or revoked token means it leaked: revoke the whole family.
  const revokeAll = async () => {
    await db.exec("UPDATE refresh_tokens SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL", [now, row.user_id]);
    return new HttpError(401, "invalid_refresh_token");
  };
  if (row.revoked_at) throw await revokeAll();
  if (new Date(iso(row.expires_at)!).getTime() <= now.getTime()) throw new HttpError(401, "invalid_refresh_token");
  const revoked = await db.exec(
    "UPDATE refresh_tokens SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL",
    [now, row.id],
  );
  // Lost a race with another refresh of the same token: also reuse.
  if (revoked.rowsAffected !== 1) throw await revokeAll();
  const user = await db.one<UserRow>("SELECT * FROM users WHERE id = ?", [row.user_id]);
  if (!user) throw new HttpError(401, "invalid_refresh_token");
  return issueSession(ctx, user, false);
}

async function logout(ctx: Ctx) {
  const body = await readJson(ctx.request);
  const token = requireString(body, "refresh_token", { max: 256 });
  await ctx.deps.db.exec(
    "UPDATE refresh_tokens SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL",
    [new Date(), await sha256Hex(token)],
  );
  return json({ ok: true });
}

// ---------------------------------------------------------------- me

async function getMe(ctx: Ctx) {
  const { user } = await requireUser(ctx);
  return json(userJson(user));
}

async function patchMe(ctx: Ctx) {
  const { user } = await requireUser(ctx);
  const body = await readJson(ctx.request);
  const name = requireString(body, "display_name", { max: 100 });
  await ctx.deps.db.exec("UPDATE users SET display_name = ?, updated_at = ? WHERE id = ?", [name, new Date(), user.id]);
  return json(userJson({ ...user, display_name: name }));
}

async function deleteMe(ctx: Ctx) {
  const { user } = await requireUser(ctx);
  const { db } = ctx.deps;
  await db.exec("DELETE FROM hosts WHERE user_id = ?", [user.id]);
  await db.exec("DELETE FROM refresh_tokens WHERE user_id = ?", [user.id]);
  await db.exec("DELETE FROM auth_identities WHERE user_id = ?", [user.id]);
  await db.exec("DELETE FROM pairings WHERE user_id = ?", [user.id]);
  if (user.email) await db.exec("DELETE FROM email_codes WHERE email = ?", [user.email]);
  await db.exec("DELETE FROM users WHERE id = ?", [user.id]);
  await ctx.deps.disconnect(user.id, null);
  return json({ ok: true });
}

// ---------------------------------------------------------------- pairing and hosts

function hostFields(body: Record<string, unknown>) {
  return {
    name: requireString(body, "host_name", { max: 100 }),
    platform: requireString(body, "platform", { max: 64 }),
    appVersion: requireString(body, "app_version", { max: 64 }),
  };
}

// Pairing states: pending -> awaiting_approval (phone claimed the code) ->
// approved (Mac approved) -> completed (host token delivered once). The Mac can
// reject from pending or awaiting_approval -> rejected.

interface PairingRow {
  id: string;
  code: string;
  poll_secret_hash: string;
  host_name: string;
  platform: string;
  app_version: string;
  status: "pending" | "awaiting_approval" | "approved" | "completed" | "rejected";
  user_id: string | null;
  host_id: string | null;
  created_at: string;
  expires_at: string;
}

function isExpired(row: { expires_at: string }): boolean {
  return new Date(iso(row.expires_at)!).getTime() <= Date.now();
}

function pairingUserJson(u: UserRow) {
  return { id: u.id, email: u.email, display_name: u.display_name };
}

async function pairingStart(ctx: Ctx) {
  const body = await readJson(ctx.request);
  const f = hostFields(body);
  const { db } = ctx.deps;
  const now = Date.now();
  if (ctx.ip) {
    const perIp = await db.one<{ n: number }>(
      "SELECT COUNT(*) AS n FROM pairings WHERE ip = ? AND created_at > ?",
      [ctx.ip, new Date(now - 60 * 60 * 1000)],
    );
    if (Number(perIp?.n ?? 0) >= PAIRING_STARTS_PER_IP_1H) throw new HttpError(429, "rate_limited");
  }
  let code = "";
  for (let i = 0; i < 5; i++) {
    code = generatePairingCode();
    const clash = await db.one(
      "SELECT id FROM pairings WHERE code = ? AND status IN ('pending', 'awaiting_approval', 'approved') AND expires_at > ?",
      [code, new Date(now)],
    );
    if (!clash) break;
    code = "";
  }
  if (!code) throw new HttpError(503, "pairing_unavailable");
  const id = crypto.randomUUID();
  const pollSecret = generateToken("cnp");
  const expiresAt = new Date(now + PAIRING_TTL_MS);
  await db.exec(
    "INSERT INTO pairings (id, code, poll_secret_hash, host_name, platform, app_version, status, ip, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)",
    [id, code, await sha256Hex(pollSecret), f.name, f.platform, f.appVersion, ctx.ip, new Date(now), expiresAt],
  );
  return json({ pairing_id: id, code, poll_secret: pollSecret, expires_at: expiresAt.toISOString() });
}

async function pairingClaim(ctx: Ctx) {
  const { user } = await requireUser(ctx);
  const body = await readJson(ctx.request);
  const code = normalizePairingCode(requireString(body, "code", { max: 32 }));
  const { db } = ctx.deps;
  const now = Date.now();
  if (await isLocked(db, "claim_fail_user", user.id, HOUR, now))
    throw new HttpError(429, "rate_limited", "too many invalid pairing codes; try again later");
  await consume(db, "claim_user", user.id, CLAIMS_PER_USER_10M, MIN_10, now);
  if (ctx.ip) await consume(db, "claim_ip", ctx.ip, CLAIMS_PER_IP_10M, MIN_10, now);

  const fail = async () => {
    await recordFailure(db, "claim_fail_user", user.id, CLAIM_FAILURES_BEFORE_LOCK_1H, HOUR, now);
    return new HttpError(404, "invalid_pairing_code", "pairing code is invalid or expired");
  };
  if (code.length !== PAIRING_CODE_LENGTH) throw await fail();
  const pairing = await db.one<PairingRow>(
    "SELECT * FROM pairings WHERE code = ? AND status = 'pending' AND expires_at > ? ORDER BY created_at DESC LIMIT 1",
    [code, new Date(now)],
  );
  if (!pairing) throw await fail();
  const hostId = crypto.randomUUID();
  const claimed = await db.exec(
    "UPDATE pairings SET status = 'awaiting_approval', user_id = ?, host_id = ? WHERE id = ? AND status = 'pending' AND user_id IS NULL",
    [user.id, hostId, pairing.id],
  );
  if (claimed.rowsAffected !== 1) throw await fail();
  return json({
    host: {
      id: hostId,
      name: pairing.host_name,
      platform: pairing.platform,
      app_version: pairing.app_version,
      created_at: null,
      last_seen_at: null,
      online: false,
    },
    status: "awaiting_approval",
    expires_at: iso(pairing.expires_at),
  });
}

/** Loads a pairing and checks its poll secret in constant time; 404 on any mismatch. */
async function pairingForSecret(ctx: Ctx, id: string, secret: string | null | undefined): Promise<PairingRow> {
  if (!secret) throw new HttpError(401, "unauthorized");
  const pairing = await ctx.deps.db.one<PairingRow>("SELECT * FROM pairings WHERE id = ?", [id]);
  const hash = await sha256Hex(secret);
  if (!pairing || !timingSafeEqual(pairing.poll_secret_hash, hash)) throw new HttpError(404, "pairing_not_found");
  return pairing;
}

async function pairingPoll(ctx: Ctx, params: Record<string, string>) {
  const pairing = await pairingForSecret(ctx, params.id!, ctx.url.searchParams.get("poll_secret"));
  const { db } = ctx.deps;
  switch (pairing.status) {
    case "completed":
      throw new HttpError(410, "pairing_consumed", "host token was already delivered");
    case "rejected":
      return json({ status: "rejected" });
    case "pending":
      if (isExpired(pairing)) throw new HttpError(410, "pairing_expired");
      return json({ status: "pending" });
    case "awaiting_approval": {
      if (isExpired(pairing)) throw new HttpError(410, "pairing_expired");
      const user = await db.one<UserRow>("SELECT * FROM users WHERE id = ?", [pairing.user_id!]);
      if (!user) throw new HttpError(410, "pairing_expired");
      return json({ status: "awaiting_approval", user: pairingUserJson(user) });
    }
    case "approved": {
      if (isExpired(pairing)) throw new HttpError(410, "pairing_expired");
      const user = await db.one<UserRow>("SELECT * FROM users WHERE id = ?", [pairing.user_id!]);
      if (!user) throw new HttpError(410, "pairing_expired");
      // Mint the host token exactly once.
      const won = await db.exec("UPDATE pairings SET status = 'completed' WHERE id = ? AND status = 'approved'", [pairing.id]);
      if (won.rowsAffected !== 1) throw new HttpError(410, "pairing_consumed", "host token was already delivered");
      const hostToken = generateToken("cnh");
      const now = new Date();
      await db.exec(
        "INSERT INTO hosts (id, user_id, name, platform, app_version, token_hash, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [pairing.host_id!, user.id, pairing.host_name, pairing.platform, pairing.app_version, await sha256Hex(hostToken), now, now],
      );
      return json({ status: "claimed", host_id: pairing.host_id, host_token: hostToken, user: userJson(user) });
    }
    default:
      throw new HttpError(410, "pairing_expired");
  }
}

async function pairingApprove(ctx: Ctx, params: Record<string, string>) {
  const body = await readJson(ctx.request);
  const pairing = await pairingForSecret(ctx, params.id!, typeof body.poll_secret === "string" ? body.poll_secret : null);
  if (pairing.status !== "awaiting_approval") throw new HttpError(409, "invalid_pairing_state", `pairing is ${pairing.status}`);
  if (isExpired(pairing)) throw new HttpError(410, "pairing_expired");
  const approved = await ctx.deps.db.exec(
    "UPDATE pairings SET status = 'approved', expires_at = ? WHERE id = ? AND status = 'awaiting_approval'",
    [new Date(Date.now() + APPROVED_TTL_MS), pairing.id],
  );
  if (approved.rowsAffected !== 1) throw new HttpError(409, "invalid_pairing_state");
  return json({ status: "approved" });
}

async function pairingReject(ctx: Ctx, params: Record<string, string>) {
  const body = await readJson(ctx.request);
  const pairing = await pairingForSecret(ctx, params.id!, typeof body.poll_secret === "string" ? body.poll_secret : null);
  if (pairing.status === "rejected") return json({ status: "rejected" });
  if (pairing.status !== "pending" && pairing.status !== "awaiting_approval")
    throw new HttpError(409, "invalid_pairing_state", `pairing is ${pairing.status}`);
  const rejected = await ctx.deps.db.exec(
    "UPDATE pairings SET status = 'rejected' WHERE id = ? AND status IN ('pending', 'awaiting_approval')",
    [pairing.id],
  );
  if (rejected.rowsAffected !== 1) throw new HttpError(409, "invalid_pairing_state");
  return json({ status: "rejected" });
}

async function hostsRegister(ctx: Ctx) {
  const { user } = await requireUser(ctx);
  const f = hostFields(await readJson(ctx.request));
  const hostId = crypto.randomUUID();
  const hostToken = generateToken("cnh");
  const now = new Date();
  await ctx.deps.db.exec(
    "INSERT INTO hosts (id, user_id, name, platform, app_version, token_hash, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    [hostId, user.id, f.name, f.platform, f.appVersion, await sha256Hex(hostToken), now, now],
  );
  return json({ host_id: hostId, host_token: hostToken });
}

async function hostsList(ctx: Ctx) {
  const { user } = await requireUser(ctx);
  const [hosts, online] = await Promise.all([
    ctx.deps.db.rows<HostRow>(
      "SELECT * FROM hosts WHERE user_id = ? AND token_hash IS NOT NULL ORDER BY created_at",
      [user.id],
    ),
    ctx.deps.onlineHostIds(user.id),
  ]);
  const set = new Set(online);
  return json({ hosts: hosts.map((h) => hostJson(h, set)) });
}

async function ownedHost(ctx: Ctx, userId: string, id: string): Promise<HostRow> {
  const host = await ctx.deps.db.one<HostRow>("SELECT * FROM hosts WHERE id = ? AND user_id = ?", [id, userId]);
  if (!host) throw new HttpError(404, "host_not_found");
  return host;
}

async function hostsPatch(ctx: Ctx, params: Record<string, string>) {
  const { user } = await requireUser(ctx);
  const host = await ownedHost(ctx, user.id, params.id!);
  const name = requireString(await readJson(ctx.request), "name", { max: 100 });
  await ctx.deps.db.exec("UPDATE hosts SET name = ? WHERE id = ?", [name, host.id]);
  const online = new Set(await ctx.deps.onlineHostIds(user.id));
  return json(hostJson({ ...host, name }, online));
}

async function hostsDelete(ctx: Ctx, params: Record<string, string>) {
  const { user } = await requireUser(ctx);
  const host = await ownedHost(ctx, user.id, params.id!);
  await ctx.deps.db.exec("DELETE FROM hosts WHERE id = ?", [host.id]);
  await ctx.deps.disconnect(user.id, host.id);
  return json({ ok: true });
}

async function hostMe(ctx: Ctx) {
  const p = await requirePrincipal(ctx, ["host"]);
  if (p.kind !== "host") throw new HttpError(401, "unauthorized");
  const { db } = ctx.deps;
  const [host, user] = await Promise.all([
    db.one<HostRow>("SELECT * FROM hosts WHERE id = ?", [p.hostId]),
    db.one<UserRow>("SELECT * FROM users WHERE id = ?", [p.userId]),
  ]);
  if (!host || !user) throw new HttpError(401, "unauthorized");
  const online = new Set(await ctx.deps.onlineHostIds(user.id));
  return json({ host: hostJson(host, online), user: userJson(user) });
}

/** A Mac unpairing itself: removes the host and revokes its token. */
async function hostMeDelete(ctx: Ctx) {
  const p = await requirePrincipal(ctx, ["host"]);
  if (p.kind !== "host") throw new HttpError(401, "unauthorized");
  await ctx.deps.db.exec("DELETE FROM hosts WHERE id = ? AND user_id = ?", [p.hostId, p.userId]);
  await ctx.deps.disconnect(p.userId, p.hostId);
  return json({ ok: true });
}

// ---------------------------------------------------------------- ice and signaling

async function ice(ctx: Ctx) {
  const p = await requirePrincipal(ctx, ["user", "host"]);
  const key = p.kind === "host" ? `host:${p.hostId}` : `user:${p.userId}`;
  await consume(ctx.deps.db, "ice", key, ICE_PER_PRINCIPAL_1H, HOUR);
  return json(await iceServers(ctx.env));
}

const PEER_ID_RE = /^[A-Za-z0-9_.:-]{1,64}$/;
/** Internal headers the Worker sets for the SignalRoom; never trusted from the client. */
const INTERNAL_HEADER_RE = /^x-(host|peer|user)-/i;

async function signal(ctx: Ctx) {
  if (ctx.request.headers.get("upgrade")?.toLowerCase() !== "websocket")
    throw new HttpError(426, "upgrade_required", "expected a WebSocket upgrade");
  // Prefer the Authorization header; `?token=` remains for older clients.
  const token = bearer(ctx.request) ?? ctx.url.searchParams.get("token");
  const p = await authenticate(ctx.env, ctx.deps.db, token);
  if (!p) throw new HttpError(401, "unauthorized");
  const user = await ctx.deps.db.one<{ id: string }>("SELECT id FROM users WHERE id = ?", [p.userId]);
  if (!user) throw new HttpError(401, "unauthorized", "account no longer exists");

  let peer: string;
  if (p.kind === "host") {
    // Host peer ids are assigned by the server so a phone cannot impersonate a Mac.
    peer = `host-${p.hostId}`;
  } else {
    peer = ctx.url.searchParams.get("peer") ?? "";
    if (!PEER_ID_RE.test(peer)) throw new HttpError(400, "invalid_peer", "peer must match [A-Za-z0-9_.:-]{1,64}");
    if (peer.toLowerCase().startsWith("host")) throw new HttpError(400, "invalid_peer", "peer ids starting with host are reserved");
  }

  const headers = new Headers();
  for (const [name, value] of ctx.request.headers) {
    if (INTERNAL_HEADER_RE.test(name) || name.toLowerCase() === "authorization") continue;
    headers.set(name, value);
  }
  headers.set("x-peer-id", peer);
  headers.set("x-peer-kind", p.kind === "host" ? "host" : "phone");
  if (p.kind === "host") {
    headers.set("x-host-id", p.hostId);
    headers.set("x-peer-name", encodeURIComponent(p.hostName));
  }
  // Forward without credentials in the URL.
  const forward = new URL(ctx.url);
  forward.searchParams.delete("token");
  return ctx.deps.connectSignal(p.userId, new Request(forward.toString(), { headers }));
}

// ---------------------------------------------------------------- routing

const router = new Router<Ctx>()
  .on("GET", "/", () => json({ name: "cmux-next-mobile-native", ok: true }))
  .on("GET", "/healthz", () => json({ ok: true }))
  .on("POST", "/v1/auth/email/start", emailStart)
  .on("POST", "/v1/auth/email/verify", emailVerify)
  .on("POST", "/v1/auth/apple", apple)
  .on("POST", "/v1/auth/refresh", refresh)
  .on("POST", "/v1/auth/logout", logout)
  .on("GET", "/v1/me", getMe)
  .on("PATCH", "/v1/me", patchMe)
  .on("DELETE", "/v1/me", deleteMe)
  .on("POST", "/v1/pairing/start", pairingStart)
  .on("POST", "/v1/pairing/claim", pairingClaim)
  .on("GET", "/v1/pairing/:id", pairingPoll)
  .on("POST", "/v1/pairing/:id/approve", pairingApprove)
  .on("POST", "/v1/pairing/:id/reject", pairingReject)
  .on("POST", "/v1/hosts/register", hostsRegister)
  .on("GET", "/v1/hosts", hostsList)
  .on("PATCH", "/v1/hosts/:id", hostsPatch)
  .on("DELETE", "/v1/hosts/:id", hostsDelete)
  .on("GET", "/v1/host/me", hostMe)
  .on("DELETE", "/v1/host/me", hostMeDelete)
  .on("GET", "/v1/ice", ice)
  .on("GET", "/v1/signal", signal);

export async function handle(request: Request, env: Env, deps: Deps): Promise<Response> {
  const url = new URL(request.url);
  const m = router.match(request.method, url.pathname);
  if (m === null) return errorResponse(404, "not_found");
  if (m === "method_not_allowed") return errorResponse(405, "method_not_allowed");
  const ctx: Ctx = { request, url, env, deps, ip: request.headers.get("cf-connecting-ip") };
  try {
    return await m.handler(ctx, m.params);
  } catch (err) {
    if (err instanceof HttpError) return errorResponse(err.status, err.code, err.message);
    console.error("unhandled", request.method, url.pathname, (err as Error).stack ?? String(err));
    return errorResponse(500, "internal_error");
  }
}
