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
