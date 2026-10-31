/**
 * PATCH /v1/vms/{vmId} (cx-b4h.2) and PATCH /v1/snapshots/{snapshotId}
 * (cx-b4h.9): only tenant-changeable fields, provider PATCH bodies built from
 * an allowlist, and labels that never cross an ownership boundary. Scope and
 * cross-tenant isolation run in isolation.test.ts and snapshots.test.ts.
 */
import { afterEach, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let current: Harness | undefined;
const harness = async (options: HarnessOptions = {}) => { current = await makeHarness(options); return current; };
afterEach(async () => { await current?.dispose(); current = undefined; });

const TENANT = "team_alpha";
const patchVm = (t: Harness, headers: Record<string, string>, vmId: string, body: unknown) =>
  t.request(`/v1/vms/${vmId}`, headers, { method: "PATCH", body });
const patchSnapshot = (t: Harness, key: string, snapshotId: string, body: unknown) =>
  t.request(`/v1/snapshots/${snapshotId}`, bearer(key), { method: "PATCH", body });
const rowOf = (t: Harness, cmuxId: string) => t.resources.find((row) => row.cmuxId === cmuxId);

it("renames, relabels and changes a VM's limits, sending the provider only the limits", async () => {
  const t = await harness(), { vmId, upstreamId } = t.addVm(TENANT, "running", { team: "a" });
  const key = await t.addKey(TENANT, ["vm:write"]);
  const response = await patchVm(t, bearer(key), vmId, { displayName: "build box", labels: { team: "b", env: "ci" }, idleTimeoutSeconds: 120, maxRunSeconds: 3600, autoDeleteSeconds: -1 });
  const text = await response.text();
  expect(response.status).toBe(200);
  expect(JSON.parse(text)).toMatchObject({ id: vmId, displayName: "build box", labels: { team: "b", env: "ci" }, idleTimeoutSeconds: 120, maxRunSeconds: 3600, autoDeleteSeconds: null });
  expect(text).not.toContain(upstreamId);
  expect(t.upstream.callsTo("PATCH", /^\/v5\/vms\//).map((c) => [c.path, c.json])).toEqual([
    [`/v5/vms/${upstreamId}`, { idleTimeoutSeconds: 120, maxRunSeconds: 3600, autoDeleteSeconds: -1 }],
  ]);
  expect(t.upstream.vms.get(upstreamId)).toMatchObject({ displayName: null, metadata: {} });
  expect(rowOf(t, vmId)).toMatchObject({ displayName: "build box", labels: { team: "b", env: "ci" } });
  expect(await (await t.request(`/v1/vms/${vmId}`, bearer(await t.addKey(TENANT, ["vm:read"])))).json()).toMatchObject({ displayName: "build box", labels: { team: "b", env: "ci" } });
  expect(t.audit.map((row) => [row.action, row.cmuxId, row.outcome])).toEqual([["vm.update", vmId, "ok"]]);
});

it("changes only the name without a provider write, and null clears it", async () => {
  const t = await harness(), { vmId } = t.addVm(TENANT);
  const key = await t.addKey(TENANT, ["vm:write"]);
  expect((await patchVm(t, bearer(key), vmId, { displayName: "x" })).status).toBe(200);
  expect(await (await patchVm(t, bearer(key), vmId, { displayName: null })).json()).toMatchObject({ displayName: null });
  expect(t.upstream.callsTo("PATCH", /./)).toHaveLength(0);
});

it.each([
  [{ slug: "mine" }],
  [{ metadata: { cmuxTenant: "team_bravo" } }],
  [{ maxRunTotalSeconds: 100 }],
  [{ ttlSeconds: 60 }],
  [{ automaticRestart: true }],
  [{ displayName: "" }],
  [{ labels: { "Bad Key": "x" } }],
])("refuses fields the tenant may not change %#", async (body) => {
  const t = await harness(), { vmId } = t.addVm(TENANT);
  const key = await t.addKey(TENANT, ["vm:write"]);
  expect((await patchVm(t, bearer(key), vmId, body)).status).toBe(400);
  expect(t.upstreamRequests).toHaveLength(0);
});

it("refuses an empty update", async () => {
  const t = await harness(), { vmId } = t.addVm(TENANT);
  const key = await t.addKey(TENANT, ["vm:write"]);
  expect((await patchVm(t, bearer(key), vmId, {})).status).toBe(400);
  expect(t.upstreamRequests).toHaveLength(0);
});

it("never adds, removes or changes cmux.* labels", async () => {
  const t = await harness(), agentVm = t.addVm(TENANT, "running", { "cmux.agent": "key_1" }), plain = t.addVm(TENANT);
  const key = await t.addKey(TENANT, ["vm:write"]);
  for (const [vmId, labels] of [[agentVm.vmId, {}], [agentVm.vmId, { "cmux.agent": "key_2" }], [plain.vmId, { "cmux.agent": "key_1" }]] as const) {
    const response = await patchVm(t, bearer(key), vmId, { labels });
    expect(response.status).toBe(403);
  }
  expect(rowOf(t, agentVm.vmId)?.labels).toEqual({ "cmux.agent": "key_1" });
  expect(rowOf(t, plain.vmId)?.labels).toEqual({});
  expect((await patchVm(t, bearer(key), agentVm.vmId, { labels: { "cmux.agent": "key_1", team: "a" } })).status).toBe(200);
});

it("keeps a service key's labels on the VMs it reaches", async () => {
  const t = await harness(), { vmId } = t.addVm(TENANT, "running", { role: "chief" });
  const service = await t.addServiceKey({ scopes: ["vm:write"] });
  const headers = { ...bearer(service), "X-Cmux-Team-Id": TENANT };
  expect((await patchVm(t, headers, vmId, { labels: { role: "other" } })).status).toBe(403);
  expect(rowOf(t, vmId)?.labels).toEqual({ role: "chief" });
  expect((await patchVm(t, headers, vmId, { labels: { role: "chief", task: "t1" } })).status).toBe(200);
  // A team member may take the VM back from the service.
  const member = await t.addKey(TENANT, ["vm:write"]);
  expect((await patchVm(t, bearer(member), vmId, { labels: {} })).status).toBe(200);
  expect((await patchVm(t, headers, vmId, { displayName: "x" })).status).toBe(404);
});

it("applies the dev/test idle rule", async () => {
  const t = await harness(), { vmId } = t.addVm(TENANT);
  const key = await t.addKey(TENANT, ["vm:write"]);
  expect((await patchVm(t, bearer(key), vmId, { idleTimeoutSeconds: -1 })).status).toBe(400);
  expect((await patchVm(t, bearer(key), vmId, { idleTimeoutSeconds: 301 })).status).toBe(400);
  expect(t.upstreamRequests).toHaveLength(0);
});

it("leaves a retired VM retired", async () => {
  const t = await harness(), { vmId, upstreamId } = t.addVm(TENANT);
  const key = await t.addKey(TENANT, ["vm:write"]);
  expect((await t.request(`/v1/vms/${vmId}/retire`, bearer(key), { method: "POST" })).status).toBe(200);
  expect((await patchVm(t, bearer(key), vmId, { maxRunSeconds: -1, autoDeleteSeconds: 600, displayName: "old" })).status).toBe(200);
  expect(t.upstream.vms.get(upstreamId)).toMatchObject({ maxRunTotalSeconds: 0 });
  expect((await t.request(`/v1/vms/${vmId}/start`, bearer(key), { method: "POST" })).status).toBe(409);
});

it("refuses a VM whose create has not finished", async () => {
  const t = await harness(), { vmId } = t.addVm(TENANT);
  const index = t.resources.findIndex((row) => row.cmuxId === vmId);
  const row = t.resources[index];
  if (row === undefined) throw new Error("no row");
  t.resources[index] = { ...row, committed: false };
  const key = await t.addKey(TENANT, ["vm:write"]);
  expect((await patchVm(t, bearer(key), vmId, { displayName: "x" })).status).toBe(409);
  expect(t.upstreamRequests).toHaveLength(0);
});

it("renames, relabels and changes a snapshot's retention", async () => {
  const t = await harness(), { snapshotId, upstreamId } = t.s3a.addSnapshot(TENANT, { displayName: "before", labels: { a: "1" } });
  const key = await t.addKey(TENANT, ["snapshot:write", "snapshot:read"]);
  const response = await patchSnapshot(t, key, snapshotId, { displayName: "after", labels: { b: "2" }, ttlSeconds: 86400, autoDeleteSeconds: null });
  const text = await response.text();
  expect(response.status).toBe(200);
  expect(JSON.parse(text)).toMatchObject({ id: snapshotId, displayName: "after", labels: { b: "2" }, ttlSeconds: 86400, autoDeleteSeconds: null });
  expect(text).not.toContain(upstreamId);
  expect(t.upstream.callsTo("PATCH", /^\/v5\/snapshots\//).map((c) => [c.path, c.json])).toEqual([
    [`/v5/snapshots/${upstreamId}`, { ttlSeconds: 86400, autoDeleteSeconds: -1 }],
  ]);
  expect(t.upstream.snapshots.get(upstreamId)?.displayName).toBeUndefined();
  const listed: unknown = await (await t.request("/v1/snapshots", bearer(key))).json();
  expect(listed).toMatchObject({ items: [{ id: snapshotId, displayName: "after", labels: { b: "2" } }] });
  expect(t.audit.map((row) => [row.action, row.cmuxId, row.outcome])).toEqual([["snapshot.update", snapshotId, "ok"]]);
});

it.each([[{ slug: "x" }], [{ public: true }], [{ ttlSeconds: 1 }], [{}]])("refuses snapshot fields the tenant may not change %#", async (body) => {
  const t = await harness(), { snapshotId } = t.s3a.addSnapshot(TENANT);
  const key = await t.addKey(TENANT, ["snapshot:write"]);
  expect((await patchSnapshot(t, key, snapshotId, body)).status).toBe(400);
  expect(t.upstream.callsTo("PATCH", /./)).toHaveLength(0);
});

it("keeps cmux.* snapshot labels", async () => {
  const t = await harness(), { snapshotId } = t.s3a.addSnapshot(TENANT, { labels: { "cmux.agent": "key_1" } });
  const key = await t.addKey(TENANT, ["snapshot:write"]);
  expect((await patchSnapshot(t, key, snapshotId, { labels: {} })).status).toBe(403);
  expect(rowOf(t, snapshotId)?.labels).toEqual({ "cmux.agent": "key_1" });
});

it("never answers 409 for a rename after changing the provider limits", async () => {
  const t = await harness(), { vmId, upstreamId } = t.addVm(TENANT, "running", { team: "a" });
  const key = await t.addKey(TENANT, ["vm:write"]);
  let limitsChanged = false;
  // Another writer renames the VM while the provider PATCH runs.
  t.upstream.updateReplies.set(upstreamId, () => {
    limitsChanged = true;
    const index = t.resources.findIndex((row) => row.cmuxId === vmId);
    const row = t.resources[index];
    if (row !== undefined) t.resources[index] = { ...row, displayName: "racer" };
    const vm = t.upstream.vms.get(upstreamId);
    return Response.json({ id: upstreamId, slug: `slug-${upstreamId}`, snapshotId: `sc-${upstreamId}`, state: vm?.state ?? "running", resources: vm?.resources, idleTimeoutSeconds: vm?.idleTimeoutSeconds ?? 300, maxRunTotalSeconds: null, maxRunSeconds: 3600, displayName: null, metadata: {}, createdAt: "2026-10-01T00:00:00Z", updatedAt: "2026-10-02T00:00:00Z" });
  });
  const response = await patchVm(t, bearer(key), vmId, { displayName: "mine", maxRunSeconds: 3600 });
  // The name was claimed before the provider write, so the later rename cannot turn an applied limit change into a 409.
  expect(limitsChanged).toBe(true);
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({ displayName: "mine", maxRunSeconds: 3600 });
});

it("a failed limit change puts the VM's name and labels back", async () => {
  const t = await harness(), { vmId } = t.addVm(TENANT, "running", { team: "a" });
  const key = await t.addKey(TENANT, ["vm:write"]);
  t.upstream.fail("update", 503);
  const response = await patchVm(t, bearer(key), vmId, { displayName: "mine", labels: { team: "b" }, maxRunSeconds: 3600 });
  expect(response.status).toBe(503);
  // The provider call failed after the name was claimed, so the name is put back.
  expect(rowOf(t, vmId)).toMatchObject({ displayName: null, labels: { team: "a" } });
});

it("a failed snapshot retention change puts the name and labels back", async () => {
  const t = await harness(), { snapshotId } = t.s3a.addSnapshot(TENANT, { displayName: "before", labels: { a: "1" } });
  const key = await t.addKey(TENANT, ["snapshot:write"]);
  t.upstream.fail("updateSnapshot", 400);
  expect((await patchSnapshot(t, key, snapshotId, { displayName: "after", labels: { b: "2" }, ttlSeconds: 86400 })).status).toBe(400);
  expect(rowOf(t, snapshotId)).toMatchObject({ displayName: "before", labels: { a: "1" } });
});
