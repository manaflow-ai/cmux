import { describe, expect, test } from "bun:test";
import { createHash, randomBytes } from "node:crypto";
import { NextRequest } from "next/server";
import {
  createMemoryHandoffCodeStore,
  HANDOFF_CODE_MAX_TTL_MS,
  sweepExpiredHandoffCodes,
  redeemHandoffCode,
  s256Challenge,
  sha256Hex,
} from "../app/lib/handoff-codes";
import {
  consoleSignInClient,
  consoleSignInRateLimitId,
  makeConsoleSignInAuthorizeHandler,
  makeConsoleSignInTokenHandler,
  type ConsoleSignInUser,
} from "../services/auth/consoleSignIn";

const PROD_SECRET = "p".repeat(40);
const STAGING_SECRET = "s".repeat(40);
const secrets = { production: PROD_SECRET, staging: STAGING_SECRET };
const NOW = 1_800_000_000_000;

const verifier = () => randomBytes(32).toString("base64url");
const state = () => randomBytes(16).toString("base64url");

function setup(options: { user?: ConsoleSignInUser | null; now?: () => number } = {}) {
  const store = createMemoryHandoffCodeStore();
  let clock = NOW;
  const now = options.now ?? (() => clock);
  const minted: string[] = [];
  const authorize = makeConsoleSignInAuthorizeHandler({
    store,
    secrets,
    currentUser: async () => (options.user === undefined ? { id: "user-1" } : options.user),
    origin: (request) => `https://${request.headers.get("host")}`,
    now,
    isVercel: () => false,
  });
  const token = makeConsoleSignInTokenHandler({
    store,
    secrets,
    mintSession: async (userId) => {
      minted.push(userId);
      return { accessToken: `access-for-${userId}`, refreshToken: `refresh-for-${userId}` };
    },
    now,
  });
  return { store, authorize, token, minted, advance: (ms: number) => (clock += ms) };
}

function authorizeRequest(host: string, params: Record<string, string>): NextRequest {
  const url = new URL(`https://${host}/handler/console-sign-in`);
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
  return new NextRequest(url, { headers: { host } });
}

function tokenRequest(host: string, body: Record<string, string>, headers: Record<string, string> = {}): NextRequest {
  return new NextRequest(`https://${host}/handler/console-sign-in/token`, {
    method: "POST",
    headers: { host, "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

async function issue(env: ReturnType<typeof setup>, host = "cmux.com", clientId = "cmux-console") {
  const codeVerifier = verifier();
  const flowState = state();
  const response = await env.authorize(
    authorizeRequest(host, { client_id: clientId, state: flowState, code_challenge: s256Challenge(codeVerifier), code_challenge_method: "S256" }),
  );
  return { response, codeVerifier, flowState, location: response.headers.get("location") };
}

const codeFrom = (location: string | null) => new URL(location!).searchParams.get("code")!;

describe("console sign-in authorize", () => {
  test("issues a one-time code to the fixed redirect URI with the same state", async () => {
    const env = setup();
    const { response, flowState, location } = await issue(env);
    expect(response.status).toBe(303);
    const target = new URL(location!);
    expect(`${target.origin}${target.pathname}`).toBe("https://console.cmux.dev/auth/handoff");
    expect(target.searchParams.get("state")).toBe(flowState);
    const code = target.searchParams.get("code")!;
    expect(Buffer.from(code, "base64url").byteLength).toBe(32);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
    // Stored hashed, short-lived, bound to the user, client, redirect URI and challenge.
    const row = env.store.rows.get(sha256Hex(code))!;
    expect(row).toBeDefined();
    expect([...env.store.rows.keys()]).not.toContain(code);
    expect(row.userId).toBe("user-1");
    expect(row.clientId).toBe("cmux-console");
    expect(row.redirectUri).toBe("https://console.cmux.dev/auth/handoff");
    expect(row.expiresAt.getTime() - NOW).toBeLessThanOrEqual(HANDOFF_CODE_MAX_TTL_MS);
  });

  test("never takes the redirect URI from the request", async () => {
    const env = setup();
    const codeVerifier = verifier();
    const response = await env.authorize(
      authorizeRequest("cmux.com", {
        client_id: "cmux-console",
        state: state(),
        code_challenge: s256Challenge(codeVerifier),
        code_challenge_method: "S256",
        redirect_uri: "https://evil.example/steal",
      }),
    );
    expect(new URL(response.headers.get("location")!).origin).toBe("https://console.cmux.dev");
  });

  test("production issues only to the production console, staging only to the staging console", async () => {
    expect(consoleSignInClient("cmux-console", "cmux.com", secrets)?.redirectUri).toBe("https://console.cmux.dev/auth/handoff");
    expect(consoleSignInClient("cmux-console-staging", "cmux-staging.vercel.app", secrets)?.redirectUri).toBe("https://console-staging.cmux.dev/auth/handoff");
    expect(consoleSignInClient("cmux-console-staging", "cmux.com", secrets)).toBeNull();
    expect(consoleSignInClient("cmux-console", "cmux-staging.vercel.app", secrets)).toBeNull();
    expect(consoleSignInClient("cmux-console", "localhost", secrets)).toBeNull();
    expect(consoleSignInClient("cmux-console", "www.cmux.com", secrets)).toBeNull();
    expect(consoleSignInClient("cmux-console", "preview-abc.vercel.app", secrets)).toBeNull();
    expect(consoleSignInClient("other", "cmux.com", secrets)).toBeNull();
    // A client without its secret on this deployment is off.
    expect(consoleSignInClient("cmux-console", "cmux.com", { staging: STAGING_SECRET })).toBeNull();
    expect(consoleSignInClient("cmux-console", "cmux.com", { production: "short" })).toBeNull();

    const env = setup();
    const crossed = await issue(env, "cmux.com", "cmux-console-staging");
    expect(crossed.response.status).toBe(400);
    expect(crossed.location).toBeNull();
    const crossedBack = await issue(env, "cmux-staging.vercel.app", "cmux-console");
    expect(crossedBack.response.status).toBe(400);
    const staging = await issue(env, "cmux-staging.vercel.app", "cmux-console-staging");
    expect(new URL(staging.location!).origin).toBe("https://console-staging.cmux.dev");
    expect(env.store.rows.size).toBe(1);
  });

  test("refuses a missing state, a plain challenge or a non-S256 method with one generic page", async () => {
    const env = setup();
    const challenge = s256Challenge(verifier());
    const bad: Record<string, string>[] = [
      { client_id: "cmux-console", code_challenge: challenge, code_challenge_method: "S256" },
      { client_id: "cmux-console", state: "short", code_challenge: challenge, code_challenge_method: "S256" },
      { client_id: "cmux-console", state: state(), code_challenge: challenge, code_challenge_method: "plain" },
      { client_id: "cmux-console", state: state(), code_challenge: "abc", code_challenge_method: "S256" },
    ];
    const bodies = new Set<string>();
    for (const params of bad) {
      const response = await env.authorize(authorizeRequest("cmux.com", params));
      expect(response.status).toBe(400);
      expect(response.headers.get("location")).toBeNull();
      bodies.add(await response.text());
    }
    expect(bodies.size).toBe(1);
    expect(env.store.rows.size).toBe(0);
  });

  test("a signed-out or anonymous person goes through sign-in and back with the same parameters", async () => {
    for (const user of [null, { id: "anon", isAnonymous: true }]) {
      const env = setup({ user });
      const { response, flowState } = await issue(env);
      expect(response.status).toBe(303);
      const location = new URL(response.headers.get("location")!);
      expect(`${location.origin}${location.pathname}`).toBe("https://cmux.com/handler/sign-in");
      const back = new URL(location.searchParams.get("after_auth_return_to")!, "https://cmux.com");
      expect(back.pathname).toBe("/handler/console-sign-in");
      expect(back.searchParams.get("client_id")).toBe("cmux-console");
      expect(back.searchParams.get("state")).toBe(flowState);
      expect(back.searchParams.get("code_challenge_method")).toBe("S256");
      expect(env.store.rows.size).toBe(0);
    }
  });

  test("fails closed on Vercel without a rate limiter, and when the limiter says so", async () => {
    const base = { store: createMemoryHandoffCodeStore(), secrets, currentUser: async () => ({ id: "u" }), origin: () => "https://cmux.com", isVercel: () => true };
    const params = { client_id: "cmux-console", state: state(), code_challenge: s256Challenge(verifier()), code_challenge_method: "S256" };
    expect((await makeConsoleSignInAuthorizeHandler(base)(authorizeRequest("cmux.com", params))).status).toBe(429);
    const limited = makeConsoleSignInAuthorizeHandler({ ...base, rateLimitId: "rl", checkRateLimit: async () => ({ rateLimited: true, error: undefined }) as never });
    expect((await limited(authorizeRequest("cmux.com", params))).status).toBe(429);
    const open = makeConsoleSignInAuthorizeHandler({ ...base, rateLimitId: "rl", checkRateLimit: async () => ({ rateLimited: false, error: undefined }) as never });
    expect((await open(authorizeRequest("cmux.com", params))).status).toBe(303);
  });
});

describe("console sign-in token", () => {
  const redeemBody = (code: string, codeVerifier: string, overrides: Record<string, string> = {}) => ({
    client_id: "cmux-console",
    client_secret: PROD_SECRET,
    code,
    code_verifier: codeVerifier,
    redirect_uri: "https://console.cmux.dev/auth/handoff",
    ...overrides,
  });

  test("redeems a code once for a fresh session in the body", async () => {
    const env = setup();
    const { location, codeVerifier } = await issue(env);
    const response = await env.token(tokenRequest("cmux.com", redeemBody(codeFrom(location), codeVerifier)));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ access_token: "access-for-user-1", refresh_token: "refresh-for-user-1" });
    expect(env.minted).toEqual(["user-1"]);
  });

  test("a code cannot be used twice", async () => {
    const env = setup();
    const { location, codeVerifier } = await issue(env);
    const body = redeemBody(codeFrom(location), codeVerifier);
    expect((await env.token(tokenRequest("cmux.com", body))).status).toBe(200);
    const again = await env.token(tokenRequest("cmux.com", body));
    expect(again.status).toBe(400);
    expect(await again.json()).toEqual({ error: "invalid_grant" });
    expect(env.minted).toEqual(["user-1"]);
  });

  test("concurrent redemptions of one code mint one session", async () => {
    const env = setup();
    const { location, codeVerifier } = await issue(env);
    const body = redeemBody(codeFrom(location), codeVerifier);
    const results = await Promise.all(Array.from({ length: 5 }, () => env.token(tokenRequest("cmux.com", body))));
    expect(results.filter((r) => r.status === 200)).toHaveLength(1);
    expect(env.minted).toHaveLength(1);
  });

  test("an expired code is refused", async () => {
    const env = setup();
    const { location, codeVerifier } = await issue(env);
    env.advance(HANDOFF_CODE_MAX_TTL_MS);
    const response = await env.token(tokenRequest("cmux.com", redeemBody(codeFrom(location), codeVerifier)));
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_grant" });
    expect(env.minted).toEqual([]);
  });

  test("a wrong PKCE verifier is refused and burns the code", async () => {
    const env = setup();
    const { location, codeVerifier } = await issue(env);
    const code = codeFrom(location);
    const wrong = await env.token(tokenRequest("cmux.com", redeemBody(code, verifier())));
    expect(wrong.status).toBe(400);
    expect(await wrong.json()).toEqual({ error: "invalid_grant" });
    // The real verifier no longer works either: one wrong try burns the code.
    expect((await env.token(tokenRequest("cmux.com", redeemBody(code, codeVerifier)))).status).toBe(400);
    expect(env.minted).toEqual([]);
  });

  test("a wrong client secret is refused without consuming the code", async () => {
    const env = setup();
    const { location, codeVerifier } = await issue(env);
    const code = codeFrom(location);
    for (const client_secret of ["", "x".repeat(40), STAGING_SECRET, `${PROD_SECRET}x`]) {
      const response = await env.token(tokenRequest("cmux.com", redeemBody(code, codeVerifier, { client_secret })));
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: "invalid_client" });
    }
    expect((await env.token(tokenRequest("cmux.com", redeemBody(code, codeVerifier)))).status).toBe(200);
  });

  test("a code issued to one client or redirect URI is refused for another", async () => {
    const env = setup();
    const { location, codeVerifier } = await issue(env);
    const code = codeFrom(location);
    const otherUri = await env.token(tokenRequest("cmux.com", redeemBody(code, codeVerifier, { redirect_uri: "https://console-staging.cmux.dev/auth/handoff" })));
    expect(otherUri.status).toBe(400);

    const staging = await issue(env, "cmux-staging.vercel.app", "cmux-console-staging");
    // The production deployment never redeems for the staging client, even with its secret.
    const crossed = await env.token(
      tokenRequest("cmux.com", redeemBody(codeFrom(staging.location), staging.codeVerifier, { client_id: "cmux-console-staging", client_secret: STAGING_SECRET, redirect_uri: "https://console-staging.cmux.dev/auth/handoff" })),
    );
    expect(crossed.status).toBe(401);
    expect(env.minted).toEqual([]);
  });

  test("a browser request (with Origin) or a non-JSON body is refused", async () => {
    const env = setup();
    const { location, codeVerifier } = await issue(env);
    const body = redeemBody(codeFrom(location), codeVerifier);
    expect((await env.token(tokenRequest("cmux.com", body, { origin: "https://evil.example" }))).status).toBe(400);
    const form = new NextRequest("https://cmux.com/handler/console-sign-in/token", {
      method: "POST",
      headers: { host: "cmux.com", "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(body).toString(),
    });
    expect((await env.token(form)).status).toBe(400);
    const oversized = new NextRequest("https://cmux.com/handler/console-sign-in/token", {
      method: "POST",
      headers: { host: "cmux.com", "content-type": "application/json" },
      body: JSON.stringify({ ...body, padding: "x".repeat(16 * 1024) }),
    });
    oversized.headers.delete("content-length");
    expect((await env.token(oversized)).status).toBe(400);
    expect((await env.token(tokenRequest("cmux.com", body))).status).toBe(200);
  });
});

describe("handoff codes", () => {
  test("a failed cleanup sweep never fails issuing a code", async () => {
    await expect(sweepExpiredHandoffCodes(async () => { throw new Error("db down"); })).resolves.toBeUndefined();
    let ran = false;
    await sweepExpiredHandoffCodes(async () => { ran = true; });
    expect(ran).toBe(true);
  });

  test("a deployment uses only its own rate limiter; local runs may fall back", () => {
    expect(consoleSignInRateLimitId({ CMUX_FEEDBACK_RATE_LIMIT_ID: "feedback" }, true)).toBeUndefined();
    expect(consoleSignInRateLimitId({ CMUX_CONSOLE_SIGN_IN_RATE_LIMIT_ID: "console", CMUX_FEEDBACK_RATE_LIMIT_ID: "feedback" }, true)).toBe("console");
    expect(consoleSignInRateLimitId({ CMUX_FEEDBACK_RATE_LIMIT_ID: "feedback" }, false)).toBe("feedback");
  });

  test("S256 matches RFC 7636 appendix B", () => {
    expect(s256Challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")).toBe("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    expect(sha256Hex("abc")).toBe(createHash("sha256").update("abc").digest("hex"));
  });

  test("a malformed code never reaches the store", async () => {
    const store = createMemoryHandoffCodeStore();
    let consumed = 0;
    const counting = { ...store, consume: async (hash: string, now: Date) => (consumed++, store.consume(hash, now)) };
    const result = await redeemHandoffCode(counting, { code: "not a code", clientId: "c", redirectUri: "r", codeVerifier: verifier(), now: new Date(NOW) });
    expect(result).toEqual({ ok: false, reason: "malformed" });
    expect(consumed).toBe(0);
  });
});
