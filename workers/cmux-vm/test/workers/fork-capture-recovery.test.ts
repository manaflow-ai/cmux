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
  const fetch = h.s3a.upstream;
  let hidden = true;
  h.s3a.upstream = (request) => hidden && request.method === "GET" && new URL(request.url).pathname.startsWith("/v5/snapshots/")
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

it("keeps an unknown capture single-send and rejects an unrelated recovery receipt", async () => {
  const source = h.addVm("team_alpha"), key = await h.addKey("team_alpha", ["vm:read", "vm:write"]);
  const headers = { ...bearer(key), "idempotency-key": "unknown-fork" };
  const fork = () => h.request(`/v1/vms/${source.vmId}/fork`, headers, { method: "POST", body: {} });
  const fetch = h.s3a.upstream;
  let hidden = true;
  h.s3a.upstream = (request) => hidden && request.method === "GET" && new URL(request.url).pathname.startsWith("/v5/snapshots/")
    ? Promise.resolve(new Response(null, { status: 404 })) : fetch(request);
  h.upstream.faults.lostSnapshotResponses = 1;
  expect((await fork()).status).toBe(503);
  expect((await fork()).status).toBe(503);
  expect((await h.request("/v1/vms", bearer(key), { method: "POST", body: {} })).status).toBe(429);
  const provider = [...h.upstream.snapshots.values()][0]!;
  const originalSource = provider.sourceVmId;
  Object.assign(provider, { sourceVmId: "unrelated-source" });
  hidden = false;
  expect((await fork()).status).toBe(503);
  expect(allocations()).toHaveLength(0);
  Object.assign(provider, { sourceVmId: originalSource });
  expect((await fork()).status).toBe(201);
  expect(captures()).toHaveLength(1);
  expect(allocations()).toHaveLength(1);
});

it("repairs a failed snapshot ownership write without discarding or recapturing", async () => {
  const source = h.addVm("team_alpha"), key = await h.addKey("team_alpha", ["vm:write"]);
  const fork = () => h.request(`/v1/vms/${source.vmId}/fork`, { ...bearer(key), "idempotency-key": "fork-sql" }, { method: "POST", body: {} });
  h.s3a.failNextSnapshotRecord();
  expect((await fork()).status).toBe(503);
  expect(h.upstream.snapshots.size).toBe(1);
  expect((await fork()).status).toBe(201);
  expect(captures()).toHaveLength(1);
  expect(allocations()).toHaveLength(1);
});

it("discovers an unkeyed fork and reconciles its capture without billing or allocating a VM", async () => {
  const source = h.addVm("team_alpha"), key = await h.addKey("team_alpha", ["vm:read", "vm:write"]);
  h.upstream.faults.lostSnapshotResponses = 1;
  const first = await h.request(`/v1/vms/${source.vmId}/fork`, bearer(key), { method: "POST", body: {} });
  expect(first.status).toBe(503);
  const { creationKey } = await first.json<{ creationKey: string }>();
  expect(creationKey).toMatch(/^vcr_/);
  const history = await h.request("/v1/vm-creations", bearer(key));
  const page = await history.json<{ items: Array<{ creationKey: string; id: string; state: string }> }>();
  expect(page.items).toEqual([expect.objectContaining({ creationKey, state: "pending", id: expect.stringMatching(/^vm_/) })]);
  h.setBilling("team_alpha", false);
  expect((await h.request(`/v1/vms/${source.vmId}`, bearer(key), { method: "DELETE" })).status).toBe(204);
  const headers = { ...bearer(key), "idempotency-key": creationKey };
  expect((await h.request("/v1/vm-creations/by-key/reconcile", headers, { method: "POST" })).status).toBe(200);
  expect(allocations()).toHaveLength(0);
  h.setBilling("team_alpha", true);
  const retry = await h.request(`/v1/vms/${source.vmId}/fork`, headers, { method: "POST", body: {} });
  expect(retry.status).toBe(201);
  expect(await retry.json()).toMatchObject({ id: page.items[0]!.id });
  expect(captures()).toHaveLength(1);
});

it("fences a late capture response before VM allocation and cannot resurrect its ownership", async () => {
  const source = h.addVm("team_alpha"), key = await h.addKey("team_alpha", ["vm:read", "vm:write"]);
  const headers = { ...bearer(key), "idempotency-key": "late-fork-capture" };
  const fetch = h.upstream.fetch;
  h.upstream.fetch = async (request) => {
    const response = await fetch(request);
    if (request.method === "POST" && new URL(request.url).pathname.endsWith("/snapshot")) {
      const cancel = await h.request("/v1/vm-creations/by-key/cancel", headers, { method: "POST" });
      expect(cancel.status).toBe(200);
      expect(await cancel.json()).toMatchObject({ state: "cancelled" });
    }
    return response;
  };
  const fork = () => h.request(`/v1/vms/${source.vmId}/fork`, headers, { method: "POST", body: {} });
  expect((await fork()).status).toBe(503);
  expect((await fork()).status).toBe(409);
  const status = await h.request("/v1/vm-creations/by-key", headers);
  expect(await status.json()).toMatchObject({ state: "deleted", cancellation: "completed" });
  expect(allocations()).toHaveLength(0);
  expect(h.upstream.snapshots.size).toBe(0);
});
