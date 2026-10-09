import type { MiddlewareHandler } from "hono";
import type { HonoEnv, Principal } from "./context";
import { randomId, randomToken, sha256Hex, signHs256, verifyHs256 } from "./crypto";
import { ApiError, unauthorized, unavailable } from "./errors";
import { bearer } from "./http";
import type { Repo, User } from "./repo/types";

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

export async function verifyAccessToken(secret: string, token: string, now: number): Promise<string | null> {
  const payload = await verifyHs256(secret, token, now);
  if (!payload || payload.typ !== "user" || payload.iss !== ISSUER || typeof payload.sub !== "string") return null;
  return payload.sub;
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
    createdAt: now,
  });
  return {
    accessToken: await signAccessToken(secret, user.id, now),
    refreshToken,
    expiresIn: ACCESS_TTL_S,
    user: userView(user),
  };
}

/** Rotates a refresh token. Reuse of a revoked token revokes its whole family. */
export async function rotateRefreshToken(repo: Repo, secret: string, refreshToken: string, now: number): Promise<Tokens> {
  const hash = await sha256Hex(refreshToken);
  const row = await repo.getRefreshToken(hash);
  if (!row) throw unauthorized("invalid refresh token");
  if (row.revokedAt !== null) {
    await repo.revokeRefreshFamily(row.familyId, now);
    throw unauthorized("refresh token reused");
  }
  if (row.expiresAt <= now) throw unauthorized("refresh token expired");
  if (!(await repo.revokeRefreshToken(hash, now))) {
    await repo.revokeRefreshFamily(row.familyId, now);
    throw unauthorized("refresh token reused");
  }
  const user = await repo.getUser(row.userId);
  if (!user) throw unauthorized("user not found");
  return issueTokens(repo, secret, user, now, row.familyId);
}

export interface ExternalIdentity {
  provider: string;
  subject: string;
  email: string | null;
  emailVerified: boolean;
  name: string | null;
}

/**
 * Finds the user for an external identity, linking by verified email or
 * creating a new user when needed.
 */
export async function resolveUser(repo: Repo, id: ExternalIdentity, now: number): Promise<User> {
  const email = id.email?.trim().toLowerCase() || null;
  const linked = await repo.findIdentityUserId(id.provider, id.subject);
  if (linked) {
    const user = await repo.getUser(linked);
    if (user) {
      if (!user.name && id.name) {
        await repo.setUserName(user.id, id.name);
        user.name = id.name;
      }
      return user;
    }
  }
  let user = email && id.emailVerified ? await repo.getUserByEmail(email) : null;
  if (!user) {
    const usableEmail = email && id.emailVerified ? email : null;
    user = { id: randomId("u"), email: usableEmail, name: id.name, createdAt: now };
    await repo.createUser(user);
  } else if (!user.name && id.name) {
    await repo.setUserName(user.id, id.name);
    user.name = id.name;
  }
  await repo.createIdentity(id.provider, id.subject, user.id, email, now);
  return user;
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
  const userId = await verifyAccessToken(jwtSecret(c.env), token, deps.now());
  if (!userId) throw unauthorized("invalid or expired access token");
  return { kind: "user", userId };
}

/** Requires a user access token. */
export const requireUser: MiddlewareHandler<HonoEnv> = async (c, next) => {
  c.set("principal", await authenticate(c, bearer(c), false));
  await next();
};

/** Accepts a user access token or a host token (header, or `?token=`). */
export const requireUserOrHost: MiddlewareHandler<HonoEnv> = async (c, next) => {
  c.set("principal", await authenticate(c, bearer(c) ?? c.req.query("token"), true));
  await next();
};
