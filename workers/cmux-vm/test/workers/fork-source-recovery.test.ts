import { afterEach, beforeEach, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

let h: Awaited<ReturnType<typeof makeHarness>>;
beforeEach(async () => { h = await makeHarness(); });
afterEach(async () => { await h.dispose(); });
const fork = (key: string, source: string, idempotency = "retained-fork", body: unknown = {}) =>
  h.request(`/v1/vms/${source}/fork`, { ...bearer(key), "idempotency-key": idempotency }, { method: "POST", body });
const remove = (key: string, id: string) => h.request(`/v1/vms/${id}`, bearer(key), { method: "DELETE" });
const allocations = () => h.upstream.callsTo("POST", /^\/v5\/vms$/);
const snapshots = () => h.upstream.callsTo("POST", /\/snapshot$/);

it("replays a completed fork after its source is deleted and never recreates a deleted destination", async () => {
  const source = h.addVm("team_alpha"), key = await h.addKey("team_alpha", ["vm:write"]);
  const first = await fork(key, source.vmId);
  expect(first.status).toBe(201);
  const vm = await first.json<{ id: string }>();
  expect((await remove(key, source.vmId)).status).toBe(204);
  const replay = await fork(key, source.vmId);
  expect(replay.status).toBe(201);
  expect(await replay.json()).toMatchObject({ id: vm.id });
  expect((await remove(key, vm.id)).status).toBe(204);
  expect((await fork(key, source.vmId)).status).toBe(404);
  expect(allocations()).toHaveLength(1);
  expect(snapshots()).toHaveLength(1);
  expect(h.upstream.vms.size).toBe(0);
});

it("resumes the retained snapshot after a confirmed create rejection and source deletion", async () => {
  const source = h.addVm("team_alpha"), key = await h.addKey("team_alpha", ["vm:write"]);
  h.upstream.fail("create", 429);
  expect((await fork(key, source.vmId)).status).toBe(503);
  expect((await remove(key, source.vmId)).status).toBe(204);
  expect((await fork(key, source.vmId)).status).toBe(201);
  expect(snapshots()).toHaveLength(1);
  expect(allocations()).toHaveLength(2);
  expect(h.upstream.vms.size).toBe(1);
  expect(h.upstream.snapshots.size).toBe(0);
});

it("repairs an unrecorded fork allocation after source deletion without sending a second create", async () => {
  const source = h.addVm("team_alpha"), key = await h.addKey("team_alpha", ["vm:write"]);
  // The snapshot ownership write precedes the VM ownership write.
  // Fail the VM write by injecting the fault only after the provider create.
  const fetch = h.upstream.fetch;
  h.upstream.fetch = async (request) => {
    const response = await fetch(request);
    if (request.method === "POST" && new URL(request.url).pathname === "/v5/vms") h.recordFault.before = 1;
    return response;
  };
  expect((await fork(key, source.vmId)).status).toBe(503);
  expect((await remove(key, source.vmId)).status).toBe(204);
  expect((await fork(key, source.vmId)).status).toBe(201);
  expect(snapshots()).toHaveLength(1);
  expect(allocations()).toHaveLength(1);
  expect(h.upstream.vms.size).toBe(1);
});

it("checks the original request identity even after the source is gone", async () => {
  const source = h.addVm("team_alpha"), other = h.addVm("team_alpha"), key = await h.addKey("team_alpha", ["vm:write"]);
  expect((await fork(key, source.vmId)).status).toBe(201);
  expect((await remove(key, source.vmId)).status).toBe(204);
  expect((await fork(key, source.vmId, "retained-fork", { displayName: "different" })).status).toBe(409);
  expect((await fork(key, other.vmId)).status).toBe(409);
  expect(allocations()).toHaveLength(1);
  expect(snapshots()).toHaveLength(1);
});

it("requires the source for a fresh fork and refuses cross-tenant and scope-limited replay", async () => {
  const source = h.addVm("team_alpha"), key = await h.addKey("team_alpha", ["vm:write"]);
  expect((await fork(key, source.vmId)).status).toBe(201);
  expect((await remove(key, source.vmId)).status).toBe(204);
  expect((await fork(key, source.vmId, "fresh-fork")).status).toBe(404);
  expect((await fork(await h.addKey("team_bravo", ["vm:write"]), source.vmId)).status).toBe(404);
  expect((await fork(await h.addKey("team_alpha", ["vm:read"]), source.vmId)).status).toBe(403);
  expect((await fork(await h.addKey("team_alpha", ["vm:write"], { allowlist: [source.vmId] }), source.vmId)).status).toBe(403);
  expect(allocations()).toHaveLength(1);
  expect(snapshots()).toHaveLength(1);
});

it("keeps the cancellation fence effective after the fork source is deleted", async () => {
  const source = h.addVm("team_alpha"), key = await h.addKey("team_alpha", ["vm:write"]);
  const fetch = h.upstream.fetch;
  h.upstream.fetch = async (request) => {
    const response = await fetch(request);
    if (request.method === "POST" && new URL(request.url).pathname === "/v5/vms") h.recordFault.before = 1;
    return response;
  };
  expect((await fork(key, source.vmId)).status).toBe(503);
  expect((await remove(key, source.vmId)).status).toBe(204);
  const cancelled = await h.request("/v1/vm-creations/by-key/cancel", { ...bearer(key), "idempotency-key": "retained-fork" }, { method: "POST" });
  expect(cancelled.status).toBe(200);
  expect(await cancelled.json()).toMatchObject({ state: "cancelled" });
  expect((await fork(key, source.vmId)).status).toBe(409);
  expect(allocations()).toHaveLength(1);
  expect(h.upstream.vms.size).toBe(0);
});

it("reauthorizes the destination against current service labels on replay", async () => {
  const source = h.addVm("team_alpha", "running", { role: "cloud" });
  const service = await h.addServiceKey({ id: "cloud-fork", labels: { role: "cloud" }, teams: ["team_alpha"] });
  const headers = { ...bearer(service), "x-cmux-team-id": "team_alpha", "idempotency-key": "service-fork" };
  const retry = () => h.request(`/v1/vms/${source.vmId}/fork`, headers, { method: "POST", body: { labels: { role: "cloud" } } });
  const response = await retry(); expect(response.status).toBe(201);
  const vm = await response.json<{ id: string }>();
  const member = await h.addKey("team_alpha", ["vm:write"]);
  expect((await remove(member, source.vmId)).status).toBe(204);
  expect((await retry()).status).toBe(201);
  const row = h.resources.find((resource) => resource.cmuxId === vm.id)!;
  Object.assign(row, { labels: { role: "unrelated" } });
  expect((await retry()).status).toBe(404);
  expect(allocations()).toHaveLength(1);
});
