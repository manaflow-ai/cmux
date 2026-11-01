import { expect, it } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { Schema } from "effect";
import { Mesh } from "../../src/api/mesh.ts";

it.each(["service", "selected"])("refuses unkeyed legacy mesh creation outside a %s credential's resource scope", async (kind) => {
  const h = await makeHarness();
  try {
    const key = kind === "service"
      ? await h.addServiceKey({ scopes: ["mesh:write"], labels: { role: "cloud" } })
      : await h.addKey("team_alpha", ["mesh:write"], { allowlist: [] });
    const reply = await h.request("/v1/meshes", { ...bearer(key), "x-cmux-team-id": "team_alpha" }, { method: "POST", body: {} });
    expect(reply.status).toBe(403);
    expect(h.upstreamRequests).toHaveLength(0);
  } finally { await h.dispose(); }
});

it("allows the Cloud service to create and replay only a mesh carrying its required labels", async () => {
  const h = await makeHarness();
  try {
    const key = await h.addServiceKey({ scopes: ["mesh:read", "mesh:write"], labels: { role: "cloud" }, teams: ["team_alpha"] });
    const headers = { ...bearer(key), "x-cmux-team-id": "team_alpha", "idempotency-key": "cloud-team-network" };
    const create = () => h.request("/v1/mesh-creations", headers, { method: "POST", body: { displayName: "Cloud network", labels: { role: "cloud" } } });
    const first = await create();
    expect(first.status).toBe(201);
    const original = Schema.decodeUnknownSync(Mesh)(await first.json());
    const replay = await create();
    expect(replay.status).toBe(201);
    expect(await replay.json()).toEqual(original);
    expect((await h.request(`/v1/meshes/${original.id}`, headers)).status).toBe(200);
    const list = await h.request("/v1/meshes", headers);
    expect(await list.json()).toEqual({ items: [original] });
    expect(h.upstreamRequests.filter((r) => r.method === "POST" && r.path === "/v5/vpcs")).toHaveLength(1);
  } finally { await h.dispose(); }
});

it("refuses a service's missing or changed required label without consuming a creation slot", async () => {
  const h = await makeHarness();
  try {
    const key = await h.addServiceKey({ scopes: ["mesh:write"], labels: { role: "cloud" } });
    const headers = { ...bearer(key), "x-cmux-team-id": "team_alpha", "idempotency-key": "required-label" };
    for (const labels of [{}, { role: "other" }]) expect((await h.request("/v1/mesh-creations", headers, { method: "POST", body: { labels } })).status).toBe(403);
    expect(h.upstreamRequests).toHaveLength(0);
    expect((await h.request("/v1/mesh-creations", headers, { method: "POST", body: { labels: { role: "cloud" } } })).status).toBe(201);
  } finally { await h.dispose(); }
});

it("retains labels in the original intent across unknown ownership outcomes and key rotation", async () => {
  const h = await makeHarness();
  try {
    const key = await h.addServiceKey({ id: "cloud", scopes: ["mesh:read", "mesh:write"], labels: { role: "cloud" } });
    const call = (secret: string) => h.request("/v1/mesh-creations", { ...bearer(secret), "x-cmux-team-id": "team_alpha", "idempotency-key": "retained-label" }, { method: "POST", body: { labels: { role: "cloud" } } });
    h.meshRecordFault.before = 1;
    expect((await call(key)).status).toBe(503);
    const rotated = await h.addServiceKey({ id: "cloud", scopes: ["mesh:read", "mesh:write"], labels: { role: "cloud" } });
    expect((await call(rotated)).status).toBe(201);
    expect(h.resources.find((r) => r.kind === "mesh")).toMatchObject({ createdBy: "service:cloud", labels: { role: "cloud" } });
    expect(h.upstreamRequests.filter((r) => r.method === "POST" && r.path === "/v5/vpcs")).toHaveLength(1);
  } finally { await h.dispose(); }
});

it("canonicalizes label order, conflicts on changed labels and reserves the journal label", async () => {
  const h = await makeHarness();
  try {
    const key = await h.addKey("team_alpha", ALL_SCOPES), headers = { ...bearer(key), "idempotency-key": "label-intent" };
    const create = (labels: Readonly<Record<string, string>>) => h.request("/v1/mesh-creations", headers, { method: "POST", body: { labels } });
    expect((await create({ cmux_mesh_creation: "replacement" })).status).toBe(403);
    expect(h.upstreamRequests).toHaveLength(0);
    const first = await create({ role: "cloud", purpose: "team" });
    expect(first.status).toBe(201);
    const reordered = await create({ purpose: "team", role: "cloud" });
    expect(reordered.status).toBe(201);
    expect(await reordered.json()).toEqual(await first.json());
    const before = h.upstreamRequests.length;
    expect((await create({ purpose: "different", role: "cloud" })).status).toBe(409);
    expect(h.upstreamRequests).toHaveLength(before);
  } finally { await h.dispose(); }
});

it("keeps meshes hidden from a service whose required labels they do not carry", async () => {
  const h = await makeHarness();
  try {
    const admin = await h.addKey("team_alpha", ALL_SCOPES);
    expect((await h.request("/v1/meshes", bearer(admin), { method: "POST", body: {} })).status).toBe(201);
    const key = await h.addServiceKey({ scopes: ["mesh:read"], labels: { role: "cloud" }, teams: ["team_alpha"] });
    const reply = await h.request("/v1/meshes", { ...bearer(key), "x-cmux-team-id": "team_alpha" });
    expect(reply.status).toBe(200);
    expect(await reply.json()).toEqual({ items: [] });
  } finally { await h.dispose(); }
});

it.each(["service", "team"])("never replays one credential's mesh creation to another %s credential reusing its key", async (other) => {
  const h = await makeHarness();
  try {
    const cloud = await h.addServiceKey({ id: "cloud", scopes: ["mesh:read", "mesh:write"], labels: { role: "cloud" } });
    const second = other === "service"
      ? await h.addServiceKey({ id: "cloud-other", scopes: ["mesh:read", "mesh:write"], labels: { role: "cloud" } })
      : await h.addKey("team_alpha", ALL_SCOPES);
    const call = (secret: string) => h.request("/v1/mesh-creations", { ...bearer(secret), "x-cmux-team-id": "team_alpha", "idempotency-key": "shared-key" }, { method: "POST", body: { displayName: "Cloud network", labels: { role: "cloud" } } });
    const first = await call(cloud);
    expect(first.status).toBe(201);
    const original = Schema.decodeUnknownSync(Mesh)(await first.json());
    // The reused key is a new creation for this credential, so it meets the one-mesh team budget instead of the first mesh.
    const reused = await call(second);
    expect(reused.status).toBe(429);
    expect(await reused.text()).not.toContain(original.id);
    expect(await (await call(cloud)).json()).toEqual(original);
    expect(h.upstreamRequests.filter((r) => r.method === "POST" && r.path === "/v5/vpcs")).toHaveLength(1);
  } finally { await h.dispose(); }
});
