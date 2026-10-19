import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { deviceRequestBody, enrollBody, makeInstallKey, rotateBody, type InstallKey } from "../support/mesh-signing.ts";

const TEAM = "team_alpha";
const WG = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=";
const WG2 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDI=";
type Harness = Awaited<ReturnType<typeof makeHarness>>;
let h: Harness;
let admin: string;
let mesh: string;
let install: InstallKey;
const call = (path: string, key: string, method = "GET", body?: unknown) => h.request(path, bearer(key), { method, body });
const read = (id: string, key = admin) => call(`/v1/devices/${id}/overlay-policy`, key);
const enroll = async (key = admin, name = "device") => {
  const response = await call(`/v1/meshes/${mesh}/devices`, key, "POST", await enrollBody(install, mesh, { name, wgPublicKey: WG }));
  expect(response.status).toBe(201);
  const body = await response.json() as { device: { id: string } };
  return body.device.id;
};
const apply = (rules: unknown[], expectedVersion = 0) => call(`/v1/meshes/${mesh}/acl`, admin, "PUT", { expectedVersion, rules });
const signed = async (id: string, body = deviceRequestBody(install, id, "overlay-policy")) =>
  h.request(`/v1/devices/${id}/signed/overlay-policy`, {}, { method: "POST", body: await body });

beforeEach(async () => {
  h = await makeHarness();
  admin = await h.addKey(TEAM, ALL_SCOPES);
  install = await makeInstallKey();
  const response = await call("/v1/meshes", admin, "POST", {});
  mesh = (await response.json() as { id: string }).id;
});
afterEach(async () => { await h.dispose(); });

describe("device overlay policy", () => {
  it("defaults to deny and exposes only public identity for the requesting device", async () => {
    const id = await enroll();
    const before = h.upstreamRequests.length;
    const response = await read(id);
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body).toMatchObject({ deviceId: id, meshId: mesh, wgPublicKey: WG, installPublicKey: install.publicKey, aclVersion: 0, peers: [] });
    expect(Object.keys(body).sort()).toEqual(["aclVersion", "deviceId", "installPublicKey", "meshId", "peers", "policyDigest", "wgPublicKey"]);
    expect(h.upstreamRequests).toHaveLength(before);
  });

  it("projects explicit direction and ports, hides unrelated identities and never creates provider rules", async () => {
    const laptop = await enroll(admin, "laptop");
    const server = await enroll(admin, "server");
    await enroll(admin, "unrelated");
    const before = h.upstreamRequests.length;
    const applied = await apply([{ src: [laptop], dst: [server], allow: ["tcp:4100", "udp:53"] }]);
    expect(applied.status).toBe(200);
    expect(await applied.json()).toMatchObject({ ruleCount: 0, overlayRuleCount: 2 });
    const outbound = await (await read(laptop)).json();
    const inbound = await (await read(server)).json();
    const ports = [{ protocol: "tcp", port: 4100 }, { protocol: "udp", port: 53 }];
    expect(outbound.peers).toEqual([{ deviceId: server, wgPublicKey: WG, installPublicKey: install.publicKey, inbound: [], outbound: ports }]);
    expect(inbound.peers).toEqual([{ deviceId: laptop, wgPublicKey: WG, installPublicKey: install.publicKey, inbound: ports, outbound: [] }]);
    expect(h.upstreamRequests).toHaveLength(before);
    expect((await (await call(`/v1/devices/${laptop}/peers`, admin)).json()).peers).toEqual([]);
  });

  it("reads with a device signature and enforces purpose, freshness, replay and revocation", async () => {
    const owner = await h.addKey(TEAM, ["mesh:join"]);
    const id = await enroll(owner);
    expect((await signed(id, deviceRequestBody(install, id, "peers"))).status).toBe(404);
    expect((await signed(id, deviceRequestBody(install, id, "overlay-policy", { signedAt: Date.now() - 180_000 }))).status).toBe(403);
    const request = deviceRequestBody(install, id, "overlay-policy");
    expect((await signed(id, request)).status).toBe(200);
    expect((await signed(id, request)).status).toBe(409);
    await h.revokeKey(owner);
    expect((await signed(id)).status).toBe(404);
    expect((await read(id)).status).toBe(404);
  });

  it("requires device ownership or admin, current scope, tenant and resource visibility", async () => {
    const owner = await h.addKey(TEAM, ["mesh:join"]);
    const id = await enroll(owner);
    const other = await h.addKey(TEAM, ["mesh:join"]);
    expect((await read(id, other)).status).toBe(404);
    expect((await read(id, await h.addKey("team_bravo", ALL_SCOPES))).status).toBe(404);
    expect((await read(id, await h.addKey(TEAM, ["mesh:read"])) ).status).toBe(403);
    expect((await read(id, await h.addKey(TEAM, ALL_SCOPES, { allowlist: [] }))).status).toBe(404);
    expect((await read(id, owner)).status).toBe(200);
    expect((await read(id)).status).toBe(200);
  });

  it("removes revoked or departed peers and updates identity at the same ACL version", async () => {
    const laptop = await enroll();
    const owner = await h.addKey(TEAM, ["mesh:join"]);
    const server = await enroll(owner, "server");
    expect((await apply([{ src: [laptop], dst: [server], allow: ["tcp:4100"] }])).status).toBe(200);
    const initial = await (await read(laptop)).json();
    const rotated = await call(`/v1/devices/${server}/rotate-key`, owner, "POST", await rotateBody(install, server, WG2));
    expect(rotated.status).toBe(200);
    const updated = await (await read(laptop)).json();
    expect(updated.aclVersion).toBe(initial.aclVersion);
    expect(updated.policyDigest).not.toBe(initial.policyDigest);
    expect(updated.peers[0].wgPublicKey).toBe(WG2);
    await h.revokeKey(owner);
    expect((await (await read(laptop)).json()).peers).toEqual([]);
  });

  it("removes deleted devices even when an old ACL still names them", async () => {
    const laptop = await enroll();
    const server = await enroll();
    expect((await apply([{ src: [laptop], dst: [server], allow: ["*"] }])).status).toBe(200);
    expect((await call(`/v1/devices/${server}`, admin, "DELETE")).status).toBe(204);
    expect((await (await read(laptop)).json()).peers).toEqual([]);
    expect((await read(server)).status).toBe(404);
  });
});
