/**
 * Mesh M2 (cx-0op.4): a device proves it holds its install key on enroll and
 * on key rotation (signed, fresh, never replayed); one-time enrollment codes
 * for headless machines (single use, 10 minutes, stored hashed, audited); and
 * key rotation through the provider's rotate-key call.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";
import { enrollBody, makeInstallKey, rotateBody, sha256Hex, type InstallKey } from "../support/mesh-signing.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const A = "team_alpha";
const B = "team_bravo";
const KEY_1 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=";
const KEY_2 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDI=";
const KEY_3 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDM=";
const MEMBER_SCOPES = ["mesh:read", "mesh:join", "acl:read"] as const;

let h: Harness;
let install: InstallKey;
const setup = async (options: HarnessOptions = {}) => {
  h = await makeHarness(options);
};
beforeEach(async () => {
  await setup();
  install = await makeInstallKey();
});
afterEach(async () => {
  await h.dispose();
});

const json = async (response: Response): Promise<Record<string, unknown>> => {
  const body: unknown = await response.json();
  return typeof body === "object" && body !== null ? Object.fromEntries(Object.entries(body)) : {};
};
const field = (value: unknown, key: string): unknown => (typeof value === "object" && value !== null ? Object.fromEntries(Object.entries(value))[key] : undefined);
const str = (value: unknown): string => (typeof value === "string" ? value : "");
const call = (path: string, key: string, method = "GET", body?: unknown) => h.request(path, bearer(key), { method, body });
const anonymous = (path: string, body: unknown) => h.request(path, {}, { method: "POST", body });

const createMesh = async (key: string) => {
  const response = await call("/v1/meshes", key, "POST", { displayName: "m2" });
  expect(response.status).toBe(201);
  return str((await json(response))["id"]);
};

const tunnelCreates = () => h.upstream.callsTo("POST", /^\/v5\/tunnels$/u).length;

describe("install-key signature on enroll", () => {
  it("enrolls with a valid signature and records the install public key", async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const response = await call(`/v1/meshes/${meshId}/devices`, admin, "POST", await enrollBody(install, meshId, { name: "laptop", wgPublicKey: KEY_1 }));
    expect(response.status).toBe(201);
    const device = field(await json(response), "device");
    expect(field(device, "installPublicKey")).toBe(install.publicKey);
  });

  it("refuses an enroll without a signature, with 400 and no provider call", async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const response = await call(`/v1/meshes/${meshId}/devices`, admin, "POST", { name: "laptop", wgPublicKey: KEY_1 });
    expect(response.status).toBe(400);
    expect(tunnelCreates()).toBe(0);
  });

  it("refuses a signature by another key, a tampered body, another mesh and a stale signedAt, with 403 and no provider call", async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const other = await makeInstallKey();
    const path = `/v1/meshes/${meshId}/devices`;
    const forged = await enrollBody(install, meshId, { name: "laptop", wgPublicKey: KEY_1 }, { signWith: other });
    const tampered = { ...(await enrollBody(install, meshId, { name: "laptop", wgPublicKey: KEY_1 })), name: "renamed" };
    const swappedKey = { ...(await enrollBody(install, meshId, { name: "laptop", wgPublicKey: KEY_1 })), wgPublicKey: KEY_2 };
    const otherMesh = await enrollBody(install, "mesh_00000000000000000000000000", { name: "laptop", wgPublicKey: KEY_1 });
    const stale = await enrollBody(install, meshId, { name: "laptop", wgPublicKey: KEY_1 }, { signedAt: Date.now() - 10 * 60_000 });
    const future = await enrollBody(install, meshId, { name: "laptop", wgPublicKey: KEY_1 }, { signedAt: Date.now() + 10 * 60_000 });
    for (const [label, body] of Object.entries({ forged, tampered, swappedKey, otherMesh, stale, future })) {
      const response = await call(path, admin, "POST", body);
      expect(response.status, label).toBe(403);
    }
    expect(tunnelCreates()).toBe(0);
  });

  it("refuses a replayed request even after the device it made was deleted", async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const body = await enrollBody(install, meshId, { name: "laptop", wgPublicKey: KEY_1 });
    const first = await call(`/v1/meshes/${meshId}/devices`, admin, "POST", body);
    expect(first.status).toBe(201);
    const deviceId = str(field(field(await json(first), "device"), "id"));
    expect((await call(`/v1/devices/${deviceId}`, admin, "DELETE")).status).toBe(204);
    const creates = tunnelCreates();
    const replay = await call(`/v1/meshes/${meshId}/devices`, admin, "POST", body);
    expect(replay.status).toBe(409);
    expect(tunnelCreates()).toBe(creates);
  });
});

describe("enrollment codes", () => {
  const newCode = async (key: string, meshId: string) => {
    const response = await call(`/v1/meshes/${meshId}/enrollment-codes`, key, "POST", {});
    expect(response.status).toBe(201);
    return json(response);
  };
  const codeEnroll = async (meshId: string, code: string, wgPublicKey = KEY_1, name = "headless") =>
    anonymous(`/v1/meshes/${meshId}/device-enrollments`, await enrollBody(install, meshId, { name, wgPublicKey, code }));

  it("issues a single-use code valid for 10 minutes and stores only its SHA-256", async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const before = Date.now();
    const issued = await newCode(admin, meshId);
    const code = str(issued["code"]);
    expect(code).toMatch(/^mec_[0-9a-hjkmnp-tv-z]{26}$/u);
    expect(issued["meshId"]).toBe(meshId);
    const expiresAt = Date.parse(str(issued["expiresAt"]));
    expect(expiresAt - before).toBeGreaterThanOrEqual(599_000);
    expect(expiresAt - before).toBeLessThanOrEqual(601_000);
    const rows = h.mesh.store.enrollmentCodes();
    expect(rows).toHaveLength(1);
    expect(rows[0]?.codeSha256).toBe(await sha256Hex(code));
    expect(JSON.stringify(rows)).not.toContain(code);
  });

  it("a headless machine enrolls with the code and no credential; the device belongs to the code's creator", async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const creator = await h.addKey(A, MEMBER_SCOPES);
    const stranger = await h.addKey(A, MEMBER_SCOPES);
    const code = str((await newCode(creator, meshId))["code"]);
    const enrolled = await codeEnroll(meshId, code);
    expect(enrolled.status).toBe(201);
    const body = await json(enrolled);
    const deviceId = str(field(field(body, "device"), "id"));
    expect(field(field(body, "tunnel"), "serverPublicKey")).toBeTypeOf("string");
    expect(JSON.stringify(body)).not.toMatch(/PrivateKey|privateKey/u);
    expect((await call(`/v1/devices/${deviceId}`, creator)).status).toBe(200);
    expect((await call(`/v1/devices/${deviceId}`, stranger)).status).toBe(404);
  });

  it("refuses a second use, an expired code, an unknown code and a code for another mesh, with 404", async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const code = str((await newCode(admin, meshId))["code"]);
    expect((await codeEnroll(meshId, code)).status).toBe(201);
    expect((await codeEnroll(meshId, code, KEY_2, "again")).status).toBe(404);

    const expired = str((await newCode(admin, meshId))["code"]);
    const hash = await sha256Hex(expired);
    for (const row of h.mesh.store.enrollmentCodes()) if (row.codeSha256 === hash) row.expiresAt = new Date(Date.now() - 1000);
    expect((await codeEnroll(meshId, expired, KEY_2, "late")).status).toBe(404);

    expect((await codeEnroll(meshId, "mec_00000000000000000000000000", KEY_2, "guess")).status).toBe(404);

    const forOther = str((await newCode(admin, meshId))["code"]);
    expect((await codeEnroll("mesh_00000000000000000000000000", forOther, KEY_2, "elsewhere")).status).toBe(404);
    // M3: a code presented at another mesh is burned (the brute-force guard, mesh-m3.test.ts).
    expect((await codeEnroll(meshId, forOther, KEY_2, "home")).status).toBe(404);
  });

  it("refuses a code enroll with a bad signature and burns the code (M3)", async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const code = str((await newCode(admin, meshId))["code"]);
    const forged = await enrollBody(install, meshId, { name: "headless", wgPublicKey: KEY_1, code }, { signWith: await makeInstallKey() });
    expect((await anonymous(`/v1/meshes/${meshId}/device-enrollments`, forged)).status).toBe(403);
    expect(tunnelCreates()).toBe(0);
    expect((await codeEnroll(meshId, code)).status).toBe(404);
  });

  it("answers 404 with the experiment's own body when the experiment is off, before any provider call", async () => {
    await h.dispose();
    await setup({ mesh: { experiment: false } });
    const response = await codeEnroll("mesh_00000000000000000000000000", "mec_00000000000000000000000000");
    expect(response.status).toBe(404);
    expect(await json(response)).toEqual({ _tag: "NotFound", message: "Not found" });
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("another tenant cannot issue a code for this mesh", async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const other = await h.addKey(B, ALL_SCOPES);
    expect((await call(`/v1/meshes/${meshId}/enrollment-codes`, other, "POST", {})).status).toBe(404);
    expect(h.mesh.store.enrollmentCodes()).toHaveLength(0);
  });

  it("limits codes per mesh per hour", async () => {
    await h.dispose();
    await setup({ mesh: { budgets: { enrollmentCodesPerHour: 2 } } });
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    await newCode(admin, meshId);
    await newCode(admin, meshId);
    const third = await call(`/v1/meshes/${meshId}/enrollment-codes`, admin, "POST", {});
    expect(third.status).toBe(429);
    expect(await json(third)).toMatchObject({ _tag: "QuotaExceeded", budget: "enrollmentCode.perMeshPerHour" });
  });

  it("writes audit rows for the code and for the enroll, as the code's creator", async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const code = str((await newCode(admin, meshId))["code"]);
    const enrolled = await codeEnroll(meshId, code);
    const deviceId = str(field(field(await json(enrolled), "device"), "id"));
    const rows = h.audit.filter((row) => row.tenantId === A && row.action !== "mesh.create");
    expect(rows.map((row) => [row.action, row.cmuxId, row.outcome])).toEqual([
      ["enrollment_code.create", meshId, "ok"],
      ["device.create", deviceId, "ok"],
    ]);
    expect(rows[0]?.actor).toBe(rows[1]?.actor);
    expect(JSON.stringify(h.audit)).not.toContain(code);
  });
});

describe("key rotation", () => {
  const enrolled = async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const owner = await h.addKey(A, MEMBER_SCOPES);
    const response = await call(`/v1/meshes/${meshId}/devices`, owner, "POST", await enrollBody(install, meshId, { name: "laptop", wgPublicKey: KEY_1 }));
    expect(response.status).toBe(201);
    const body = await json(response);
    return {
      admin,
      owner,
      meshId,
      deviceId: str(field(field(body, "device"), "id")),
      serverPublicKey: str(field(field(body, "tunnel"), "serverPublicKey")),
    };
  };
  const rotateCalls = () => h.upstream.callsTo("POST", /^\/v5\/tunnels\/[^/]+\/rotate-key$/u);

  it("rotates through the provider with the new key, returns the new config and records the key", async () => {
    const ids = await enrolled();
    const response = await call(`/v1/devices/${ids.deviceId}/rotate-key`, ids.owner, "POST", await rotateBody(install, ids.deviceId, KEY_2));
    expect(response.status).toBe(200);
    const config = await json(response);
    expect(config["deviceId"]).toBe(ids.deviceId);
    expect(str(config["serverPublicKey"])).not.toBe(ids.serverPublicKey);
    expect(JSON.stringify(config)).not.toMatch(/PrivateKey|privateKey/u);
    const calls = rotateCalls();
    expect(calls).toHaveLength(1);
    expect(field(calls[0]?.json, "clientPublicKey")).toBe(KEY_2);
    expect(field(await json(await call(`/v1/devices/${ids.deviceId}`, ids.owner)), "wgPublicKey")).toBe(KEY_2);
    expect(h.audit.filter((row) => row.action === "device.rotate_key").map((row) => [row.cmuxId, row.outcome])).toEqual([[ids.deviceId, "ok"]]);
  });

  it("another principal of the tenant gets 404, and nothing reaches the provider", async () => {
    const ids = await enrolled();
    const stranger = await h.addKey(A, MEMBER_SCOPES);
    const response = await call(`/v1/devices/${ids.deviceId}/rotate-key`, stranger, "POST", await rotateBody(install, ids.deviceId, KEY_2));
    expect(response.status).toBe(404);
    expect(rotateCalls()).toHaveLength(0);
  });

  it("a tenant admin may rotate, but only with the device's install-key signature", async () => {
    const ids = await enrolled();
    const forged = await call(`/v1/devices/${ids.deviceId}/rotate-key`, ids.admin, "POST", await rotateBody(await makeInstallKey(), ids.deviceId, KEY_2));
    expect(forged.status).toBe(403);
    expect(rotateCalls()).toHaveLength(0);
    const signed = await call(`/v1/devices/${ids.deviceId}/rotate-key`, ids.admin, "POST", await rotateBody(install, ids.deviceId, KEY_2));
    expect(signed.status).toBe(200);
  });

  it("refuses a replayed rotation, a stale one and a key already in the mesh", async () => {
    const ids = await enrolled();
    const body = await rotateBody(install, ids.deviceId, KEY_2);
    expect((await call(`/v1/devices/${ids.deviceId}/rotate-key`, ids.owner, "POST", body)).status).toBe(200);
    expect((await call(`/v1/devices/${ids.deviceId}/rotate-key`, ids.owner, "POST", body)).status).toBe(409);
    const stale = await rotateBody(install, ids.deviceId, KEY_3, { signedAt: Date.now() - 10 * 60_000 });
    expect((await call(`/v1/devices/${ids.deviceId}/rotate-key`, ids.owner, "POST", stale)).status).toBe(403);
    const second = await call(`/v1/meshes/${ids.meshId}/devices`, ids.owner, "POST", await enrollBody(install, ids.meshId, { name: "second", wgPublicKey: KEY_3 }));
    expect(second.status).toBe(201);
    const taken = await call(`/v1/devices/${ids.deviceId}/rotate-key`, ids.owner, "POST", await rotateBody(install, ids.deviceId, KEY_3));
    expect(taken.status).toBe(409);
    expect(rotateCalls()).toHaveLength(1);
  });

  it("fails closed when the provider mints a private key on rotation: 503, no key in the answer", async () => {
    const ids = await enrolled();
    h.mesh.mintKeys(true);
    const response = await call(`/v1/devices/${ids.deviceId}/rotate-key`, ids.owner, "POST", await rotateBody(install, ids.deviceId, KEY_2));
    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain("bWludGVkLXByaXZhdGUta2V5");
  });
});
