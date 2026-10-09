import type { MiddlewareHandler } from "hono";
import type { HonoEnv, Principal } from "./context";
import { hmacHex, randomId, randomToken, sha256Hex, signHs256, verifyHs256 } from "./crypto";
import { ApiError, unauthorized, unavailable } from "./errors";
import { bearer } from "./http";
import { isDuplicate, type Repo, type User } from "./repo/types";

export const ACCESS_TTL_S = 15 * 60;
export const REFRESH_TTL_MS = 60 * 24 * 60 * 60 * 1000;
export const ISSUER = "cmux-next-mobile";

export interface Tokens {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  user: UserView;
}

export interface UserView {
  id: string;
  email: string | null;
  name: string | null;
}

export const userView = (u: User): UserView => ({ id: u.id, email: u.email, name: u.name });

export function jwtSecret(env: { JWT_SECRET?: string }): string {
  if (!env.JWT_SECRET) throw unavailable("auth not configured");
  return env.JWT_SECRET;
}

export async function signAccessToken(secret: string, userId: string, now: number): Promise<string> {
  const iat = Math.floor(now / 1000);
  return signHs256(secret, { iss: ISSUER, sub: userId, typ: "user", iat, exp: iat + ACCESS_TTL_S });
}

export async function verifyAccessToken(secret: string, token: string, now: number): Promise<{ userId: string; exp: number } | null> {
  const payload = await verifyHs256(secret, token, now);
  if (!payload || payload.typ !== "user" || payload.iss !== ISSUER || typeof payload.sub !== "string" || typeof payload.exp !== "number") return null;
  return { userId: payload.sub, exp: payload.exp * 1000 };
}

/** Issues an access token and a new refresh token in `familyId` (new family when omitted). */
export async function issueTokens(repo: Repo, secret: string, user: User, now: number, familyId?: string): Promise<Tokens> {
  const refreshToken = randomToken("rt");
  await repo.createRefreshToken({
    hash: await sha256Hex(refreshToken),
    userId: user.id,
    familyId: familyId ?? randomId("rf"),
    expiresAt: now + REFRESH_TTL_MS,
    revokedAt: null,
    rotatedAt: null,
    createdAt: now,
  });
  return {
    accessToken: await signAccessToken(secret, user.id, now),
    refreshToken,
    expiresIn: ACCESS_TTL_S,
    user: userView(user),
  };
}

/** A retry of the same refresh within this window gets the same new pair. */
export const REFRESH_GRACE_MS = 30 * 1000;

/** The successor of a refresh token is derived from it, so a retry can recompute it. */
async function successorOf(secret: string, refreshToken: string): Promise<string> {
  return `rt_${(await hmacHex(secret, `rotate:${refreshToken}`)).slice(0, 43)}`;
}

/**
 * Rotates a refresh token. A retry with the immediately previous token within
 * REFRESH_GRACE_MS returns the same new pair; any other reuse of a rotated or
 * revoked token revokes the whole family.
 */
export async function rotateRefreshToken(repo: Repo, secret: string, refreshToken: string, now: number): Promise<Tokens> {
  const hash = await sha256Hex(refreshToken);
  const row = await repo.getRefreshToken(hash);
  if (!row) throw unauthorized("invalid refresh token");
  const next = await successorOf(secret, refreshToken);
  const nextHash = await sha256Hex(next);

  const reuse = async (): Promise<never> => {
    await repo.revokeRefreshFamily(row.familyId, now);
    throw unauthorized("refresh token reused");
  };
  const pair = async (at: number): Promise<Tokens> => {
    const user = await repo.getUser(row.userId);
    if (!user) throw unauthorized("user not found");
    return { accessToken: await signAccessToken(secret, user.id, at), refreshToken: next, expiresIn: ACCESS_TTL_S, user: userView(user) };
  };
  const grace = async (rotatedAt: number | null): Promise<Tokens> => {
    if (rotatedAt === null || now - rotatedAt > REFRESH_GRACE_MS) return reuse();
    const child = await repo.getRefreshToken(nextHash);
    if (!child || child.revokedAt !== null) return reuse();
    return pair(rotatedAt);
  };

  if (row.revokedAt !== null) return grace(row.rotatedAt);
  if (row.expiresAt <= now) throw unauthorized("refresh token expired");
  // Insert the successor first so a concurrent retry finds it.
  await repo.createRefreshTokenIfAbsent({
    hash: nextHash,
    userId: row.userId,
    familyId: row.familyId,
    expiresAt: now + REFRESH_TTL_MS,
    revokedAt: null,
    rotatedAt: null,
    createdAt: now,
  });
  if (!(await repo.markRefreshTokenRotated(hash, now))) {
    const current = await repo.getRefreshToken(hash);
    return grace(current?.rotatedAt ?? null);
  }
  return pair(now);
}

export interface ExternalIdentity {
  provider: string;
  subject: string;
  email: string | null;
  emailVerified: boolean;
  name: string | null;
  /** False keeps the email off the account and never links by it. Default true. */
  linkByEmail?: boolean;
}

/**
 * Finds the user for an external identity, linking by verified email or
 * creating a new user when needed. Safe against concurrent first sign-ins.
 */
export async function resolveUser(repo: Repo, id: ExternalIdentity, now: number): Promise<User> {
  const email = id.email?.trim().toLowerCase() || null;
  const usableEmail = email && id.emailVerified && id.linkByEmail !== false ? email : null;

  const byIdentity = async (): Promise<User | null> => {
    const linked = await repo.findIdentityUserId(id.provider, id.subject);
    return linked ? repo.getUser(linked) : null;
  };
  const fillName = async (user: User): Promise<User> => {
    if (!user.name && id.name) {
      await repo.setUserName(user.id, id.name);
      user.name = id.name;
    }
    return user;
  };

  const existing = await byIdentity();
  if (existing) return fillName(existing);

  let user = usableEmail ? await repo.getUserByEmail(usableEmail) : null;
  let created = false;
  if (!user) {
    const fresh: User = { id: randomId("u"), email: usableEmail, name: id.name, createdAt: now };
    try {
      await repo.createUser(fresh);
      user = fresh;
      created = true;
    } catch (err) {
      // A concurrent sign-in created the account with this email first.
      if (!isDuplicate(err) || !usableEmail) throw err;
      user = await repo.getUserByEmail(usableEmail);
      if (!user) throw err;
    }
  }
  try {
    await repo.createIdentity(id.provider, id.subject, user.id, email, now);
  } catch (err) {
    if (!isDuplicate(err)) throw err;
    // A concurrent sign-in linked this identity first; use its user.
    const winner = await byIdentity();
    if (!winner) throw err;
    if (created && winner.id !== user.id) await repo.deleteUser(user.id);
    return fillName(winner);
  }
  return created ? user : fillName(user);
}

async function authenticate(c: Parameters<MiddlewareHandler<HonoEnv>>[0], token: string | undefined, allowHost: boolean): Promise<Principal> {
  if (!token) throw unauthorized("missing bearer token");
  const { deps, repo } = c.var;
  if (token.startsWith("ht_")) {
    if (!allowHost) throw new ApiError("forbidden", "user token required");
    const host = await repo.getHostByTokenHash(await sha256Hex(token));
    if (!host) throw unauthorized("invalid host token");
    return { kind: "host", userId: host.userId, hostId: host.id };
  }
  const verified = await verifyAccessToken(jwtSecret(c.env), token, deps.now());
  if (!verified) throw unauthorized("invalid or expired access token");
  return { kind: "user", userId: verified.userId, expiresAt: verified.exp };
}

/** Requires a user access token. */
export const requireUser: MiddlewareHandler<HonoEnv> = async (c, next) => {
  c.set("principal", await authenticate(c, bearer(c), false));
  await next();
};

/** Accepts a user access token or a host token in `Authorization: Bearer`. */
export const requireUserOrHost: MiddlewareHandler<HonoEnv> = async (c, next) => {
  c.set("principal", await authenticate(c, bearer(c), true));
  await next();
};

/**
 * Like requireUserOrHost, plus the deprecated `?token=` query parameter
 * (signaling WebSocket only; clients are moving to the header).
 */
export const requireUserOrHostAllowQuery: MiddlewareHandler<HonoEnv> = async (c, next) => {
  c.set("principal", await authenticate(c, bearer(c) ?? c.req.query("token"), true));
  await next();
};
