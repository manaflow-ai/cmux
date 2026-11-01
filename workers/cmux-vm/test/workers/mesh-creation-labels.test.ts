import { expect, it } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

it("allows the Cloud service to create and replay only a mesh carrying its required labels", async () => {
  const h = await makeHarness();
  try {
    const key = await h.addServiceKey({ scopes: ["mesh:read", "mesh:write"], labels: { role: "cloud" }, teams: ["team_alpha"] });
    const headers = { ...bearer(key), "x-cmux-team-id": "team_alpha", "idempotency-key": "cloud-team-network" };
    const create = () => h.request("/v1/mesh-creations", headers, { method: "POST", body: { displayName: "Cloud network", labels: { role: "cloud" } } });
    const first = await create();
    expect(first.status).toBe(201);
    const replay = await create();
    expect(replay.status).toBe(201);
    expect(await replay.json()).toEqual(await first.json());
    expect(h.upstreamRequests.filter((r) => r.method === "POST" && r.path === "/v5/vpcs")).toHaveLength(1);
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
