import { describe, expect, it } from "vitest";
import { signEs256 } from "../src/crypto";
import * as main from "../src/index";
import { allowedStackProjects } from "../src/stack";
import { Device, STACK_DEV_PROJECT, STACK_OTHER_PROJECT, STACK_PROJECT, billingPlans, hubEnv, mockOutbound, outbound, rawCall, signIn, stackClaims, stackToken } from "./helpers";

describe("main module", () => {
  it("exports only the handler and the Durable Object classes (workerd rejects other exports)", () => {
    expect(Object.keys(main).sort()).toEqual(["SessionDO", "UserDO", "default"]);
  });
});

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
    const token = await stackToken(stackClaims("stack-user-1"));
    const res = await rawCall("POST", "/v1/auth/stack", { body: { token } });
    expect(res.status).toBe(200);
    expect(res.json).toMatchObject({ userId: `${STACK_PROJECT}:stack-user-1`, stackUserId: "stack-user-1", projectId: STACK_PROJECT });
    // The hub session ends no later than the Stack token it was exchanged for
    // (stackClaims: exp = now + 600), so relay checks always have a live token.
    const stackExp = stackClaims("stack-user-1").exp;
    expect(res.json.expiresAt).toBeLessThanOrEqual(stackExp * 1000);
    expect(res.json.expiresAt).toBeGreaterThan(Date.now() + 500_000);
    const [h, p] = (res.json.session as string).split(".");
    expect(JSON.parse(atob(h!.replace(/-/g, "+").replace(/_/g, "/")))).toMatchObject({ alg: "ES256" });
    const payload = JSON.parse(atob(p!.replace(/-/g, "+").replace(/_/g, "/")));
    expect(payload).toMatchObject({ iss: "device-hub", sub: `${STACK_PROJECT}:stack-user-1` });
    expect(payload.exp - payload.iat).toBeLessThanOrEqual(600);
    // The Stack token rides in the session only sealed: never in the clear.
    expect(JSON.stringify(payload)).not.toContain(token.split(".")[2]);
    expect(JSON.stringify(payload)).not.toContain(token.split(".")[1]);
    expect(typeof payload.stk).toBe("string");
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

  it("accepts every listed project and keeps users of different projects apart", async () => {
    mockOutbound();
    const sub = `same-${crypto.randomUUID()}`;
    const prod = await signIn(sub, STACK_PROJECT);
    const dev = await signIn(sub, STACK_DEV_PROJECT);
    expect(prod.userId).toBe(`${STACK_PROJECT}:${sub}`);
    expect(dev.userId).toBe(`${STACK_DEV_PROJECT}:${sub}`);
    const a = await Device.create(prod);
    await a.register();
    const b = await Device.create(dev);
    await b.register();
    expect((await a.call("GET", "/v1/devices")).json.devices.map((d: any) => d.id)).toEqual([a.id]);
    expect((await b.call("GET", "/v1/devices")).json.devices.map((d: any) => d.id)).toEqual([b.id]);
    expect((await b.call("GET", "/v1/me")).json.userId).toBe(`${STACK_DEV_PROJECT}:${sub}`);
  });

  it("refuses tokens from an unlisted project and tokens whose issuer names another project", async () => {
    mockOutbound();
    const post = async (claims: Record<string, unknown>) => rawCall("POST", "/v1/auth/stack", { body: { token: await stackToken(claims) } });
    const unlisted = await post(stackClaims("u", {}, STACK_OTHER_PROJECT));
    expect([unlisted.status, unlisted.json.error.code]).toEqual([401, "unauthorized"]);
    expect(outbound.some((u) => u.includes(STACK_OTHER_PROJECT))).toBe(false);
    // aud says dev, iss says prod: refused.
    const mixed = await post(stackClaims("u", { iss: `https://stack.test/api/v1/projects/${STACK_PROJECT}` }, STACK_DEV_PROJECT));
    expect(mixed.status).toBe(401);
    // aud lists two projects: refused rather than guessed.
    const both = await post(stackClaims("u", { aud: [STACK_PROJECT, STACK_DEV_PROJECT] }));
    expect(both.status).toBe(401);
  });

  it("reads STACK_PROJECT_IDS, falling back to STACK_PROJECT_ID", () => {
    expect(allowedStackProjects({ STACK_PROJECT_IDS: " a, b ,", STACK_PROJECT_ID: "c" } as any)).toEqual(["a", "b"]);
    expect(allowedStackProjects({ STACK_PROJECT_ID: "c" } as any)).toEqual(["c"]);
    expect(allowedStackProjects({ STACK_PROJECT_IDS: "", STACK_PROJECT_ID: "c" } as any)).toEqual(["c"]);
    expect(allowedStackProjects({} as any)).toEqual([]);
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
    // A session from before relay checks (no sealed Stack token) still works,
    // so an app's socket reconnects after the deploy, but never gets the relay.
    await d.register();
    billingPlans.set(account.sub, { subscriptionPlanId: "pro" });
    const legacy = await signEs256(hubEnv.SESSION_KEY, { iss: "device-hub", sub: account.userId, iat: now, exp: now + 600 });
    const legacyMe = await d.call("GET", "/v1/me", undefined, { session: legacy });
    expect([legacyMe.status, legacyMe.json.plan]).toEqual([200, "free"]);
    // A sealed token that does not open (tampered) is refused too.
    const tampered = await signEs256(hubEnv.SESSION_KEY, { iss: "device-hub", sub: account.userId, iat: now, exp: now + 600, stk: "AAAA.BBBB" });
    expect((await d.call("GET", "/v1/me", undefined, { session: tampered })).json.error.code).toBe("unauthorized");
  });
});
