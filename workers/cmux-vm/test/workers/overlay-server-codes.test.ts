import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { makeInstallKey, type InstallKey } from "../support/mesh-signing.ts";

const TEAM = "team_alpha";
const WG = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=";
const WG2 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDI=";
type Harness = Awaited<ReturnType<typeof makeHarness>>;
let h: Harness;
let key: string;
let mesh: string;
let install: InstallKey;
const record = (value: unknown): Record<string, unknown> => typeof value === "object" && value !== null ? Object.fromEntries(Object.entries(value)) : {};
const json = async (response: Response) => record(await response.json());
const field = (body: Record<string, unknown>, name: string) => { const value = body[name]; if (typeof value !== "string") throw new Error(`missing ${name}`); return value; };
const call = (path: string, method = "GET", body?: unknown, auth = key) => h.request(path, bearer(auth), { method, body });
const binding = () => ({ name: "server", wgPublicKey: WG, installPublicKey: install.publicKey });
const issue = (auth = key) => call(`/v1/meshes/${mesh}/overlay-server-codes`, "POST", binding(), auth);
const issued = async () => { const response = await issue(); expect(response.status).toBe(201); return json(response); };
const signed = async (code: string, name = "server", wgPublicKey = WG, signedAt = Date.now()) => {
  const nonce = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16)))).replace(/\+/gu, "-").replace(/\//gu, "_").replace(/=+$/u, "");
  const message = ["cmux-mesh-v1", "enroll-overlay-server", mesh, wgPublicKey, install.publicKey, `${code}:${name}`, String(signedAt), nonce].join("\n");
  const bytes = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, install.privateKey, new TextEncoder().encode(message)));
  return { code, name, wgPublicKey, installPublicKey: install.publicKey, signedAt, nonce, signature: btoa(String.fromCharCode(...bytes)) };
};
const redeem = (body: unknown, target = mesh) => h.request(`/v1/meshes/${target}/overlay-server-enrollments`, {}, { method: "POST", body });

beforeEach(async () => {
  h = await makeHarness(); key = await h.addKey(TEAM, ALL_SCOPES); install = await makeInstallKey();
  mesh = field(await json(await call("/v1/meshes", "POST", {})), "id");
});
afterEach(async () => { await h.dispose(); });

describe("approved provider-free server enrollment codes", () => {
  it("reserves an identity, pins the approved keys and returns no reusable credential", async () => {
    const before = h.upstreamRequests.length;
    const grant = await issued();
    expect(grant).toMatchObject({ meshId: mesh, tenantId: TEAM, binding: binding() });
    expect(field(grant, "code")).toMatch(/^msc_[0-9a-hjkmnp-tv-z]{26}$/u);
    expect(Date.parse(field(grant, "expiresAt")) - Date.now()).toBeGreaterThan(590_000);
    expect(Object.keys(grant).sort()).toEqual(["binding", "code", "deviceId", "expiresAt", "meshId", "tenantId"]);
    expect((await json(await call(`/v1/meshes/${mesh}/overlay-servers`)))["items"]).toEqual([]);
    const response = await redeem(await signed(field(grant, "code")));
    expect(response.status).toBe(201);
    expect(await json(response)).toMatchObject({ id: grant["deviceId"], meshId: mesh, ...binding(), kind: "server", transport: "overlay" });
    expect(h.upstreamRequests).toHaveLength(before);
    expect((await call(`/v1/devices/${field(grant, "deviceId")}`)).status).toBe(404);
  });

  it("recovers a lost enrollment response with a fresh signed receipt and never resurrects a revoked id", async () => {
    const grant = await issued(); const code = field(grant, "code"); const id = field(grant, "deviceId");
    const request = await signed(code);
    expect((await redeem(request)).status).toBe(201);
    expect((await redeem(request)).status).toBe(409);
    expect(await json(await redeem(await signed(code)))).toMatchObject({ id });
    expect((await json(await call(`/v1/meshes/${mesh}/overlay-servers`)))["items"]).toHaveLength(1);
    expect((await call(`/v1/overlay-servers/${id}`, "DELETE")).status).toBe(204);
    expect((await redeem(await signed(code))).status).toBe(404);
    expect((await json(await call(`/v1/meshes/${mesh}/overlay-servers`)))["items"]).toEqual([]);
  });

  it("shares a pending reservation across separately single-use codes and concurrent redemption", async () => {
    const a = await issued(); const b = await issued();
    expect(b["deviceId"]).toBe(a["deviceId"]); expect(b["code"]).not.toBe(a["code"]);
    const responses = await Promise.all([redeem(await signed(field(a, "code"))), redeem(await signed(field(b, "code")))]);
    expect(responses.map((response) => response.status)).toEqual([201, 201]);
    expect((await json(await call(`/v1/meshes/${mesh}/overlay-servers`)))["items"]).toHaveLength(1);
  });

  it("burns a mismatched binding, stale signature or swapped code before registering a server", async () => {
    const a = await issued(); const b = await issued();
    const request = await signed(field(a, "code"));
    expect((await redeem({ ...request, code: field(b, "code") })).status).toBe(403);
    expect((await redeem(await signed(field(b, "code")))).status).toBe(404);
    expect((await redeem(await signed(field(a, "code"), "different"))).status).toBe(404);
    expect((await redeem(await signed(field(a, "code")))).status).toBe(404);
    const c = await issued(); const code = field(c, "code");
    expect((await redeem(await signed(code, "server", WG, Date.now() - 180_000))).status).toBe(403);
    expect((await redeem(await signed(code))).status).toBe(404);
    expect((await json(await call(`/v1/meshes/${mesh}/overlay-servers`)))["items"]).toEqual([]);
  });

  it("cannot cross gateway routes or another mesh and never makes provider calls", async () => {
    const grant = await issued(); const code = field(grant, "code");
    const before = h.upstreamRequests.length;
    const request = await signed(code);
    expect((await h.request(`/v1/meshes/${mesh}/device-enrollments`, {}, { method: "POST", body: request })).status).toBe(400);
    const otherMesh = "mesh_00000000000000000000000000";
    expect((await redeem(request, otherMesh)).status).toBe(404);
    expect((await redeem(await signed(code))).status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(before);
  });

  it("rechecks the approving principal and credential restrictions", async () => {
    expect((await issue(await h.addKey(TEAM, ["mesh:read"]))).status).toBe(403);
    expect((await issue(await h.addKey(TEAM, ALL_SCOPES, { allowlist: [] }))).status).toBe(404);
    expect((await issue(await h.addKey("team_bravo", ALL_SCOPES))).status).toBe(404);
    const grant = await issued(); await h.revokeKey(key);
    expect((await redeem(await signed(field(grant, "code")))).status).toBe(404);
  });

  it("requires fresh membership even after a positive membership cache", async () => {
    h.addMember(TEAM, "user_pair");
    const token = await h.sessionToken("user_pair");
    const response = await h.request(`/v1/meshes/${mesh}/overlay-server-codes`, { ...bearer(token), "x-cmux-team-id": TEAM }, { method: "POST", body: binding() });
    expect(response.status).toBe(201); const grant = await json(response);
    h.removeMember(TEAM, "user_pair");
    expect((await redeem(await signed(field(grant, "code")))).status).toBe(404);
  });

  it("leaves a valid code usable when metadata admission is temporarily full", async () => {
    await h.dispose(); h = await makeHarness({ mesh: { budgets: { overlayServersPerMesh: 1 } } });
    key = await h.addKey(TEAM, ALL_SCOPES); mesh = field(await json(await call("/v1/meshes", "POST", {})), "id");
    const grant = await issued(); const code = field(grant, "code");
    const original = install; install = await makeInstallKey();
    // Ordinary credential enrollment occupies the slot after approval, before redemption.
    const body = await signed("");
    const message = ["cmux-mesh-v1", "enroll-overlay-server", mesh, WG2, install.publicKey, "other", String(body.signedAt), body.nonce].join("\n");
    const bytes = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, install.privateKey, new TextEncoder().encode(message)));
    const occupied = await call(`/v1/meshes/${mesh}/overlay-servers`, "POST", { name: "other", wgPublicKey: WG2, installPublicKey: install.publicKey, signedAt: body.signedAt, nonce: body.nonce, signature: btoa(String.fromCharCode(...bytes)) });
    expect(occupied.status).toBe(201); const id = field(await json(occupied), "id"); install = original;
    expect((await redeem(await signed(code))).status).toBe(429);
    expect((await call(`/v1/overlay-servers/${id}`, "DELETE")).status).toBe(204);
    expect((await redeem(await signed(code))).status).toBe(201);
  });
});
