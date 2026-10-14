import { beforeEach, describe, expect, it } from "vitest";
import { base64url } from "../src/crypto";
import { resetStackJwksCache } from "../src/stack";
import { emailLogin, harness } from "./helpers";

const PROD = "9790718f-14cd-4f7e-824d-eaf527a82b82";
const DEV = "454ecd03-1db2-4050-845e-4ce5b0cd9895";

describe("Stack Auth sign-in", () => {
  let keys: CryptoKeyPair;
  let jwk: JsonWebKey;

  beforeEach(async () => {
    resetStackJwksCache();
    keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
    jwk = (await crypto.subtle.exportKey("jwk", keys.publicKey)) as JsonWebKey;
  });

  async function stackToken(claims: Record<string, unknown>, kid = "s1") {
    const enc = new TextEncoder();
    const header = base64url(enc.encode(JSON.stringify({ alg: "ES256", kid })));
    const body = base64url(enc.encode(JSON.stringify(claims)));
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys.privateKey, enc.encode(`${header}.${body}`));
    return `${header}.${body}.${base64url(new Uint8Array(sig))}`;
  }

  function setup(envOverrides: Record<string, string> = {}, usersMe?: Record<string, unknown>) {
    const h = harness(envOverrides);
    h.onFetch((url, init) => {
      if (url.endsWith("/.well-known/jwks.json") && url.startsWith("https://api.stack-auth.com/api/v1/projects/")) {
        return Response.json({ keys: [{ ...jwk, kid: "s1", alg: "ES256" }] });
      }
      if (url === "https://api.stack-auth.com/api/v1/users/me") {
        const hd = new Headers(init?.headers);
        expect(hd.get("x-stack-access-type")).toBe("client");
        expect(hd.get("x-stack-access-token")).toBeTruthy();
        return usersMe ? Response.json(usersMe) : new Response("{}", { status: 401 });
      }
      return undefined;
    });
    return h;
  }

  const claims = (h: ReturnType<typeof harness>, project = PROD) => ({
    iss: `https://api.stack-auth.com/api/v1/projects/${project}`,
    aud: project,
    sub: "stack-user-1",
    email: "s@example.com",
    email_verified: true,
    name: "Stacy",
    iat: Math.floor(h.clock.now / 1000),
    exp: Math.floor(h.clock.now / 1000) + 600,
  });

  it("exchanges a valid prod token for Tokens and maps repeat sign-ins to one user", async () => {
    const h = setup();
    const res = await h.call("POST", "/v1/auth/stack", { body: { accessToken: await stackToken(claims(h)), projectId: PROD } });
    expect(res.status).toBe(200);
    expect(res.json.user).toMatchObject({ email: "s@example.com", name: "Stacy" });
    expect(res.json.refreshToken).toMatch(/^rt_/);
    expect(h.repo.identities.get(`stack:${PROD}:stack-user-1`)?.userId).toBe(res.json.user.id);
    const again = await h.call("POST", "/v1/auth/stack", { body: { accessToken: await stackToken(claims(h)), projectId: PROD } });
    expect(again.json.user.id).toBe(res.json.user.id);
    // JWKS is cached.
    expect(h.outbound.filter((o) => o.url.endsWith("jwks.json"))).toHaveLength(1);
  });

  it("links prod sign-ins to an existing account by verified email", async () => {
    const h = setup();
    const existing = await emailLogin(h, "s@example.com");
    const res = await h.call("POST", "/v1/auth/stack", { body: { accessToken: await stackToken(claims(h)), projectId: PROD } });
    expect(res.json.user.id).toBe(existing.user.id);
  });

  it("accepts the dev project as a separate identity that never links by email", async () => {
    const h = setup({ DEV_STACK_ENABLED: "true", STACK_DEV_PROJECT_ID: DEV });
    const existing = await emailLogin(h, "s@example.com");
    const res = await h.call("POST", "/v1/auth/stack", { body: { accessToken: await stackToken(claims(h, DEV)), projectId: DEV } });
    expect(res.status).toBe(200);
    expect(res.json.user.id).not.toBe(existing.user.id);
    expect(res.json.user.email).toBeNull();
    expect(h.repo.identities.get(`stack:${DEV}:stack-user-1`)?.userId).toBe(res.json.user.id);
    // Same Stack user id in prod is a different identity.
    const prod = await h.call("POST", "/v1/auth/stack", { body: { accessToken: await stackToken(claims(h)), projectId: PROD } });
    expect(prod.json.user.id).toBe(existing.user.id);
  });

  it("refuses the dev project unless DEV_STACK_ENABLED is true (production config)", async () => {
    const h = setup({ STACK_DEV_PROJECT_ID: DEV });
    expect((await h.call("POST", "/v1/auth/stack", { body: { accessToken: await stackToken(claims(h, DEV)), projectId: DEV } })).status).toBe(400);
    expect((await h.call("POST", "/v1/auth/stack", { body: { accessToken: await stackToken(claims(h)), projectId: PROD } })).status).toBe(200);
  });

  it("verifies RS256 tokens too", async () => {
    const h = harness();
    const rsa = (await crypto.subtle.generateKey(
      { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
      true,
      ["sign", "verify"],
    )) as CryptoKeyPair;
    const pub = (await crypto.subtle.exportKey("jwk", rsa.publicKey)) as JsonWebKey;
    h.onFetch((url) => (url.endsWith("/.well-known/jwks.json") ? Response.json({ keys: [{ ...pub, kid: "r1", alg: "RS256" }] }) : undefined));
    const enc = new TextEncoder();
    const header = base64url(enc.encode(JSON.stringify({ alg: "RS256", kid: "r1" })));
    const body = base64url(enc.encode(JSON.stringify(claims(h))));
    const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", rsa.privateKey, enc.encode(`${header}.${body}`));
    const res = await h.call("POST", "/v1/auth/stack", { body: { accessToken: `${header}.${body}.${base64url(new Uint8Array(sig))}`, projectId: PROD } });
    expect(res.status).toBe(200);
  });

  it("fetches users/me when the token has no email", async () => {
    const h = setup({}, { primary_email: "me@example.com", primary_email_verified: true, display_name: "Me" });
    const { email: _e, name: _n, ...noEmail } = claims(h);
    const res = await h.call("POST", "/v1/auth/stack", { body: { accessToken: await stackToken(noEmail), projectId: PROD } });
    expect(res.json.user).toMatchObject({ email: "me@example.com", name: "Me" });
  });

  it("rejects disallowed projects, wrong iss/aud, expiry, anonymous users and bad signatures", async () => {
    const h = setup();
    const ok = claims(h);
    const post = async (token: string, projectId = PROD) => (await h.call("POST", "/v1/auth/stack", { body: { accessToken: token, projectId } })).status;
    expect(await post(await stackToken(ok), "other-project")).toBe(400);
    expect(await post(await stackToken({ ...ok, iss: "https://evil" }))).toBe(401);
    expect(await post(await stackToken({ ...ok, aud: DEV }))).toBe(401);
    // A dev token presented as prod fails the issuer check.
    expect(await post(await stackToken(claims(h, DEV)))).toBe(401);
    expect(await post(await stackToken({ ...ok, exp: Math.floor(h.clock.now / 1000) - 120 }))).toBe(401);
    expect(await post(await stackToken({ ...ok, is_anonymous: true }))).toBe(401);
    expect(await post(await stackToken(ok, "unknown"))).toBe(401);
    const good = await stackToken(ok);
    expect(await post(good.slice(0, good.lastIndexOf(".")) + "." + base64url(new Uint8Array(64)))).toBe(401);
    expect(await post("garbage")).toBe(401);
    expect((await h.call("POST", "/v1/auth/stack", { body: { projectId: PROD } })).status).toBe(400);
  });
});
