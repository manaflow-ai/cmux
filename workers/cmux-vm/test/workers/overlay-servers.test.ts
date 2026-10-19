import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { enrollBody, makeInstallKey, type InstallKey } from "../support/mesh-signing.ts";
import { newDeviceId } from "../../src/lib/ids.ts";

const TEAM = "team_alpha";
const WG1 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=";
const WG2 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDI=";
type Harness = Awaited<ReturnType<typeof makeHarness>>;
let h: Harness;
let key: string;
let mesh: string;
let install: InstallKey;
const record = (value: unknown): Record<string, unknown> => typeof value === "object" && value !== null ? Object.fromEntries(Object.entries(value)) : {};
const json = async (response: Response) => record(await response.json());
const idOf = (body: Record<string, unknown>) => { if (typeof body["id"] !== "string") throw new Error("missing id"); return body["id"]; };
const call = (path: string, method = "GET", body?: unknown, auth = key) => h.request(path, bearer(auth), { method, body });
const signed = async (purpose: string, target: string, wgPublicKey = "", name = "") => {
  const signedAt = Date.now();
  const nonce = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16)))).replace(/\+/gu, "-").replace(/\//gu, "_").replace(/=+$/u, "");
  const message = ["cmux-mesh-v1", purpose, target, wgPublicKey, install.publicKey, name, String(signedAt), nonce].join("\n");
  const bytes = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, install.privateKey, new TextEncoder().encode(message)));
  return { signedAt, nonce, signature: btoa(String.fromCharCode(...bytes)) };
};
const enroll = async (wgPublicKey = WG1, name = "server") => call(`/v1/meshes/${mesh}/overlay-servers`, "POST", {
  name, wgPublicKey, installPublicKey: install.publicKey, ...await signed("enroll-overlay-server", mesh, wgPublicKey, name),
});
const policy = async (id: string) => h.request(`/v1/overlay-servers/${id}/signed/policy`, {}, { method: "POST", body: await signed("overlay-server-policy", id) });

beforeEach(async () => {
  h = await makeHarness(); key = await h.addKey(TEAM, ALL_SCOPES); install = await makeInstallKey();
  mesh = idOf(await json(await call("/v1/meshes", "POST", {})));
});
afterEach(async () => { await h.dispose(); });

describe("provider-free overlay servers", () => {
  it("enrolls a stable destination identity without a tunnel, provider mutation or synthetic tunnel id", async () => {
    const before = h.upstreamRequests.length;
    const response = await enroll(); expect(response.status).toBe(201);
    const server = await json(response);
    expect(server).toMatchObject({ meshId: mesh, name: "server", wgPublicKey: WG1, installPublicKey: install.publicKey, kind: "server", transport: "overlay" });
    expect(Object.keys(server).sort()).toEqual(["createdAt", "id", "installPublicKey", "kind", "meshId", "name", "transport", "wgPublicKey"]);
    expect(idOf(await json(await enroll()))).toBe(idOf(server));
    expect(h.upstreamRequests).toHaveLength(before);
    expect((await json(await policy(idOf(server))))).toMatchObject({ tenantId: TEAM, deviceId: idOf(server), meshId: mesh, peers: [] });
    expect((await call(`/v1/devices/${idOf(server)}`)).status).toBe(404);
  });

  it("shares policy with gateway clients while keeping the server out of source wildcards", async () => {
    const server = idOf(await json(await enroll()));
    const device = record((await json(await call(`/v1/meshes/${mesh}/devices`, "POST", await enrollBody(install, mesh, { name: "laptop", wgPublicKey: WG2 }))))["device"]);
    const client = idOf(device);
    const applied = await call(`/v1/meshes/${mesh}/acl`, "PUT", { expectedVersion: 0, rules: [{ src: ["device:*"], dst: [server], allow: ["tcp:4100"] }] });
    expect(applied.status).toBe(200);
    expect(await json(applied)).toMatchObject({ ruleCount: 0, overlayRuleCount: 1 });
    expect((await json(await call(`/v1/devices/${client}/overlay-policy`)))["peers"]).toEqual([expect.objectContaining({ deviceId: server, outbound: [{ protocol: "tcp", port: 4100 }], inbound: [] })]);
    expect((await json(await policy(server)))["peers"]).toEqual([expect.objectContaining({ deviceId: client, inbound: [{ protocol: "tcp", port: 4100 }], outbound: [] })]);
    const granted = await call(`/v1/meshes/${mesh}/acl`, "PUT", { expectedVersion: 1, rules: [{ src: [server], dst: [client], allow: ["tcp:4100"] }] });
    expect(granted.status).toBe(200);
    expect((await json(await policy(server)))["peers"]).toEqual([expect.objectContaining({ deviceId: client, inbound: [], outbound: [{ protocol: "tcp", port: 4100 }] })]);
  });

  it("requires possession, current owner, scope and tenant; signatures cannot cross the gateway enroll domain", async () => {
    const before = h.upstreamRequests.length;
    expect((await call(`/v1/meshes/${mesh}/overlay-servers`, "POST", await enrollBody(install, mesh, { name: "server", wgPublicKey: WG1 })))).toHaveProperty("status", 403);
    const owner = await h.addKey(TEAM, ["mesh:join"]);
    const request = { name: "server", wgPublicKey: WG1, installPublicKey: install.publicKey, ...await signed("enroll-overlay-server", mesh, WG1, "server") };
    const response = await call(`/v1/meshes/${mesh}/overlay-servers`, "POST", request, owner);
    expect(response.status).toBe(201);
    const server = idOf(await json(response));
    expect((await call(`/v1/meshes/${mesh}/overlay-servers`, "POST", request, owner)).status).toBe(409);
    expect((await call(`/v1/overlay-servers/${server}`, "GET", undefined, await h.addKey(TEAM, ["mesh:join"])) ).status).toBe(404);
    expect((await call(`/v1/overlay-servers/${server}`, "GET", undefined, await h.addKey("team_bravo", ALL_SCOPES))).status).toBe(404);
    await h.revokeKey(owner);
    expect((await policy(server)).status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(before);
  });

  it("refuses WireGuard keys already used by gateway clients in either enrollment direction", async () => {
    const client = await call(`/v1/meshes/${mesh}/devices`, "POST", await enrollBody(install, mesh, { name: "laptop", wgPublicKey: WG1 }));
    expect(client.status).toBe(201);
    const before = h.upstreamRequests.length;
    expect((await enroll()).status).toBe(409);
    const server = await enroll(WG2); expect(server.status).toBe(201);
    const refused = await call(`/v1/meshes/${mesh}/devices`, "POST", await enrollBody(install, mesh, { name: "other", wgPublicKey: WG2 }));
    expect(refused.status).toBe(409);
    expect(h.upstreamRequests).toHaveLength(before);
  });

  it("revokes its own identity without a provider call and removes it from client policy", async () => {
    const server = idOf(await json(await enroll()));
    const before = h.upstreamRequests.length;
    const revoked = await h.request(`/v1/overlay-servers/${server}/signed/revoke`, {}, { method: "POST", body: await signed("revoke-overlay-server", server) });
    expect(revoked.status).toBe(204);
    expect((await policy(server)).status).toBe(404);
    expect((await call(`/v1/overlay-servers/${server}`)).status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(before);
    const revokedAudit = h.audit.filter((row) => row.action === "overlay_server.revoke");
    expect(revokedAudit).toHaveLength(1);
    expect(revokedAudit[0]?.actor).toBe(`device:${server}`);
    expect(revokedAudit[0]?.ownerActor).toBe(h.audit.find((row) => row.action === "overlay_server.create")?.actor);
  });

  it("serializes gateway/server admission so a key cannot gain two live identities", async () => {
    const [server, client] = await Promise.all([
      enroll(),
      call(`/v1/meshes/${mesh}/devices`, "POST", await enrollBody(install, mesh, { name: "laptop", wgPublicKey: WG1 })),
    ]);
    expect([server.status, client.status].sort()).toEqual([201, 409]);
  });

  it("refuses wildcard expansion before persistence and leaves the existing policy readable", async () => {
    await h.dispose(); h = await makeHarness({ mesh: { budgets: { overlayRulesPerMesh: 1 } } });
    key = await h.addKey(TEAM, ALL_SCOPES);
    mesh = idOf(await json(await call("/v1/meshes", "POST", {})));
    expect((await call(`/v1/meshes/${mesh}/devices`, "POST", await enrollBody(install, mesh, { name: "laptop", wgPublicKey: WG2 }))).status).toBe(201);
    expect((await call(`/v1/meshes/${mesh}/acl`, "PUT", { expectedVersion: 0, rules: [{ src: ["device:*"], dst: ["device:*"], allow: ["tcp:4100"] }] })).status).toBe(200);
    const first = idOf(await json(await enroll()));
    const original = install;
    install = await makeInstallKey();
    const refused = await enroll("dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDM=");
    expect(refused.status).toBe(429);
    install = original;
    expect((await policy(first)).status).toBe(200);
    expect((await json(await call(`/v1/meshes/${mesh}/overlay-servers`)))["items"]).toHaveLength(1);
    expect((await call(`/v1/meshes/${mesh}`, "DELETE")).status).toBe(409);
  });

  it("bounds metadata admission separately from Cloud VM entitlements and enforces credential restrictions", async () => {
    await h.dispose(); h = await makeHarness({ mesh: { budgets: { overlayServersPerMesh: 1 } } });
    key = await h.addKey(TEAM, ALL_SCOPES);
    mesh = idOf(await json(await call("/v1/meshes", "POST", {})));
    h.setBilling(TEAM, false);
    const response = await enroll(); expect(response.status).toBe(201);
    const server = idOf(await json(response));
    expect((await call(`/v1/overlay-servers/${server}`, "GET", undefined, await h.addKey(TEAM, ["mesh:read"])) ).status).toBe(403);
    expect((await call(`/v1/overlay-servers/${server}`, "GET", undefined, await h.addKey(TEAM, ALL_SCOPES, { allowlist: [] }))).status).toBe(404);
    install = await makeInstallKey(); expect((await enroll(WG2)).status).toBe(429);
  });

  it("fails closed on cross-inventory key ambiguity left by an old gateway writer", async () => {
    const server = idOf(await json(await enroll()));
    const client = idOf(record((await json(await call(`/v1/meshes/${mesh}/devices`, "POST", await enrollBody(install, mesh, { name: "laptop", wgPublicKey: WG2 }))))["device"]));
    expect((await call(`/v1/meshes/${mesh}/acl`, "PUT", { expectedVersion: 0, rules: [{ src: [client], dst: [server], allow: ["tcp:4100"] }] })).status).toBe(200);
    const row = h.mesh.store.devices[0];
    if (row === undefined) throw new Error("missing gateway fixture");
    h.mesh.store.devices.push({ ...row, deviceId: newDeviceId(), wgPublicKey: WG1 });
    expect((await policy(server)).status).toBe(503);
    expect((await json(await call(`/v1/devices/${client}/overlay-policy`)))["peers"]).toEqual([]);
  });
});
