/**
 * Mesh M3 (cx-0op.5).
 *
 * 1. Device-signed requests: a device enrolled with a one-time code has no
 *    credential afterwards. Its install-key signature (fresh, never replayed)
 *    authenticates it for its OWN peer map, tunnel config and key rotation and
 *    nothing else.
 * 2. A code made by an API key is refused once that key is revoked (checked
 *    when the code is used).
 * 3. A code is burned by any authentication failure (bad or stale signature,
 *    replay, another mesh, a revoked creator), and restored when the device
 *    budget or the provider refuses the enroll after the code was accepted.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";
import { deviceRequestBody, enrollBody, makeInstallKey, rotateBody, type InstallKey } from "../support/mesh-signing.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const A = "team_alpha";
const KEY_1 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=";
const KEY_2 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDI=";
const KEY_3 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDM=";
const KEY_4 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDQ=";
const MEMBER_SCOPES = ["mesh:read", "mesh:join", "acl:read"] as const;
const UNKNOWN_DEVICE = "dev_00000000000000000000000000";

let h: Harness;
const setup = async (options: HarnessOptions = {}) => {
  h = await makeHarness(options);
};
beforeEach(async () => {
  await setup();
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
const anonymous = (path: string, body?: unknown, method = "POST") => h.request(path, {}, { method, body });

const tunnelCreates = () => h.upstream.callsTo("POST", /^\/v5\/tunnels$/u).length;
const tunnelReads = () => h.upstream.callsTo("GET", /^\/v5\/tunnels\/[^/]+$/u).length;
const rotateCalls = () => h.upstream.callsTo("POST", /^\/v5\/tunnels\/[^/]+\/rotate-key$/u);

const createMesh = async (key: string) => {
  const response = await call("/v1/meshes", key, "POST", { displayName: "m3" });
  expect(response.status).toBe(201);
  return str((await json(response))["id"]);
};

const newCode = async (key: string, meshId: string) => {
  const response = await call(`/v1/meshes/${meshId}/enrollment-codes`, key, "POST", {});
  expect(response.status).toBe(201);
  return str((await json(response))["code"]);
};

const codeEnroll = async (install: InstallKey, meshId: string, code: string, wgPublicKey: string, name = "headless") =>
  anonymous(`/v1/meshes/${meshId}/device-enrollments`, await enrollBody(install, meshId, { name, wgPublicKey, code }));

const signedPeers = async (install: InstallKey, deviceId: string, path = deviceId) =>
  anonymous(`/v1/devices/${path}/signed/peers`, await deviceRequestBody(install, deviceId, "peers"));
const signedTunnel = async (install: InstallKey, deviceId: string, path = deviceId) =>
  anonymous(`/v1/devices/${path}/signed/tunnel`, await deviceRequestBody(install, deviceId, "tunnel"));
const signedRotate = async (install: InstallKey, deviceId: string, newPublicKey: string, path = deviceId) =>
  anonymous(`/v1/devices/${path}/signed/rotate-key`, await rotateBody(install, deviceId, newPublicKey));

/** A mesh with one VM that every device may ping, and a member key that issues codes. */
const meshWithVm = async () => {
  const admin = await h.addKey(A, ALL_SCOPES);
  const meshId = await createMesh(admin);
  const vm = h.addVm(A);
  expect((await call(`/v1/meshes/${meshId}/vms/${vm.vmId}`, admin, "PUT")).status).toBe(200);
  const acl = await call(`/v1/meshes/${meshId}/acl`, admin, "PUT", { expectedVersion: 0, rules: [{ src: ["device:*"], dst: ["vm:*"], allow: ["icmp"] }] });
  expect(acl.status).toBe(200);
  const creator = await h.addKey(A, MEMBER_SCOPES);
  return { admin, meshId, vmId: vm.vmId, creator };
};

/** Enrolls a headless device with a code made by `creator`; returns its id. */
const headless = async (meshId: string, creator: string, install: InstallKey, wgPublicKey: string, name = "headless") => {
  const code = await newCode(creator, meshId);
  const response = await codeEnroll(install, meshId, code, wgPublicKey, name);
  expect(response.status).toBe(201);
  return str(field(field(await json(response), "device"), "id"));
};

describe("device-signed requests", () => {
  it("a device enrolled with a code reads its peer map and tunnel config and rotates its key with only its install-key signature", async () => {
    const mesh = await meshWithVm();
    const install = await makeInstallKey();
    const deviceId = await headless(mesh.meshId, mesh.creator, install, KEY_1);

    const peers = await signedPeers(install, deviceId);
    expect(peers.status).toBe(200);
    const map = await json(peers);
    expect(map["deviceId"]).toBe(deviceId);
    expect(map["meshId"]).toBe(mesh.meshId);
    expect(Array.isArray(map["peers"]) ? map["peers"].map((peer) => field(peer, "id")) : []).toEqual([mesh.vmId]);

    const tunnel = await signedTunnel(install, deviceId);
    expect(tunnel.status).toBe(200);
    const config = await json(tunnel);
    expect(config["deviceId"]).toBe(deviceId);
    expect(config["serverPublicKey"]).toBeTypeOf("string");
    expect(JSON.stringify(config)).not.toMatch(/PrivateKey|privateKey/u);

    const rotated = await signedRotate(install, deviceId, KEY_2);
    expect(rotated.status).toBe(200);
    expect((await json(rotated))["deviceId"]).toBe(deviceId);
    const calls = rotateCalls();
    expect(calls).toHaveLength(1);
    expect(field(calls[0]?.json, "clientPublicKey")).toBe(KEY_2);
    expect(field(await json(await call(`/v1/devices/${deviceId}`, mesh.creator)), "wgPublicKey")).toBe(KEY_2);

    // Audited as the device, with the device's owner (the code's creator) as its owner (M4, cx-0op.7).
    const created = h.audit.find((row) => row.action === "enrollment_code.create");
    const rotation = h.audit.filter((row) => row.action === "device.rotate_key");
    expect(rotation.map((row) => [row.cmuxId, row.outcome])).toEqual([[deviceId, "ok"]]);
    expect(rotation[0]?.actor).toBe(`device:${deviceId}`);
    expect(rotation[0]?.ownerActor).toBe(created?.actor);
  });

  it("a device's signature cannot act on another device: 404, and nothing reaches the provider", async () => {
    const mesh = await meshWithVm();
    const mine = await makeInstallKey();
    const theirs = await makeInstallKey();
    const myDevice = await headless(mesh.meshId, mesh.creator, mine, KEY_1, "mine");
    const otherDevice = await headless(mesh.meshId, mesh.creator, theirs, KEY_2, "theirs");
    const reads = tunnelReads();

    // My key signing for the other device's id, and my own id sent to the other device's path.
    expect((await signedPeers(mine, otherDevice)).status).toBe(404);
    expect((await signedPeers(mine, myDevice, otherDevice)).status).toBe(404);
    expect((await signedTunnel(mine, otherDevice)).status).toBe(404);
    expect((await signedTunnel(mine, myDevice, otherDevice)).status).toBe(404);
    expect((await signedRotate(mine, otherDevice, KEY_3)).status).toBe(404);
    expect((await signedRotate(mine, myDevice, KEY_3, otherDevice)).status).toBe(404);

    expect(await json(await signedPeers(mine, otherDevice))).toEqual({ _tag: "NotFound", message: "Not found" });
    expect(tunnelReads()).toBe(reads);
    expect(rotateCalls()).toHaveLength(0);
    // The other device still works with its own key.
    expect((await signedPeers(theirs, otherDevice)).status).toBe(200);
  });

  it("refuses a replay with 409 and a stale or future signedAt with 403", async () => {
    const mesh = await meshWithVm();
    const install = await makeInstallKey();
    const deviceId = await headless(mesh.meshId, mesh.creator, install, KEY_1);
    const path = `/v1/devices/${deviceId}/signed/peers`;

    const body = await deviceRequestBody(install, deviceId, "peers");
    expect((await anonymous(path, body)).status).toBe(200);
    expect((await anonymous(path, body)).status).toBe(409);

    const stale = await deviceRequestBody(install, deviceId, "peers", { signedAt: Date.now() - 10 * 60_000 });
    expect((await anonymous(path, stale)).status).toBe(403);
    const future = await deviceRequestBody(install, deviceId, "tunnel", { signedAt: Date.now() + 10 * 60_000 });
    expect((await anonymous(`/v1/devices/${deviceId}/signed/tunnel`, future)).status).toBe(403);

    const rotate = await rotateBody(install, deviceId, KEY_2);
    expect((await anonymous(`/v1/devices/${deviceId}/signed/rotate-key`, rotate)).status).toBe(200);
    expect((await anonymous(`/v1/devices/${deviceId}/signed/rotate-key`, rotate)).status).toBe(409);
    const staleRotate = await rotateBody(install, deviceId, KEY_3, { signedAt: Date.now() - 10 * 60_000 });
    expect((await anonymous(`/v1/devices/${deviceId}/signed/rotate-key`, staleRotate)).status).toBe(403);
    expect(rotateCalls()).toHaveLength(1);
  });

  it("a signature made for one request does not authorize another", async () => {
    const mesh = await meshWithVm();
    const install = await makeInstallKey();
    const deviceId = await headless(mesh.meshId, mesh.creator, install, KEY_1);
    const peersBody = await deviceRequestBody(install, deviceId, "peers");
    expect((await anonymous(`/v1/devices/${deviceId}/signed/tunnel`, peersBody)).status).toBe(404);
    const tunnelBody = await deviceRequestBody(install, deviceId, "tunnel");
    expect((await anonymous(`/v1/devices/${deviceId}/signed/peers`, tunnelBody)).status).toBe(404);
    // A rotation must sign the key it registers.
    const swapped = { ...(await rotateBody(install, deviceId, KEY_2)), newPublicKey: KEY_3 };
    expect((await anonymous(`/v1/devices/${deviceId}/signed/rotate-key`, swapped)).status).toBe(404);
    expect(rotateCalls()).toHaveLength(0);
  });

  it("answers 404 for an unknown device, a deleted device, and when the experiment is off", async () => {
    const mesh = await meshWithVm();
    const install = await makeInstallKey();
    const deviceId = await headless(mesh.meshId, mesh.creator, install, KEY_1);
    expect((await signedPeers(install, UNKNOWN_DEVICE)).status).toBe(404);
    expect((await anonymous("/v1/devices/not-an-id/signed/peers", await deviceRequestBody(install, "not-an-id", "peers"))).status).toBe(404);
    expect((await call(`/v1/devices/${deviceId}`, mesh.creator, "DELETE")).status).toBe(204);
    expect((await signedPeers(install, deviceId)).status).toBe(404);
    expect((await signedRotate(install, deviceId, KEY_2)).status).toBe(404);

    await h.dispose();
    await setup({ mesh: { experiment: false } });
    const off = await signedPeers(install, UNKNOWN_DEVICE);
    expect(off.status).toBe(404);
    expect(await json(off)).toEqual({ _tag: "NotFound", message: "Not found" });
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("stops working when the API key that enrolled the device is revoked", async () => {
    const mesh = await meshWithVm();
    const install = await makeInstallKey();
    const deviceId = await headless(mesh.meshId, mesh.creator, install, KEY_1);
    expect((await signedPeers(install, deviceId)).status).toBe(200);
    await h.revokeKey(mesh.creator);
    expect((await signedPeers(install, deviceId)).status).toBe(404);
    expect((await signedTunnel(install, deviceId)).status).toBe(404);
    expect((await signedRotate(install, deviceId, KEY_2)).status).toBe(404);
    expect(rotateCalls()).toHaveLength(0);
  });

  it("grants nothing else: without a credential every other device route answers 401", async () => {
    const mesh = await meshWithVm();
    const install = await makeInstallKey();
    const deviceId = await headless(mesh.meshId, mesh.creator, install, KEY_1);
    const tunnelId = str(field(await json(await call(`/v1/devices/${deviceId}`, mesh.creator)), "tunnelId"));
    const signed = await deviceRequestBody(install, deviceId, "peers");
    expect((await anonymous(`/v1/devices/${deviceId}`, undefined, "GET")).status).toBe(401);
    expect((await anonymous(`/v1/devices/${deviceId}`, undefined, "DELETE")).status).toBe(401);
    expect((await anonymous(`/v1/devices/${deviceId}/peers`, undefined, "GET")).status).toBe(401);
    expect((await anonymous(`/v1/devices/${deviceId}/rotate-key`, await rotateBody(install, deviceId, KEY_2))).status).toBe(401);
    expect((await anonymous(`/v1/tunnels/${tunnelId}`, undefined, "GET")).status).toBe(401);
    expect((await anonymous(`/v1/meshes/${mesh.meshId}/devices`, undefined, "GET")).status).toBe(401);
    expect((await anonymous(`/v1/meshes/${mesh.meshId}/acl`, signed, "PUT")).status).toBe(401);
    expect((await anonymous(`/v1/meshes/${mesh.meshId}/enrollment-codes`, {})).status).toBe(401);
    // The device still exists and the provider saw no change.
    expect((await call(`/v1/devices/${deviceId}`, mesh.creator)).status).toBe(200);
    expect(rotateCalls()).toHaveLength(0);
  });
});

describe("enrollment codes made by an API key", () => {
  it("are refused once the key is revoked, checked when the code is used", async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const creator = await h.addKey(A, MEMBER_SCOPES);
    const code = await newCode(creator, meshId);
    await h.revokeKey(creator);
    const install = await makeInstallKey();
    const response = await codeEnroll(install, meshId, code, KEY_1);
    expect(response.status).toBe(404);
    expect(await json(response)).toEqual({ _tag: "NotFound", message: "Not found" });
    expect(tunnelCreates()).toBe(0);
    expect(h.mesh.store.devices).toHaveLength(0);
  });

  it("keep working while the key is live", async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const creator = await h.addKey(A, MEMBER_SCOPES);
    const code = await newCode(creator, meshId);
    expect((await codeEnroll(await makeInstallKey(), meshId, code, KEY_1)).status).toBe(201);
  });
});

describe("burning and restoring codes", () => {
  it("burns the code on a forged signature, a stale signature, a replayed request and another mesh's path", async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const install = await makeInstallKey();
    const path = `/v1/meshes/${meshId}/device-enrollments`;

    const forgedCode = await newCode(admin, meshId);
    const forged = await enrollBody(install, meshId, { name: "forged", wgPublicKey: KEY_1, code: forgedCode }, { signWith: await makeInstallKey() });
    expect((await anonymous(path, forged)).status).toBe(403);
    expect((await codeEnroll(install, meshId, forgedCode, KEY_1)).status).toBe(404);

    const staleCode = await newCode(admin, meshId);
    const stale = await enrollBody(install, meshId, { name: "stale", wgPublicKey: KEY_1, code: staleCode }, { signedAt: Date.now() - 10 * 60_000 });
    expect((await anonymous(path, stale)).status).toBe(403);
    expect((await codeEnroll(install, meshId, staleCode, KEY_1)).status).toBe(404);

    // The signed message does not include the code, so one signed body sent with a second code is a replay.
    const firstCode = await newCode(admin, meshId);
    const replayedCode = await newCode(admin, meshId);
    const body = await enrollBody(install, meshId, { name: "first", wgPublicKey: KEY_1 });
    expect((await anonymous(path, { ...body, code: firstCode })).status).toBe(201);
    expect((await anonymous(path, { ...body, code: replayedCode })).status).toBe(409);
    expect((await codeEnroll(install, meshId, replayedCode, KEY_2, "second")).status).toBe(404);

    const elsewhereCode = await newCode(admin, meshId);
    expect((await codeEnroll(install, "mesh_00000000000000000000000000", elsewhereCode, KEY_2, "elsewhere")).status).toBe(404);
    expect((await codeEnroll(install, meshId, elsewhereCode, KEY_2, "home")).status).toBe(404);

    expect(tunnelCreates()).toBe(1);
  });

  it("restores the code when the device budget refuses the enroll, so the same code works later", async () => {
    await h.dispose();
    await setup({ mesh: { budgets: { devicesPerMesh: 1 } } });
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const first = await call(`/v1/meshes/${meshId}/devices`, admin, "POST", await enrollBody(await makeInstallKey(), meshId, { name: "first", wgPublicKey: KEY_1 }));
    expect(first.status).toBe(201);
    const firstId = str(field(field(await json(first), "device"), "id"));
    const code = await newCode(admin, meshId);
    const install = await makeInstallKey();
    const refused = await codeEnroll(install, meshId, code, KEY_2);
    expect(refused.status).toBe(429);
    expect(await json(refused)).toMatchObject({ _tag: "QuotaExceeded", budget: "device.perMesh" });
    expect(tunnelCreates()).toBe(1);
    expect((await call(`/v1/devices/${firstId}`, admin, "DELETE")).status).toBe(204);
    expect((await codeEnroll(install, meshId, code, KEY_2)).status).toBe(201);
  });

  it("restores the code when the provider fails to create the tunnel, so the same code works later", async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const code = await newCode(admin, meshId);
    const install = await makeInstallKey();
    h.mesh.failTunnelCreates(503);
    expect((await codeEnroll(install, meshId, code, KEY_1)).status).toBe(503);
    expect(h.mesh.store.devices).toHaveLength(0);
    h.mesh.failTunnelCreates(null);
    expect((await codeEnroll(install, meshId, code, KEY_1)).status).toBe(201);
    // Used now: a third attempt is refused.
    expect((await codeEnroll(install, meshId, code, KEY_4, "again")).status).toBe(404);
  });
});
