import { describe, expect, it } from "vitest";
import { signEs256 } from "../src/crypto";
import { Device, hubEnv, mockOutbound, outbound, rawCall, signIn, stackClaims, stackToken } from "./helpers";

describe("health", () => {
  it("answers without auth", async () => {
    const res = await rawCall("GET", "/v1/health");
    expect(res.status).toBe(200);
    expect(res.json).toMatchObject({ ok: true, service: "device-hub", protocol: 1 });
  });
});

describe("POST /v1/auth/stack", () => {
  it("exchanges a Stack access token for an ES256 hub session", async () => {
    mockOutbound();
    const res = await rawCall("POST", "/v1/auth/stack", { body: { token: await stackToken(stackClaims("stack-user-1")) } });
    expect(res.status).toBe(200);
    expect(res.json.userId).toBe("stack-user-1");
    expect(res.json.expiresAt).toBeGreaterThan(Date.now() + 3500_000);
    const [h, p] = (res.json.session as string).split(".");
    expect(JSON.parse(atob(h!.replace(/-/g, "+").replace(/_/g, "/")))).toMatchObject({ alg: "ES256" });
    const payload = JSON.parse(atob(p!.replace(/-/g, "+").replace(/_/g, "/")));
    expect(payload).toMatchObject({ iss: "device-hub", sub: "stack-user-1" });
    expect(payload.exp - payload.iat).toBe(3600);
    // JWKS is cached across sign-ins.
    const before = outbound.filter((u) => u.endsWith("jwks.json")).length;
    await rawCall("POST", "/v1/auth/stack", { body: { token: await stackToken(stackClaims("stack-user-1")) } });
    expect(outbound.filter((u) => u.endsWith("jwks.json")).length).toBe(before);
  });

  it("rejects bad issuer, audience, expiry, anonymous users, unknown keys and bad signatures", async () => {
    mockOutbound();
    const post = async (token: string) => (await rawCall("POST", "/v1/auth/stack", { body: { token } })).status;
    expect(await post(await stackToken(stackClaims("u", { iss: "https://evil" })))).toBe(401);
    expect(await post(await stackToken(stackClaims("u", { aud: "other" })))).toBe(401);
    expect(await post(await stackToken(stackClaims("u", { exp: Math.floor(Date.now() / 1000) - 120 })))).toBe(401);
    expect(await post(await stackToken(stackClaims("u", { is_anonymous: true })))).toBe(401);
    expect(await post(await stackToken(stackClaims("u"), "unknown-kid"))).toBe(401);
    const good = await stackToken(stackClaims("u"));
    expect(await post(good.slice(0, good.lastIndexOf(".")) + ".AAAA")).toBe(401);
    expect(await post("garbage")).toBe(401);
    expect((await rawCall("POST", "/v1/auth/stack", { body: {} })).status).toBe(400);
  });

  it("requires a valid, unexpired hub session on device calls", async () => {
    const account = await signIn();
    const d = await Device.create(account);
    expect((await d.call("GET", "/v1/me", undefined, { session: "nope" })).status).toBe(401);
    const now = Math.floor(Date.now() / 1000);
    const expired = await signEs256(hubEnv.SESSION_KEY, { iss: "device-hub", sub: account.userId, iat: now - 7200, exp: now - 3600 });
    expect((await d.call("GET", "/v1/me", undefined, { session: expired })).json.error.code).toBe("unauthorized");
    // A token signed by another key (the ticket key) is not a session.
    const forged = await signEs256(hubEnv.TICKET_KEY, { iss: "device-hub", sub: account.userId, iat: now, exp: now + 60 });
    expect((await d.call("GET", "/v1/me", undefined, { session: forged })).status).toBe(401);
  });
});
