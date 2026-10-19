import { afterEach, beforeEach, expect, it } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

let h: Awaited<ReturnType<typeof makeHarness>>;
beforeEach(async () => { h = await makeHarness({ mesh: { budgets: { meshesPerTenant: 4 } } }); });
afterEach(async () => { await h.dispose(); });

const create = (key: string, name = "Team network", idempotency = "team-mesh-one") =>
  h.request("/v1/meshes", { ...bearer(key), "idempotency-key": idempotency }, { method: "POST", body: { displayName: name } });

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
