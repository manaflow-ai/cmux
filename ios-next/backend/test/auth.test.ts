import { beforeEach, describe, expect, it } from "vitest";
import { resetAppleJwksCache } from "../src/apple";
import { base64url, CODE_ALPHABET, sha256Base64url, sha256Hex, verifyHs256 } from "../src/crypto";
import { emailLogin, harness, lastCode } from "./helpers";

describe("health and configuration", () => {
  it("reports configured features", async () => {
    const h = harness({ TURN_KEY_ID: undefined, TURN_KEY_API_TOKEN: undefined });
    const res = await h.call("GET", "/v1/health");
    expect(res.status).toBe(200);
    expect(res.json).toMatchObject({ ok: true, turn: false, oauth: { github: false, google: false } });
  });

  it("answers 503 for database routes when no database is configured", async () => {
    const { createApp } = await import("../src/app");
    const app = createApp({ repo: () => null });
    const res = await app.request("https://api.test/v1/auth/email/start", { method: "POST", body: "{}" }, {});
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: { code: "unavailable", message: "database not configured" } });
    const health = await app.request("https://api.test/v1/health", {}, {});
    expect(await health.json()).toMatchObject({ db: false, email: false, turn: false });
  });

  it("returns a JSON 404 for unknown routes", async () => {
    const h = harness();
    const res = await h.call("GET", "/v1/nope");
    expect(res.status).toBe(404);
    expect(res.json.error.code).toBe("not_found");
  });
});

describe("email sign-in", () => {
  it("mails a 6-char code without ambiguous characters and verifies it", async () => {
    const h = harness();
    const start = await h.call("POST", "/v1/auth/email/start", { body: { email: " A@Example.com " } });
    expect(start.status).toBe(200);
    expect(start.json.nonce).toMatch(/^en_/);
    expect(h.mail).toHaveLength(1);
    expect(h.mail[0]!.to).toBe("a@example.com");
    const code = lastCode(h.mail);
    expect(code).toHaveLength(6);
    for (const ch of code) expect(CODE_ALPHABET).toContain(ch);
    expect(code).not.toMatch(/[01OIL]/);

    const verify = await h.call("POST", "/v1/auth/email/verify", { body: { email: "a@example.com", code: code.toLowerCase(), nonce: start.json.nonce } });
    expect(verify.status).toBe(200);
    expect(verify.json).toMatchObject({ expiresIn: 900, user: { email: "a@example.com" } });
    expect(verify.json.refreshToken).toMatch(/^rt_/);
    const payload = await verifyHs256("unit-secret", verify.json.accessToken, h.clock.now);
    expect(payload).toMatchObject({ sub: verify.json.user.id, typ: "user" });
    expect(payload!.exp! - payload!.iat!).toBe(900);

    // Codes are stored hashed.
    const row = [...h.repo.emailCodes.values()][0]!;
    expect(row.codeHash).not.toContain(code);

    // Single use.
    const again = await h.call("POST", "/v1/auth/email/verify", { body: { email: "a@example.com", code, nonce: start.json.nonce } });
    expect(again.status).toBe(401);
  });

  it("returns the same user on a second sign-in", async () => {
    const h = harness();
    const a = await emailLogin(h);
    const b = await emailLogin(h);
    expect(b.user.id).toBe(a.user.id);
  });

  it("rejects wrong codes and locks after 5 attempts", async () => {
    const h = harness();
    const start = await h.call("POST", "/v1/auth/email/start", { body: { email: "a@example.com" } });
    const code = lastCode(h.mail);
    const wrong = code === "AAAAAA" ? "BBBBBB" : "AAAAAA";
    for (let i = 0; i < 5; i++) {
      const r = await h.call("POST", "/v1/auth/email/verify", { body: { email: "a@example.com", code: wrong, nonce: start.json.nonce } });
      expect(r.status).toBe(401);
    }
    const locked = await h.call("POST", "/v1/auth/email/verify", { body: { email: "a@example.com", code, nonce: start.json.nonce } });
    expect(locked.status).toBe(429);
    expect(locked.headers.get("retry-after")).toBe("60");
  });

  it("rejects expired codes and codes for another email", async () => {
    const h = harness();
    const start = await h.call("POST", "/v1/auth/email/start", { body: { email: "a@example.com" } });
    const code = lastCode(h.mail);
    const other = await h.call("POST", "/v1/auth/email/verify", { body: { email: "b@example.com", code, nonce: start.json.nonce } });
    expect(other.status).toBe(401);
    h.clock.now += 10 * 60 * 1000 + 1;
    const expired = await h.call("POST", "/v1/auth/email/verify", { body: { email: "a@example.com", code, nonce: start.json.nonce } });
    expect(expired.status).toBe(401);
  });

  it("limits codes per email per hour", async () => {
    const h = harness();
    for (let i = 0; i < 5; i++) expect((await h.call("POST", "/v1/auth/email/start", { body: { email: "a@example.com" } })).status).toBe(200);
    const limited = await h.call("POST", "/v1/auth/email/start", { body: { email: "a@example.com" } });
    expect(limited.status).toBe(429);
    expect(limited.headers.get("retry-after")).toBe("3600");
    h.clock.now += 60 * 60 * 1000 + 1;
    expect((await h.call("POST", "/v1/auth/email/start", { body: { email: "a@example.com" } })).status).toBe(200);
  });

  it("validates input and reports unconfigured email", async () => {
    const h = harness();
    expect((await h.call("POST", "/v1/auth/email/start", { body: { email: "nope" } })).status).toBe(400);
    expect((await h.call("POST", "/v1/auth/email/start", { body: {} })).status).toBe(400);
    h.setMailEnabled(false);
    const res = await h.call("POST", "/v1/auth/email/start", { body: { email: "a@example.com" } });
    expect(res.status).toBe(503);
    expect(res.json.error.code).toBe("unavailable");
  });
});

describe("test sign-in", () => {
  it("is absent without TEST_LOGIN_SECRET", async () => {
    const h = harness();
    expect((await h.call("POST", "/v1/auth/test", { body: { email: "bot@test.cmux.dev", secret: "x" } })).status).toBe(404);
  });

  it("issues tokens for the right secret and allowed domains only", async () => {
    const h = harness({ TEST_LOGIN_SECRET: "s3cret" });
    expect((await h.call("POST", "/v1/auth/test", { body: { email: "bot@test.cmux.dev", secret: "wrong" } })).status).toBe(401);
    expect((await h.call("POST", "/v1/auth/test", { body: { email: "victim@example.com", secret: "s3cret" } })).status).toBe(403);
    const ok = await h.call("POST", "/v1/auth/test", { body: { email: "bot@test.cmux.dev", secret: "s3cret" } });
    expect(ok.status).toBe(200);
    expect(ok.json.user.email).toBe("bot@test.cmux.dev");
  });
});

describe("refresh tokens", () => {
  it("rotates; a retry within 30 s returns the same pair; later reuse revokes the family", async () => {
    const h = harness();
    const first = await emailLogin(h);
    const second = await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: first.refreshToken } });
    expect(second.status).toBe(200);
    expect(second.json.refreshToken).not.toBe(first.refreshToken);
    expect(second.json.user.id).toBe(first.user.id);

    // Stored hashed.
    expect(h.repo.refreshTokens.has(first.refreshToken)).toBe(false);

    // Idempotent retry (lost response) inside the grace window.
    h.clock.now += 20 * 1000;
    const retry = await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: first.refreshToken } });
    expect(retry.status).toBe(200);
    expect(retry.json).toEqual(second.json);

    // After the window, replaying the old token is reuse: it fails and kills the new one too.
    h.clock.now += 11 * 1000;
    expect((await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: first.refreshToken } })).status).toBe(401);
    expect((await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: second.json.refreshToken } })).status).toBe(401);
  });

  it("concurrent refreshes of one token both succeed with the same pair", async () => {
    const h = harness();
    const t = await emailLogin(h);
    const [a, b] = await Promise.all([
      h.call("POST", "/v1/auth/refresh", { body: { refreshToken: t.refreshToken } }),
      h.call("POST", "/v1/auth/refresh", { body: { refreshToken: t.refreshToken } }),
    ]);
    expect(a.status).toBe(200);
    expect(b.json).toEqual(a.json);
    expect((await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: a.json.refreshToken } })).status).toBe(200);
  });

  it("a grace retry fails once the successor was itself rotated", async () => {
    const h = harness();
    const t = await emailLogin(h);
    const second = await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: t.refreshToken } });
    expect((await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: second.json.refreshToken } })).status).toBe(200);
    expect((await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: t.refreshToken } })).status).toBe(401);
  });

  it("rejects unknown and expired tokens", async () => {
    const h = harness();
    expect((await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: "rt_nope" } })).status).toBe(401);
    const t = await emailLogin(h);
    h.clock.now += 61 * 24 * 60 * 60 * 1000;
    expect((await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: t.refreshToken } })).status).toBe(401);
  });

  it("revoked families lose their access tokens (logout and reuse)", async () => {
    const h = harness();
    const t = await emailLogin(h);
    expect((await h.call("GET", "/v1/me", { token: t.accessToken })).status).toBe(200);
    await h.call("POST", "/v1/auth/logout", { token: t.accessToken, body: { refreshToken: t.refreshToken } });
    const me = await h.call("GET", "/v1/me", { token: t.accessToken });
    expect(me.status).toBe(401);
    expect(me.json.error.message).toBe("session revoked");

    const u = await emailLogin(h);
    const r1 = await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: u.refreshToken } });
    expect((await h.call("GET", "/v1/me", { token: r1.json.accessToken })).status).toBe(200);
    h.clock.now += 31 * 1000;
    expect((await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: u.refreshToken } })).status).toBe(401);
    expect((await h.call("GET", "/v1/me", { token: r1.json.accessToken })).status).toBe(401);
    // Another sign-in of the same user is unaffected.
    const other = await emailLogin(h);
    expect((await h.call("GET", "/v1/me", { token: other.accessToken })).status).toBe(200);
  });

  it("another isolate's revocation is seen within the 30 s cache TTL", async () => {
    const h = harness();
    const t = await emailLogin(h);
    expect((await h.call("GET", "/v1/me", { token: t.accessToken })).status).toBe(200);
    // Revoke in the database only (as another isolate would).
    const family = [...h.repo.refreshTokens.values()].find((r) => r.userId === t.user.id)!.familyId;
    await h.repo.revokeRefreshFamily(family, h.clock.now);
    h.clock.now += 31 * 1000;
    expect((await h.call("GET", "/v1/me", { token: t.accessToken })).status).toBe(401);
  });

  it("logout revokes the family, with no grace", async () => {
    const h = harness();
    const t = await emailLogin(h);
    const rotated = await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: t.refreshToken } });
    expect((await h.call("POST", "/v1/auth/logout", { token: t.accessToken, body: { refreshToken: rotated.json.refreshToken } })).status).toBe(200);
    expect((await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: rotated.json.refreshToken } })).status).toBe(401);
    // Even the grace retry of the older token is refused: its successor is revoked.
    expect((await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: t.refreshToken } })).status).toBe(401);
  });
});

describe("/me", () => {
  it("requires a valid, unexpired access token", async () => {
    const h = harness();
    expect((await h.call("GET", "/v1/me")).status).toBe(401);
    const t = await emailLogin(h);
    const me = await h.call("GET", "/v1/me", { token: t.accessToken });
    expect(me.json).toEqual({ user: { id: t.user.id, email: "a@example.com", name: null } });
    h.clock.now += 15 * 60 * 1000 + 1;
    expect((await h.call("GET", "/v1/me", { token: t.accessToken })).status).toBe(401);
  });

  it("delete removes the account and its sessions", async () => {
    const h = harness();
    const t = await emailLogin(h);
    expect((await h.call("DELETE", "/v1/me", { token: t.accessToken })).status).toBe(200);
    expect((await h.call("GET", "/v1/me", { token: t.accessToken })).status).toBe(404);
    expect((await h.call("POST", "/v1/auth/refresh", { body: { refreshToken: t.refreshToken } })).status).toBe(401);
  });
});

describe("Sign in with Apple", () => {
  const RAW = "raw-nonce-123";
  let HASHED = "";
  const appleHarness = () => harness({ APPLE_AUDIENCES: "dev.cmux.next.drawer,dev.cmux.next.tabs" });
  let keys: CryptoKeyPair;
  let jwk: JsonWebKey;

  beforeEach(async () => {
    resetAppleJwksCache();
    HASHED = await sha256Hex(RAW);
    keys = (await crypto.subtle.generateKey(
      { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
      true,
      ["sign", "verify"],
    )) as CryptoKeyPair;
    jwk = (await crypto.subtle.exportKey("jwk", keys.publicKey)) as JsonWebKey;
  });

  async function appleToken(claims: Record<string, unknown>, kid = "k1") {
    const enc = new TextEncoder();
    const header = base64url(enc.encode(JSON.stringify({ alg: "RS256", kid })));
    const body = base64url(enc.encode(JSON.stringify(claims)));
    const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", keys.privateKey, enc.encode(`${header}.${body}`));
    return `${header}.${body}.${base64url(new Uint8Array(sig))}`;
  }

  function withJwks(h: ReturnType<typeof harness>) {
    h.onFetch((url) => (url === "https://appleid.apple.com/auth/keys" ? Response.json({ keys: [{ ...jwk, kid: "k1", alg: "RS256", use: "sig" }] }) : undefined));
  }

  const base = (h: ReturnType<typeof harness>) => ({
    iss: "https://appleid.apple.com",
    aud: "dev.cmux.next.tabs",
    sub: "apple-sub-1",
    email: "a@example.com",
    email_verified: "true",
    nonce: HASHED,
    iat: Math.floor(h.clock.now / 1000),
    exp: Math.floor(h.clock.now / 1000) + 600,
  });

  it("verifies the token, creates the user and stores the name", async () => {
    const h = appleHarness();
    withJwks(h);
    const res = await h.call("POST", "/v1/auth/apple", {
      body: { nonce: RAW, identityToken: await appleToken(base(h)), fullName: { givenName: "Ada", familyName: "Lovelace" } },
    });
    expect(res.status).toBe(200);
    expect(res.json.user).toMatchObject({ email: "a@example.com", name: "Ada Lovelace" });

    // Second sign-in without email/name maps to the same user.
    const { email: _e, ...noEmail } = base(h);
    const again = await h.call("POST", "/v1/auth/apple", { body: { nonce: RAW, identityToken: await appleToken(noEmail) } });
    expect(again.json.user.id).toBe(res.json.user.id);
  });

  it("links to an existing email account when the email is verified", async () => {
    const h = appleHarness();
    withJwks(h);
    const emailUser = await emailLogin(h, "a@example.com");
    const res = await h.call("POST", "/v1/auth/apple", { body: { nonce: RAW, identityToken: await appleToken(base(h)) } });
    expect(res.json.user.id).toBe(emailUser.user.id);
  });

  it("accepts the drawer bundle id and rejects other audiences, issuers, expiry and signatures", async () => {
    const h = appleHarness();
    withJwks(h);
    expect((await h.call("POST", "/v1/auth/apple", { body: { nonce: RAW, identityToken: await appleToken({ ...base(h), aud: "dev.cmux.next.drawer" }) } })).status).toBe(200);
    expect((await h.call("POST", "/v1/auth/apple", { body: { nonce: RAW, identityToken: await appleToken({ ...base(h), aud: "com.evil.app" }) } })).status).toBe(401);
    expect((await h.call("POST", "/v1/auth/apple", { body: { nonce: RAW, identityToken: await appleToken({ ...base(h), iss: "https://evil" }) } })).status).toBe(401);
    expect((await h.call("POST", "/v1/auth/apple", { body: { nonce: RAW, identityToken: await appleToken({ ...base(h), exp: 1 }) } })).status).toBe(401);
    const good = await appleToken(base(h));
    const tampered = good.slice(0, good.lastIndexOf(".")) + "." + base64url(new Uint8Array(256));
    expect((await h.call("POST", "/v1/auth/apple", { body: { nonce: RAW, identityToken: tampered } })).status).toBe(401);
    expect((await h.call("POST", "/v1/auth/apple", { body: { nonce: RAW, identityToken: await appleToken(base(h), "unknown-kid") } })).status).toBe(401);
    expect((await h.call("POST", "/v1/auth/apple", { body: { nonce: RAW, identityToken: "garbage" } })).status).toBe(401);
  });

  it("requires and checks a nonce", async () => {
    const h = appleHarness();
    withJwks(h);
    const post = async (claims: Record<string, unknown>, nonce?: string) =>
      (await h.call("POST", "/v1/auth/apple", { body: { identityToken: await appleToken(claims), ...(nonce ? { nonce } : {}) } })).status;
    expect(await post({ ...base(h), nonce: HASHED }, RAW)).toBe(200);
    expect(await post({ ...base(h), nonce: RAW }, RAW)).toBe(200);
    expect(await post({ ...base(h), nonce: HASHED }, "other")).toBe(401);
    const { nonce: _n, ...noNonce } = base(h);
    expect(await post(noNonce, RAW)).toBe(401);
    // Missing nonce: refused.
    expect(await post(base(h))).toBe(501);
  });

  it("is unsupported unless APPLE_AUDIENCES is configured", async () => {
    const h = harness({ APPLE_AUDIENCES: "" });
    const res = await h.call("POST", "/v1/auth/apple", { body: { identityToken: "x", nonce: RAW } });
    expect(res.status).toBe(501);
    expect(res.json.error.code).toBe("unsupported");
  });
});

describe("OAuth web flows", () => {
  it("answers unsupported when the provider is not configured", async () => {
    const h = harness();
    const res = await h.call("GET", `/v1/auth/oauth/github/start?redirect=cmux-next://auth&code_challenge=${"a".repeat(43)}`);
    expect(res.status).toBe(501);
    expect(res.json.error.code).toBe("unsupported");
    expect((await h.call("GET", "/v1/auth/oauth/myspace/start?redirect=cmux-next://auth")).status).toBe(404);
  });

  function githubHarness() {
    const h = harness({ GITHUB_CLIENT_ID: "gh-id", GITHUB_CLIENT_SECRET: "gh-secret" });
    h.onFetch((url, init) => {
      if (url === "https://github.com/login/oauth/access_token") {
        const body = JSON.parse(String(init?.body));
        return Response.json(body.code === "good" ? { access_token: "gho_x" } : { error: "bad_verification_code" });
      }
      if (url === "https://api.github.com/user") return Response.json({ id: 42, login: "octo", name: "Octo Cat" });
      if (url === "https://api.github.com/user/emails") return Response.json([{ email: "octo@example.com", primary: true, verified: true }]);
      return undefined;
    });
    return h;
  }

  it("runs start -> callback -> exchange with PKCE", async () => {
    const h = githubHarness();
    const verifier = "v".repeat(64);
    const challenge = await sha256Base64url(verifier);
    const start = await h.call("GET", `/v1/auth/oauth/github/start?redirect=${encodeURIComponent("cmux-next://auth/done")}&code_challenge=${challenge}`);
    expect(start.status).toBe(302);
    const authorize = new URL(start.headers.get("location")!);
    expect(authorize.origin + authorize.pathname).toBe("https://github.com/login/oauth/authorize");
    expect(authorize.searchParams.get("client_id")).toBe("gh-id");
    expect(authorize.searchParams.get("redirect_uri")).toBe("https://api.test/v1/auth/oauth/github/callback");
    const state = authorize.searchParams.get("state")!;

    const cb = await h.call("GET", `/v1/auth/oauth/github/callback?code=good&state=${encodeURIComponent(state)}`);
    expect(cb.status).toBe(302);
    const back = new URL(cb.headers.get("location")!);
    expect(back.protocol).toBe("cmux-next:");
    const code = back.searchParams.get("code")!;
    expect(code).toMatch(/^oc_/);

    expect((await h.call("POST", "/v1/auth/oauth/exchange", { body: { code } })).status).toBe(400);
    expect((await h.call("POST", "/v1/auth/oauth/exchange", { body: { code, codeVerifier: "wrong".repeat(10) } })).status).toBe(401);
    // A failed verifier consumed the code; run the callback again for a fresh one.
    const cb2 = await h.call("GET", `/v1/auth/oauth/github/callback?code=good&state=${encodeURIComponent(state)}`);
    const code2 = new URL(cb2.headers.get("location")!).searchParams.get("code")!;
    const tokens = await h.call("POST", "/v1/auth/oauth/exchange", { body: { code: code2, codeVerifier: verifier } });
    expect(tokens.status).toBe(200);
    expect(tokens.json.user).toMatchObject({ email: "octo@example.com", name: "Octo Cat" });
    expect((await h.call("POST", "/v1/auth/oauth/exchange", { body: { code: code2, codeVerifier: verifier } })).status).toBe(401);
  });

  it("rejects non-app redirect schemes and bad state, and reports provider errors to the app", async () => {
    const h = githubHarness();
    const cc = `&code_challenge=${await sha256Base64url("v".repeat(64))}`;
    expect((await h.call("GET", `/v1/auth/oauth/github/start?redirect=${encodeURIComponent("https://evil.example/cb")}${cc}`)).status).toBe(400);
    // PKCE S256 is mandatory.
    expect((await h.call("GET", `/v1/auth/oauth/github/start?redirect=${encodeURIComponent("cmux-next://auth")}`)).status).toBe(400);
    expect((await h.call("GET", `/v1/auth/oauth/github/start?redirect=${encodeURIComponent("cmux-next://auth")}${cc}&code_challenge_method=plain`)).status).toBe(400);
    expect((await h.call("GET", "/v1/auth/oauth/github/callback?code=good&state=forged")).status).toBe(400);
    const start = await h.call("GET", `/v1/auth/oauth/github/start?redirect=${encodeURIComponent("cmux-next://auth")}${cc}`);
    const state = new URL(start.headers.get("location")!).searchParams.get("state")!;
    const cb = await h.call("GET", `/v1/auth/oauth/github/callback?code=bad&state=${encodeURIComponent(state)}`);
    expect(new URL(cb.headers.get("location")!).searchParams.get("error")).toBe("server_error");
    const denied = await h.call("GET", `/v1/auth/oauth/github/callback?error=access_denied&state=${encodeURIComponent(state)}`);
    expect(new URL(denied.headers.get("location")!).searchParams.get("error")).toBe("access_denied");
  });

  it("supports Google via userinfo", async () => {
    const h = harness({ GOOGLE_CLIENT_ID: "g-id", GOOGLE_CLIENT_SECRET: "g-secret" });
    h.onFetch((url) => {
      if (url === "https://oauth2.googleapis.com/token") return Response.json({ access_token: "ya29" });
      if (url === "https://openidconnect.googleapis.com/v1/userinfo") return Response.json({ sub: "g1", email: "g@example.com", email_verified: true, name: "Gee" });
      return undefined;
    });
    const verifier = "g".repeat(50);
    const start = await h.call(
      "GET",
      `/v1/auth/oauth/google/start?redirect=${encodeURIComponent("dev.cmux.next.tabs://oauth")}&code_challenge=${await sha256Base64url(verifier)}&code_challenge_method=S256`,
    );
    const authorize = new URL(start.headers.get("location")!);
    expect(authorize.hostname).toBe("accounts.google.com");
    const cb = await h.call("GET", `/v1/auth/oauth/google/callback?code=c&state=${encodeURIComponent(authorize.searchParams.get("state")!)}`);
    const code = new URL(cb.headers.get("location")!).searchParams.get("code")!;
    const tokens = await h.call("POST", "/v1/auth/oauth/exchange", { body: { code, codeVerifier: verifier } });
    expect(tokens.json.user).toMatchObject({ email: "g@example.com", name: "Gee" });
  });
});

describe("resolveUser concurrency", () => {
  it("concurrent first sign-ins with one identity yield one user", async () => {
    const { resolveUser } = await import("../src/auth");
    const { MemoryRepo } = await import("../src/repo/memory");
    const repo = new MemoryRepo();
    // Make every read miss once so both callers try to create.
    const getUserByEmail = repo.getUserByEmail.bind(repo);
    const findIdentity = repo.findIdentityUserId.bind(repo);
    let emailMisses = 2;
    let identityMisses = 2;
    repo.getUserByEmail = async (e) => (emailMisses-- > 0 ? null : getUserByEmail(e));
    repo.findIdentityUserId = async (p, s) => (identityMisses-- > 0 ? null : findIdentity(p, s));
    const id = { provider: "stack:p", subject: "same", email: "race@example.com", emailVerified: true, name: "R" };
    const [a, b] = await Promise.all([resolveUser(repo, id, 1), resolveUser(repo, id, 1)]);
    expect(a.id).toBe(b.id);
    expect(repo.users.size).toBe(1);
    expect(repo.identities.size).toBe(1);
  });

  it("concurrent identity link without email cleans up the losing user", async () => {
    const { resolveUser } = await import("../src/auth");
    const { MemoryRepo } = await import("../src/repo/memory");
    const repo = new MemoryRepo();
    const findIdentity = repo.findIdentityUserId.bind(repo);
    let misses = 2;
    repo.findIdentityUserId = async (p, s) => (misses-- > 0 ? null : findIdentity(p, s));
    const id = { provider: "apple", subject: "x", email: null, emailVerified: false, name: null };
    const [a, b] = await Promise.all([resolveUser(repo, id, 1), resolveUser(repo, id, 1)]);
    expect(a.id).toBe(b.id);
    expect(repo.users.size).toBe(1);
  });
});
