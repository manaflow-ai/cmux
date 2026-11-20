import { expect, it } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

it("requires the durable creation route and replays its original mesh at a full quota", async () => {
  const h = await makeHarness({ mesh: { budgets: { meshesPerTenant: 1 } } });
  try {
    const key = await h.addKey("team_alpha", ALL_SCOPES);
    const create = () => h.request("/v1/mesh-creations", { ...bearer(key), "idempotency-key": "cloud-team-mesh" }, { method: "POST", body: { displayName: "Cloud network" } });
    const first = await create();
    expect(first.status).toBe(201);
    const second = await create();
    expect(second.status).toBe(201);
    expect(await second.json()).toEqual(await first.json());
    expect(h.upstreamRequests.filter((r) => r.method === "POST" && r.path === "/v5/vpcs")).toHaveLength(1);
  } finally { await h.dispose(); }
});

it("refuses a missing creation key before provider allocation", async () => {
  const h = await makeHarness();
  try {
    const key = await h.addKey("team_alpha", ALL_SCOPES);
    expect((await h.request("/v1/mesh-creations", bearer(key), { method: "POST", body: {} })).status).toBe(400);
    expect(h.upstreamRequests).toHaveLength(0);
  } finally { await h.dispose(); }
});

it("shares the same intent across creation routes and refuses changed payloads", async () => {
  const h = await makeHarness();
  try {
    const key = await h.addKey("team_alpha", ALL_SCOPES), headers = { ...bearer(key), "idempotency-key": "shared-creation" };
    const first = await h.request("/v1/mesh-creations", headers, { method: "POST", body: {} });
    expect(first.status).toBe(201);
    const legacy = await h.request("/v1/meshes", headers, { method: "POST", body: {} });
    expect(legacy.status).toBe(201);
    expect(await legacy.json()).toEqual(await first.json());
    expect((await h.request("/v1/mesh-creations", headers, { method: "POST", body: { displayName: "Different intent" } })).status).toBe(409);
    expect(h.upstreamRequests.filter((r) => r.method === "POST" && r.path === "/v5/vpcs")).toHaveLength(1);
  } finally { await h.dispose(); }
});
