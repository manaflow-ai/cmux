import { Hono } from "hono";
import { verifyAppleIdentityToken } from "../apple";
import { issueTokens, jwtSecret, requireUser, resolveUser, rotateRefreshToken, userView } from "../auth";
import type { HonoEnv } from "../context";
import { CODE_ALPHABET, hmacHex, randomCode, randomToken, sha256Hex, timingSafeEqual } from "../crypto";
import { csv, stackProjects } from "../env";
import { fetchStackUser, verifyStackAccessToken } from "../stack";
import { notifyFamiliesRevoked } from "../signal/client";
import { ApiError, badRequest, notFound, unauthorized, unavailable, unsupported } from "../errors";
import { rateLimit, readJson, str } from "../http";

export const EMAIL_CODE_TTL_MS = 10 * 60 * 1000;
export const EMAIL_CODE_MAX_ATTEMPTS = 5;
export const EMAIL_CODES_PER_HOUR = 5;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function normalizeEmail(raw: string): string {
  const email = raw.trim().toLowerCase();
  if (email.length > 320 || !EMAIL_RE.test(email)) throw badRequest("invalid email");
  return email;
}

export function normalizeCode(raw: string): string {
  return raw.toUpperCase().replace(/[^A-Z0-9]/g, "");
}

export const authRoutes = new Hono<HonoEnv>();

authRoutes.post("/email/start", async (c) => {
  await rateLimit(c, "auth");
  const { repo, deps } = c.var;
  const secret = jwtSecret(c.env);
  const email = normalizeEmail(str(await readJson(c), "email", { max: 320 }));
  const now = deps.now();
  if ((await repo.countEmailCodesSince(email, now - 60 * 60 * 1000)) >= EMAIL_CODES_PER_HOUR) {
    throw new ApiError("rate_limited", "too many codes requested; try again later");
  }
  const nonce = randomToken("en", 16);
  const code = randomCode(6, CODE_ALPHABET);
  await repo.createEmailCode({
    nonce,
    email,
    codeHash: await hmacHex(secret, `${nonce}:${code}`),
    attempts: 0,
    expiresAt: now + EMAIL_CODE_TTL_MS,
    consumedAt: null,
    createdAt: now,
  });
  const sent = await deps.mailer(c.env, {
    to: email,
    subject: `Your cmux sign-in code: ${code}`,
    text: `Your cmux sign-in code is ${code}\n\nIt expires in 10 minutes. If you did not request it, ignore this email.`,
    html: `<p>Your cmux sign-in code is</p><p style="font-size:28px;font-weight:600;letter-spacing:4px;font-family:ui-monospace,monospace">${code}</p><p>It expires in 10 minutes. If you did not request it, ignore this email.</p>`,
  });
  if (!sent) throw unavailable("email sign-in is not configured");
  return c.json({ nonce });
});

authRoutes.post("/email/verify", async (c) => {
  await rateLimit(c, "auth");
  const { repo, deps } = c.var;
  const secret = jwtSecret(c.env);
  const body = await readJson(c);
  const email = normalizeEmail(str(body, "email", { max: 320 }));
  const code = normalizeCode(str(body, "code", { max: 32 }));
  const nonce = str(body, "nonce", { max: 64 });
  const now = deps.now();
  const row = await repo.getEmailCode(nonce);
  if (!row || row.email !== email || row.consumedAt !== null || row.expiresAt <= now) throw unauthorized("invalid or expired code");
  if (!(await repo.incrementEmailCodeAttempts(nonce, EMAIL_CODE_MAX_ATTEMPTS))) {
    throw new ApiError("rate_limited", "too many attempts; request a new code");
  }
  if (!timingSafeEqual(await hmacHex(secret, `${nonce}:${code}`), row.codeHash)) throw unauthorized("invalid or expired code");
  if (!(await repo.consumeEmailCode(nonce, now))) throw unauthorized("invalid or expired code");
  const user = await resolveUser(repo, { provider: "email", subject: email, email, emailVerified: true, name: null }, now);
  return c.json(await issueTokens(repo, secret, user, now));
});

/**
 * Automated-test sign-in. Exists only when the TEST_LOGIN_SECRET secret is
 * set, and only for emails in TEST_LOGIN_EMAIL_DOMAINS.
 */
authRoutes.post("/test", async (c) => {
  const expected = c.env.TEST_LOGIN_SECRET;
  if (!expected) throw notFound();
  await rateLimit(c, "auth");
  const { repo, deps } = c.var;
  const body = await readJson(c);
  const email = normalizeEmail(str(body, "email", { max: 320 }));
  const given = str(body, "secret", { max: 512 });
  if (!timingSafeEqual(await sha256Hex(given), await sha256Hex(expected))) throw unauthorized("invalid test secret");
  const domains = csv(c.env.TEST_LOGIN_EMAIL_DOMAINS ?? "test.cmux.dev");
  if (!domains.includes(email.split("@")[1] ?? "")) throw new ApiError("forbidden", "email domain not allowed for test sign-in");
  const now = deps.now();
  const user = await resolveUser(repo, { provider: "email", subject: email, email, emailVerified: true, name: null }, now);
  return c.json(await issueTokens(repo, jwtSecret(c.env), user, now));
});

/** Primary sign-in: exchange a Stack Auth access token (same accounts as cmux iOS). */
authRoutes.post("/stack", async (c) => {
  await rateLimit(c, "auth");
  const { repo, deps } = c.var;
  const secret = jwtSecret(c.env);
  const body = await readJson(c);
  const accessToken = str(body, "accessToken", { max: 8192 });
  const projectId = str(body, "projectId", { max: 64 });
  const now = deps.now();
  const projects = stackProjects(c.env);
  const project = projects.get(projectId);
  const claims = await verifyStackAccessToken(accessToken, projectId, [...projects.keys()], deps.fetch, now);
  if (!claims.email || !claims.name) {
    try {
      const extra = await fetchStackUser(accessToken, projectId, deps.fetch);
      if (!claims.email && extra.email) {
        claims.email = extra.email;
        claims.emailVerified = extra.emailVerified ?? false;
      }
      claims.name ??= extra.name ?? null;
    } catch (err) {
      console.error("stack users/me failed", err instanceof Error ? err.message : err);
    }
  }
  const user = await resolveUser(
    repo,
    {
      provider: `stack:${projectId}`,
      subject: claims.sub,
      email: claims.email,
      emailVerified: claims.emailVerified,
      name: claims.name,
      // Only the prod project may link to (or claim) an account by email; dev
      // project users are anyone who signs up there, so they never inherit one.
      linkByEmail: project?.linkByEmail ?? false,
    },
    now,
  );
  return c.json(await issueTokens(repo, secret, user, now));
});

/** Disabled unless APPLE_AUDIENCES is set; the app signs in with Apple through Stack. */
authRoutes.post("/apple", async (c) => {
  if (csv(c.env.APPLE_AUDIENCES).length === 0) throw unsupported("Sign in with Apple is not enabled; use Stack");
  await rateLimit(c, "auth");
  const { repo, deps } = c.var;
  const secret = jwtSecret(c.env);
  const body = await readJson(c);
  const identityToken = str(body, "identityToken", { max: 8192 });
  const now = deps.now();
  const nonce = str(body, "nonce", { max: 256, optional: true });
  if (!nonce) throw unsupported("Sign in with Apple requires a nonce");
  const claims = await verifyAppleIdentityToken(identityToken, csv(c.env.APPLE_AUDIENCES), deps.fetch, now, nonce);
  const user = await resolveUser(
    repo,
    { provider: "apple", subject: claims.sub, email: claims.email, emailVerified: claims.emailVerified, name: appleName(body.fullName) },
    now,
  );
  return c.json(await issueTokens(repo, secret, user, now));
});

function appleName(raw: unknown): string | null {
  if (typeof raw === "string") return raw.trim().slice(0, 200) || null;
  if (raw && typeof raw === "object") {
    const n = raw as Record<string, unknown>;
    const parts = [n.givenName, n.middleName, n.familyName].filter((p): p is string => typeof p === "string" && p.trim() !== "");
    return parts.join(" ").slice(0, 200) || null;
  }
  return null;
}

authRoutes.post("/refresh", async (c) => {
  await rateLimit(c, "refresh");
  const { repo, deps } = c.var;
  const refreshToken = str(await readJson(c), "refreshToken", { max: 256 });
  return c.json(
    await rotateRefreshToken(repo, jwtSecret(c.env), refreshToken, deps.now(), (userId, family) => notifyFamiliesRevoked(c.env, userId, [family])),
  );
});

authRoutes.post("/logout", requireUser, async (c) => {
  const { repo, deps, principal } = c.var;
  const refreshToken = str(await readJson(c), "refreshToken", { max: 256, optional: true });
  if (refreshToken) {
    const row = await repo.getRefreshToken(await sha256Hex(refreshToken));
    if (row && row.userId === principal.userId) {
      await repo.revokeRefreshFamily(row.familyId, deps.now());
      await notifyFamiliesRevoked(c.env, principal.userId, [row.familyId]);
    }
  }
  return c.json({});
});

export { userView };
