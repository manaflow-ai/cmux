import { afterEach, beforeEach, expect, it } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { Schema } from "effect";
import { Mesh } from "../../src/api/mesh.ts";

let h: Awaited<ReturnType<typeof makeHarness>>;
beforeEach(async () => { h = await makeHarness({ mesh: { budgets: { meshesPerTenant: 4 } } }); });
afterEach(async () => { await h.dispose(); });

const create = (key: string, name = "Team network", idempotency = "team-mesh-one") =>
  h.request("/v1/meshes", { ...bearer(key), "idempotency-key": idempotency }, { method: "POST", body: { displayName: name } });
const meshBody = async (r: Response) => Schema.decodeUnknownSync(Mesh)(await r.json());
const networkSends = () => h.upstreamRequests.filter((r) => r.method === "POST" && r.path === "/v5/vpcs");

it("replays an acknowledged mesh creation without allocating another network", async () => {
  const key = await h.addKey("team_alpha", ALL_SCOPES);
  const first = await create(key), second = await create(key);
  expect(first.status).toBe(201);
  expect(second.status).toBe(201);
  expect(await second.json()).toEqual(await first.json());
  expect(h.upstreamRequests.filter((r) => r.method === "POST" && r.path === "/v5/vpcs")).toHaveLength(1);
});

it("rejects changed business intent under the same mesh creation key before provider I/O", async () => {
  const key = await h.addKey("team_alpha", ALL_SCOPES);
  expect((await create(key)).status).toBe(201);
  const before = h.upstreamRequests.length;
  expect((await create(key, "Different network")).status).toBe(409);
  expect(h.upstreamRequests).toHaveLength(before);
});

it("replays a committed creation even when its network filled the mesh budget", async () => {
  await h.dispose();
  h = await makeHarness({ mesh: { budgets: { meshesPerTenant: 1 } } });
  const key = await h.addKey("team_alpha", ALL_SCOPES);
  expect((await create(key)).status).toBe(201);
  expect((await create(key)).status).toBe(201);
  expect(h.upstreamRequests.filter((r) => r.method === "POST" && r.path === "/v5/vpcs")).toHaveLength(1);
});

it("never shares a creation key between two API keys of a tenant or across tenants", async () => {
  const first = await h.addKey("team_alpha", ALL_SCOPES), second = await h.addKey("team_alpha", ALL_SCOPES), other = await h.addKey("team_bravo", ALL_SCOPES);
  const a = await meshBody(await create(first));
  const own = await meshBody(await create(second));
  expect(own.id).not.toBe(a.id);
  expect(own.ipv4Cidr).not.toBe(a.ipv4Cidr);
  const b = await meshBody(await create(other));
  expect(b.id).not.toBe(a.id);
  expect(await meshBody(await create(first))).toEqual(a);
  expect(networkSends()).toHaveLength(3);
  expect(h.resources.filter((r) => r.kind === "mesh")).toHaveLength(3);
});

it("never replays an API key's mesh creation to a session of the same team, nor the reverse", async () => {
  h.addMember("team_alpha", "owner");
  h.addAdmin("team_alpha", "owner");
  const session = await h.sessionToken("owner"), key = await h.addKey("team_alpha", ALL_SCOPES);
  const bySession = () => h.request("/v1/meshes", { authorization: `Bearer ${session}`, "x-cmux-team-id": "team_alpha", "idempotency-key": "team-mesh-one" }, { method: "POST", body: { displayName: "Team network" } });
  const fromKey = await meshBody(await create(key));
  const fromSession = await meshBody(await bySession());
  expect(fromSession.id).not.toBe(fromKey.id);
  expect(await meshBody(await bySession())).toEqual(fromSession);
  expect(await meshBody(await create(key))).toEqual(fromKey);
  expect(networkSends()).toHaveLength(2);
});

it("recovers a lost provider reply using the exact stable slug", async () => {
  const key = await h.addKey("team_alpha", ALL_SCOPES);
  h.mesh.loseNetworkReplies(1);
  const first = await create(key);
  expect(first.status).toBe(201);
  const body = await meshBody(first);
  expect(await meshBody(await create(key))).toEqual(body);
  expect(networkSends()).toHaveLength(1);
  expect(h.mesh.vpcs.size).toBe(1);
  expect(h.upstreamRequests.some((r) => r.method === "GET" && r.path === `/v5/vpcs/cmux-mesh-local-${body.id.replace("_", "-")}`)).toBe(true);
  expect(JSON.stringify(body)).not.toContain("vpc-");
});

it("never repeats an uncertain send when the network is not yet discoverable", async () => {
  const key = await h.addKey("team_alpha", ALL_SCOPES);
  h.mesh.loseNetworkReplies(1);
  h.mesh.hideNetworks(true);
  expect((await create(key)).status).toBe(503);
  expect((await create(key)).status).toBe(503);
  expect(h.mesh.vpcs.size).toBe(1);
  expect(networkSends()).toHaveLength(1);
  h.setBilling("team_alpha", false);
  h.mesh.hideNetworks(false);
  // Reading the already allocated network does not authorize another allocation.
  expect((await create(key)).status).toBe(201);
  expect(networkSends()).toHaveLength(1);
});

it("keeps a failed ownership write recoverable without discarding the network or CIDR", async () => {
  const key = await h.addKey("team_alpha", ALL_SCOPES);
  h.meshRecordFault.before = 1;
  expect((await create(key)).status).toBe(503);
  expect(h.mesh.vpcs.size).toBe(1);
  expect(h.resources.filter((r) => r.kind === "mesh")).toHaveLength(0);
  const retry = await create(key);
  expect(retry.status).toBe(201);
  expect(await meshBody(await create(key))).toEqual(await meshBody(retry));
  expect(networkSends()).toHaveLength(1);
  expect(h.upstreamRequests.some((r) => r.method === "DELETE")).toBe(false);
});

it("replays an ownership commit whose acknowledgement was lost at the full budget", async () => {
  await h.dispose();
  h = await makeHarness({ mesh: { budgets: { meshesPerTenant: 1 } } });
  const key = await h.addKey("team_alpha", ALL_SCOPES);
  h.meshRecordFault.after = 1;
  expect((await create(key)).status).toBe(503);
  expect((await create(key)).status).toBe(201);
  expect(networkSends()).toHaveLength(1);
});

it("retains the quota of a possibly allocated network and refuses another intent", async () => {
  await h.dispose();
  h = await makeHarness({ mesh: { budgets: { meshesPerTenant: 1 } } });
  const key = await h.addKey("team_alpha", ALL_SCOPES);
  h.mesh.failNetworkCreates(503);
  expect((await create(key)).status).toBe(503);
  h.mesh.failNetworkCreates(null);
  expect((await create(key, "Team network", "another-intent")).status).toBe(429);
  expect((await create(key)).status).toBe(503);
  expect(networkSends()).toHaveLength(1);
});

it.each([400, 409, 429])("retries a documented non-allocating %s rejection with the retained quota", async (status) => {
  const key = await h.addKey("team_alpha", ALL_SCOPES);
  h.mesh.failNetworkCreates(status);
  expect((await create(key)).status).toBe(503);
  h.mesh.failNetworkCreates(null);
  expect((await create(key)).status).toBe(201);
  expect(networkSends()).toHaveLength(2);
  expect(h.mesh.vpcs.size).toBe(1);
});

it("rechecks entitlement before retrying a rejected allocation", async () => {
  const key = await h.addKey("team_alpha", ALL_SCOPES);
  h.mesh.failNetworkCreates(429);
  expect((await create(key)).status).toBe(503);
  h.mesh.failNetworkCreates(null);
  h.setBilling("team_alpha", false);
  expect((await create(key)).status).toBe(402);
  expect(networkSends()).toHaveLength(1);
});

it("fences a changed provider context after an uncertain send before any further provider I/O", async () => {
  const key = await h.addKey("team_alpha", ALL_SCOPES);
  h.mesh.failNetworkCreates(503);
  expect((await create(key)).status).toBe(503);
  const before = h.upstreamRequests.length;
  h.mesh.setProviderConfig("https://another-provider.test");
  expect((await create(key)).status).toBe(503);
  expect(h.upstreamRequests).toHaveLength(before);
});

it("does not adopt a network whose recovered metadata differs from the retained intent", async () => {
  const key = await h.addKey("team_alpha", ALL_SCOPES);
  h.meshRecordFault.before = 1;
  expect((await create(key)).status).toBe(503);
  const original = [...h.mesh.vpcs.values()][0];
  if (!original) throw Error("network not allocated");
  h.mesh.vpcs.set(original.id, { ...original, cidr: "10.0.0.0/24" });
  expect((await create(key)).status).toBe(503);
  expect(h.resources.filter((r) => r.kind === "mesh")).toHaveLength(0);
  expect(networkSends()).toHaveLength(1);
});

it("serializes concurrent attempts before sending the allocating request", async () => {
  const key = await h.addKey("team_alpha", ALL_SCOPES), release = h.mesh.holdNetworkCreates();
  const first = create(key);
  await h.mesh.networkCreateHeld();
  try {
    expect((await create(key)).status).toBe(409);
    expect(networkSends()).toHaveLength(1);
  } finally { release(); }
  expect((await first).status).toBe(201);
});

it("keeps a deleted creation key terminal and frees the mesh budget for a new key", async () => {
  await h.dispose();
  h = await makeHarness({ mesh: { budgets: { meshesPerTenant: 1 } } });
  const key = await h.addKey("team_alpha", ALL_SCOPES), body = await meshBody(await create(key));
  expect((await h.request(`/v1/meshes/${body.id}`, bearer(key), { method: "DELETE" })).status).toBe(204);
  const before = h.upstreamRequests.length;
  expect((await create(key)).status).toBe(404);
  expect(h.upstreamRequests).toHaveLength(before);
  expect((await create(key, "Team network", "replacement")).status).toBe(201);
  expect(h.mesh.vpcs.size).toBe(1);
});

it("never lets a selected-resource key replay another key's creation, and refuses its unknown intents without consuming them", async () => {
  const full = await h.addKey("team_alpha", ALL_SCOPES), body = await meshBody(await create(full));
  const selected = await h.addKey("team_alpha", ALL_SCOPES, { allowlist: [body.id] });
  const denied = await h.addKey("team_alpha", ALL_SCOPES, { allowlist: [] });
  const before = h.upstreamRequests.length;
  const reply = await create(selected);
  expect(reply.status).toBe(404);
  expect(await reply.text()).not.toContain(body.id);
  expect((await create(denied)).status).toBe(404);
  expect((await create(selected, "Team network", "unclaimed")).status).toBe(404);
  expect(h.upstreamRequests).toHaveLength(before);
  expect(await meshBody(await create(full))).toEqual(body);
  expect((await create(full, "Team network", "unclaimed")).status).toBe(201);
});

it("refuses non-admin sessions and service credentials whose required labels cannot be met", async () => {
  h.addMember("team_alpha", "viewer");
  const session = await h.sessionToken("viewer");
  expect((await h.request("/v1/meshes", { authorization: `Bearer ${session}`, "x-cmux-team-id": "team_alpha", "idempotency-key": "team-mesh-one" }, { method: "POST", body: {} })).status).toBe(403);
  const service = await h.addServiceKey({ scopes: ["mesh:write"], labels: { service: "cloud" }, teams: ["team_alpha"] });
  expect((await h.request("/v1/meshes", { ...bearer(service), "x-cmux-team-id": "team_alpha", "idempotency-key": "team-mesh-one" }, { method: "POST", body: {} })).status).toBe(403);
  expect(networkSends()).toHaveLength(0);
});
