import { afterEach, beforeEach, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

let h: Awaited<ReturnType<typeof makeHarness>>;
beforeEach(async () => { h = await makeHarness({ maxVms: 2, maxSnapshots: 1 }); });
afterEach(async () => { await h.dispose(); });
const captures = () => h.upstream.callsTo("POST", /\/snapshot$/);
const allocations = () => h.upstream.callsTo("POST", /^\/v5\/vms$/);

it("recovers a lost fork snapshot response after source deletion without recapturing", async () => {
  const source = h.addVm("team_alpha"), key = await h.addKey("team_alpha", ["vm:read", "vm:write"]);
  const headers = { ...bearer(key), "idempotency-key": "lost-fork-capture" };
  const fork = () => h.request(`/v1/vms/${source.vmId}/fork`, headers, { method: "POST", body: { displayName: "copy" } });
  h.upstream.faults.lostSnapshotResponses = 1;
  expect((await fork()).status).toBe(503);
  const pending = await h.request("/v1/vm-creations/by-key", headers);
  expect(pending.status).toBe(200);
  const intent = await pending.json<{ state: string; id: string }>();
  expect(intent).toMatchObject({ state: "pending", id: expect.stringMatching(/^vm_/) });
  expect((await h.request(`/v1/vms/${source.vmId}`, bearer(key), { method: "DELETE" })).status).toBe(204);
  const recovered = await fork();
  expect(recovered.status).toBe(201);
  expect(await recovered.json()).toMatchObject({ id: intent.id, displayName: "copy" });
  expect(captures()).toHaveLength(1);
  expect(allocations()).toHaveLength(1);
  expect(h.upstream.snapshots.size).toBe(0);
});

it("cancels an uncertain fork capture and retains quota until verified cleanup", async () => {
  const source = h.addVm("team_alpha"), key = await h.addKey("team_alpha", ["vm:read", "vm:write"]);
  const headers = { ...bearer(key), "idempotency-key": "cancel-fork-capture" };
  const fork = () => h.request(`/v1/vms/${source.vmId}/fork`, headers, { method: "POST", body: {} });
  const fetch = h.upstream.fetch;
  let hidden = true;
  h.upstream.fetch = (request) => hidden && request.method === "GET" && new URL(request.url).pathname.startsWith("/v5/snapshots/")
    ? Promise.resolve(new Response(null, { status: 404 })) : fetch(request);
  h.upstream.faults.lostSnapshotResponses = 1;
  expect((await fork()).status).toBe(503);
  const cancelled = await h.request("/v1/vm-creations/by-key/cancel", headers, { method: "POST" });
  expect(cancelled.status).toBe(200);
  const intent = await cancelled.json<{ id: string }>();
  expect(intent).toMatchObject({ state: "cancelling", id: expect.stringMatching(/^vm_/) });
  expect((await fork()).status).toBe(409);
  expect((await h.request("/v1/vms", bearer(key), { method: "POST", body: {} })).status).toBe(429);
  h.setBilling("team_alpha", false);
  expect((await h.request(`/v1/vms/${source.vmId}`, bearer(key), { method: "DELETE" })).status).toBe(204);
  hidden = false;
  const reconciled = await h.request("/v1/vm-creations/by-key/reconcile", headers, { method: "POST" });
  expect(reconciled.status).toBe(200);
  expect(await reconciled.json()).toMatchObject({ state: "deleted", cancellation: "completed", id: intent.id });
  expect(captures()).toHaveLength(1);
  expect(h.upstream.snapshots.size).toBe(0);
  expect(allocations()).toHaveLength(0);
  h.setBilling("team_alpha", true);
  expect((await h.request("/v1/vms", bearer(key), { method: "POST", body: {} })).status).toBe(201);
});
