import { Hono } from "hono";
import { issueTokens, jwtSecret, resolveUser, type ExternalIdentity } from "../auth";
import type { Ctx, HonoEnv } from "../context";
import { randomToken, sha256Base64url, sha256Hex, signHs256, timingSafeEqual, verifyHs256 } from "../crypto";
import { csv, oauthConfigured, type AppEnv, type OAuthProvider } from "../env";
import { badRequest, notFound, unauthorized, unsupported } from "../errors";
import { rateLimit, readJson, str } from "../http";

const STATE_TTL_S = 10 * 60;
const CODE_TTL_MS = 5 * 60 * 1000;
const PROVIDERS: OAuthProvider[] = ["github", "google"];
const UA = "cmux-next-mobile";

function provider(c: Ctx): OAuthProvider {
  const p = c.req.param("provider") as OAuthProvider;
  if (!PROVIDERS.includes(p)) throw notFound("unknown provider");
  if (!oauthConfigured(c.env, p)) throw unsupported(`${p} sign-in is not configured`);
  return p;
}

function callbackUrl(c: Ctx, p: OAuthProvider): string {
  return `${new URL(c.req.url).origin}/v1/auth/oauth/${p}/callback`;
}

/** Only custom app schemes from OAUTH_REDIRECT_SCHEMES may receive codes. */
export function checkRedirect(env: AppEnv, raw: string | undefined): URL {
  if (!raw) throw badRequest("redirect is required");
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw badRequest("invalid redirect");
  }
  const scheme = url.protocol.replace(/:$/, "");
  if (!csv(env.OAUTH_REDIRECT_SCHEMES).includes(scheme)) throw badRequest("redirect scheme not allowed");
  return url;
}

function redirectWith(target: string, params: Record<string, string>): Response {
  const url = new URL(target);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  return new Response(null, { status: 302, headers: { location: url.toString(), "cache-control": "no-store" } });
}

export const oauthRoutes = new Hono<HonoEnv>();

oauthRoutes.get("/:provider/start", async (c) => {
  await rateLimit(c, "auth");
  const p = provider(c);
  const redirect = checkRedirect(c.env, c.req.query("redirect"));
  const challenge = c.req.query("code_challenge");
  const method = c.req.query("code_challenge_method") ?? "S256";
  if (method !== "S256" || !challenge || !/^[A-Za-z0-9_-]{43}$/.test(challenge)) throw badRequest("code_challenge (S256) is required");
  const iat = Math.floor(c.var.deps.now() / 1000);
  const state = await signHs256(jwtSecret(c.env), {
    typ: "oauth_state",
    p,
    r: redirect.toString(),
    cc: challenge,
    n: randomToken("n", 8),
    iat,
    exp: iat + STATE_TTL_S,
  });
  const url =
    p === "github"
      ? new URL("https://github.com/login/oauth/authorize")
      : new URL("https://accounts.google.com/o/oauth2/v2/auth");
  url.searchParams.set("client_id", p === "github" ? c.env.GITHUB_CLIENT_ID! : c.env.GOOGLE_CLIENT_ID!);
  url.searchParams.set("redirect_uri", callbackUrl(c, p));
  url.searchParams.set("state", state);
  if (p === "github") {
    url.searchParams.set("scope", "read:user user:email");
  } else {
    url.searchParams.set("response_type", "code");
    url.searchParams.set("scope", "openid email profile");
    url.searchParams.set("prompt", "select_account");
  }
  return c.redirect(url.toString(), 302);
});

oauthRoutes.get("/:provider/callback", async (c) => {
  const p = provider(c);
  const { deps, repo } = c.var;
  const now = deps.now();
  const state = await verifyHs256(jwtSecret(c.env), c.req.query("state") ?? "", now);
  if (!state || state.typ !== "oauth_state" || state.p !== p || typeof state.r !== "string" || typeof state.cc !== "string") {
    throw badRequest("invalid or expired state");
  }
  const redirect = checkRedirect(c.env, state.r).toString();
  if (c.req.query("error")) return redirectWith(redirect, { error: "access_denied" });
  const code = c.req.query("code");
  if (!code) return redirectWith(redirect, { error: "invalid_request" });
  let identity: ExternalIdentity;
  try {
    identity = p === "github" ? await githubIdentity(c, code) : await googleIdentity(c, code);
  } catch (err) {
    console.error("oauth exchange failed", p, err instanceof Error ? err.message : err);
    return redirectWith(redirect, { error: "server_error" });
  }
  const user = await resolveUser(repo, identity, now);
  const oneTime = randomToken("oc");
  await repo.createOAuthCode({
    codeHash: await sha256Hex(oneTime),
    userId: user.id,
    codeChallenge: state.cc,
    expiresAt: now + CODE_TTL_MS,
    consumedAt: null,
    createdAt: now,
  });
  return redirectWith(redirect, { code: oneTime });
});

oauthRoutes.post("/exchange", async (c) => {
  await rateLimit(c, "auth");
  const { deps, repo } = c.var;
  const body = await readJson(c);
  const code = str(body, "code", { max: 256 });
  const verifier = str(body, "codeVerifier", { max: 128 });
  if (!/^[A-Za-z0-9._~-]{43,128}$/.test(verifier)) throw badRequest("codeVerifier must be 43-128 unreserved characters");
  const now = deps.now();
  const row = await repo.takeOAuthCode(await sha256Hex(code), now);
  if (!row) throw unauthorized("invalid or expired code");
  if (!row.codeChallenge || !timingSafeEqual(await sha256Base64url(verifier), row.codeChallenge)) throw unauthorized("code verifier mismatch");
  const user = await repo.getUser(row.userId);
  if (!user) throw unauthorized("user not found");
  return c.json(await issueTokens(repo, jwtSecret(c.env), user, now));
});

async function githubIdentity(c: Ctx, code: string): Promise<ExternalIdentity> {
  const f = c.var.deps.fetch;
  const tokenRes = await f("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/json", "user-agent": UA },
    body: JSON.stringify({
      client_id: c.env.GITHUB_CLIENT_ID,
      client_secret: c.env.GITHUB_CLIENT_SECRET,
      code,
      redirect_uri: callbackUrl(c, "github"),
    }),
  });
  const token = (await tokenRes.json()) as { access_token?: string; error?: string };
  if (!token.access_token) throw new Error(`github token: ${token.error ?? tokenRes.status}`);
  const headers = { authorization: `Bearer ${token.access_token}`, accept: "application/vnd.github+json", "user-agent": UA };
  const userRes = await f("https://api.github.com/user", { headers });
  if (!userRes.ok) throw new Error(`github user: ${userRes.status}`);
  const gh = (await userRes.json()) as { id: number; login: string; name?: string | null };
  let email: string | null = null;
  const emailsRes = await f("https://api.github.com/user/emails", { headers });
  if (emailsRes.ok) {
    const emails = (await emailsRes.json()) as { email: string; primary: boolean; verified: boolean }[];
    email = emails.find((e) => e.primary && e.verified)?.email ?? null;
  }
  return { provider: "github", subject: String(gh.id), email, emailVerified: email !== null, name: gh.name || gh.login };
}

async function googleIdentity(c: Ctx, code: string): Promise<ExternalIdentity> {
  const f = c.var.deps.fetch;
  const tokenRes = await f("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: c.env.GOOGLE_CLIENT_ID!,
      client_secret: c.env.GOOGLE_CLIENT_SECRET!,
      redirect_uri: callbackUrl(c, "google"),
      grant_type: "authorization_code",
    }),
  });
  const token = (await tokenRes.json()) as { access_token?: string; error?: string };
  if (!token.access_token) throw new Error(`google token: ${token.error ?? tokenRes.status}`);
  const infoRes = await f("https://openidconnect.googleapis.com/v1/userinfo", { headers: { authorization: `Bearer ${token.access_token}` } });
  if (!infoRes.ok) throw new Error(`google userinfo: ${infoRes.status}`);
  const info = (await infoRes.json()) as { sub: string; email?: string; email_verified?: boolean; name?: string };
  return { provider: "google", subject: info.sub, email: info.email ?? null, emailVerified: info.email_verified === true, name: info.name ?? null };
}
