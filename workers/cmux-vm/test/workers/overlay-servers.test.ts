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
const signed = async (purpose: string, target: string, wgPublicKey = "", name = "", signedAt = Date.now()) => {
  const nonce = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16)))).replace(/\+/gu, "-").replace(/\//gu, "_").replace(/=+$/u, "");
  const message = ["cmux-mesh-v1", purpose, target, wgPublicKey, install.publicKey, name, String(signedAt), nonce].join("\n");
  const bytes = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, install.privateKey, new TextEncoder().encode(message)));
  return { signedAt, nonce, signature: btoa(String.fromCharCode(...bytes)) };
};
const enroll = async (wgPublicKey = WG1, name = "server") => call(`/v1/meshes/${mesh}/overlay-servers`, "POST", {
  name, wgPublicKey, installPublicKey: install.publicKey, ...await signed("enroll-overlay-server", mesh, wgPublicKey, name),
});
const SECRET = `whsec_${btoa("overlay-server-webhook-secret-32!")}`;
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

  it("binds signed policy and revocation to their own purpose, key, target and freshness", async () => {
    const server = idOf(await json(await enroll()));
    const send = (body: unknown, suffix = "policy") => h.request(`/v1/overlay-servers/${server}/signed/${suffix}`, {}, { method: "POST", body });
    const request = await signed("overlay-server-policy", server);
    expect((await send(request, "revoke")).status).toBe(404);
    expect((await send(request)).status).toBe(200);
    expect((await send(request)).status).toBe(409);
    expect((await send(await signed("overlay-server-policy", server, "", "", Date.now() - 180_000))).status).toBe(403);
    expect((await send(await signed("overlay-server-policy", newDeviceId()))).status).toBe(404);
    install = await makeInstallKey();
    expect((await policy(server)).status).toBe(404);
    expect((await call(`/v1/overlay-servers/${server}`)).status).toBe(200);
  });

  it("does not reuse a positive membership cache for policy or signed revocation", async () => {
    h.addMember(TEAM, "user_network");
    const token = await h.sessionToken("user_network");
    const response = await h.request(`/v1/meshes/${mesh}/overlay-servers`, { ...bearer(token), "x-cmux-team-id": TEAM }, { method: "POST", body: { name: "server", wgPublicKey: WG1, installPublicKey: install.publicKey, ...await signed("enroll-overlay-server", mesh, WG1, "server") } });
    expect(response.status).toBe(201);
    const server = idOf(await json(response));
    expect((await policy(server)).status).toBe(200);
    h.failStackFor("user_network");
    expect((await policy(server)).status).toBe(503);
    h.failStackFor("user_network", false);
    h.removeMember(TEAM, "user_network");
    expect((await policy(server)).status).toBe(404);
    expect((await h.request(`/v1/overlay-servers/${server}/signed/revoke`, {}, { method: "POST", body: await signed("revoke-overlay-server", server) })).status).toBe(404);
    expect((await call(`/v1/overlay-servers/${server}`, "DELETE")).status).toBe(204);
  });

  it("a removed or deleted user's servers stay revoked after a re-add (G1 webhook)", async () => {
    await h.dispose(); h = await makeHarness({ stackWebhookSecret: SECRET }); key = await h.addKey(TEAM, ALL_SCOPES);
    mesh = idOf(await json(await call("/v1/meshes", "POST", {})));
    const session = async (user: string) => ({ ...bearer(await h.sessionToken(user)), "x-cmux-team-id": TEAM });
    const enrollAs = async (user: string, server: InstallKey, wgPublicKey: string) => {
      install = server;
      const response = await h.request(`/v1/meshes/${mesh}/overlay-servers`, await session(user), { method: "POST", body: { name: user, wgPublicKey, installPublicKey: server.publicKey, ...await signed("enroll-overlay-server", mesh, wgPublicKey, user) } });
      expect(response.status).toBe(201);
      return { id: idOf(await json(response)), install: server };
    };
    const signedPolicy = async (server: { id: string; install: InstallKey }) => { install = server.install; return policy(server.id); };
    h.addMember(TEAM, "user_ada"); h.addMember(TEAM, "user_bob");
    const ada = await enrollAs("user_ada", await makeInstallKey(), WG1);
    const bob = await enrollAs("user_bob", await makeInstallKey(), WG2);
    install = await makeInstallKey();
    const laptop = idOf(record((await json(await call(`/v1/meshes/${mesh}/devices`, "POST", await enrollBody(install, mesh, { name: "laptop", wgPublicKey: "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDM=" }))))["device"]));
    expect((await call(`/v1/meshes/${mesh}/acl`, "PUT", { expectedVersion: 0, rules: [{ src: ["device:*"], dst: ["device:*"], allow: ["tcp:4100"] }] })).status).toBe(200);
    const peers = async () => (await json(await call(`/v1/devices/${laptop}/overlay-policy`)))["peers"];
    expect(await peers()).toEqual(expect.arrayContaining([expect.objectContaining({ deviceId: ada.id }), expect.objectContaining({ deviceId: bob.id })]));

    h.removeMember(TEAM, "user_ada");
    expect((await h.stackWebhook({ type: "team_membership.deleted", data: { team_id: TEAM, user_id: "user_ada" } }, { id: "msg_ada" })).status).toBe(200);
    h.addMember(TEAM, "user_ada");
    // A removal cuts the servers that existed then; the re-add does not bring them back.
    expect(await peers()).toEqual([expect.objectContaining({ deviceId: bob.id })]);
    expect((await signedPolicy(ada)).status).toBe(404);
    expect((await call(`/v1/overlay-servers/${ada.id}`)).status).toBe(404);
    expect((await signedPolicy(bob)).status).toBe(200);

    // user.deleted with a stale (empty) team list still finds the tenant holding the user's server.
    expect((await h.stackWebhook({ type: "user.deleted", data: { id: "user_bob", teams: [] } }, { id: "msg_bob" })).status).toBe(200);
    expect(await peers()).toEqual([]);
    expect((await signedPolicy(bob)).status).toBe(404);
    expect((await call(`/v1/overlay-servers/${bob.id}`)).status).toBe(404);
  });
});
