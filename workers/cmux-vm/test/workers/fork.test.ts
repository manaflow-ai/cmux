/**
 * forkVm = snapshot the source, then create a VM from that snapshot. Not
 * atomic: when the snapshot succeeds and the create fails, the caller gets
 * 503 ForkIncomplete naming the kept snapshot, and a retry with the same
 * idempotency key creates from that snapshot instead of taking a second one.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TENANT_A = "team_alpha";
const SNAPSHOT_ID = /^snap_[0-9a-hjkmnp-tv-z]{26}$/;

let h: Harness;
beforeEach(async () => {
  h = await makeHarness();
});
afterEach(async () => {
  await h.dispose();
});

const json = async (response: Response): Promise<Record<string, unknown>> => {
  const body: unknown = await response.json();
  return typeof body === "object" && body !== null ? Object.fromEntries(Object.entries(body)) : {};
};

const fork = (key: string, vmId: string, headers: Record<string, string> = {}, body: unknown = {}) =>
  h.request(`/v1/vms/${vmId}/fork`, { ...bearer(key), ...headers }, { method: "POST", body });

/** The upstream snapshot id a create call booted from. */
const bootedFrom = (call: { readonly json: unknown } | undefined): unknown =>
  typeof call?.json === "object" && call.json !== null && "snapshotId" in call.json ? call.json.snapshotId : null;

const snapshotCalls = () => h.upstream.callsTo("POST", /^\/v5\/vms\/[^/]+\/snapshot$/);
const createCalls = () => h.upstream.callsTo("POST", /^\/v5\/vms$/);

describe("forkVm", () => {
  it("snapshots the source by its exact id, creates from that snapshot, then deletes the snapshot", async () => {
    const source = h.addVm(TENANT_A, "running");
    const key = await h.addKey(TENANT_A, ["vm:read", "vm:write"]);

    const response = await fork(key, source.vmId, {}, { displayName: "copy" });

    expect(response.status).toBe(201);
    const vm = await json(response);
    expect(vm).toMatchObject({ displayName: "copy", idleTimeoutSeconds: 300 });
    expect(vm.id).not.toEqual(source.vmId);

    expect(snapshotCalls().map((call) => call.path)).toEqual([`/v5/vms/${source.upstreamId}/snapshot`]);
    expect(h.upstream.snapshots.size).toBe(0);
    const created = createCalls();
    expect(created).toHaveLength(1);
    expect(created[0]?.json).toMatchObject({
      snapshotId: expect.stringMatching(/^sh-/),
      metadata: { cmux_tenant: TENANT_A, cmux_id: vm.id, cmux_env: "local" },
    });
    const deleted = h.upstream.callsTo("DELETE", /^\/v5\/snapshots\//).map((call) => call.path);
    expect(deleted).toEqual([`/v5/snapshots/${String(bootedFrom(created[0]))}`]);

    expect((await h.request(`/v1/vms/${String(vm.id)}`, bearer(key))).status).toBe(200);
    expect(h.audit).toEqual([expect.objectContaining({ action: "vm.fork", cmuxId: vm.id, outcome: "ok" })]);
  });

  it("returns 503 ForkIncomplete with the kept snapshot when the create fails", async () => {
    const source = h.addVm(TENANT_A, "running");
    const key = await h.addKey(TENANT_A, ["vm:write"]);
    h.upstream.fail("create", 409, 1, { code: "CONFLICT", message: "no capacity" });

    const response = await fork(key, source.vmId);

    expect(response.status).toBe(503);
    const body = await json(response);
    expect(body).toEqual({
      _tag: "ForkIncomplete",
      message: expect.any(String),
      snapshotId: expect.stringMatching(SNAPSHOT_ID),
    });
    expect(h.resources).toContainEqual(expect.objectContaining({ tenantId: TENANT_A, kind: "snapshot", cmuxId: body.snapshotId }));
    expect(h.upstream.snapshots.size).toBe(1);
    expect(JSON.stringify(body)).not.toMatch(/sh-|vm-/);
  });

  it("resumes from the kept snapshot on a retry with the same idempotency key, without a second snapshot", async () => {
    const source = h.addVm(TENANT_A, "running");
    const key = await h.addKey(TENANT_A, ["vm:write"]);
    const headers = { "idempotency-key": "fork-1" };
    h.upstream.fail("create", 503);

    const failed = await fork(key, source.vmId, headers);
    expect(failed.status).toBe(503);
    const { snapshotId } = await json(failed);

    const retried = await fork(key, source.vmId, headers);
    expect(retried.status).toBe(201);

    expect(snapshotCalls()).toHaveLength(1);
    const creates = createCalls();
    expect(creates).toHaveLength(2);
    expect(bootedFrom(creates[1])).toEqual(bootedFrom(creates[0]));
    expect(h.resources.find((row) => row.cmuxId === snapshotId)).toBeDefined();

    const replay = await fork(key, source.vmId, headers);
    expect(replay.status).toBe(201);
    expect((await json(replay)).id).toEqual((await json(retried)).id);
    expect(snapshotCalls()).toHaveLength(1);
    expect(createCalls()).toHaveLength(2);
  });

  it("keeps the snapshot after a failed fork without an idempotency key", async () => {
    const source = h.addVm(TENANT_A, "running");
    const key = await h.addKey(TENANT_A, ["vm:write"]);
    h.upstream.fail("create", 409);

    const response = await fork(key, source.vmId);

    expect(response.status).toBe(503);
    expect(h.upstream.snapshots.size).toBe(1);
    expect(h.upstream.callsTo("DELETE", /^\/v5\/snapshots\//)).toHaveLength(0);
  });

  it("creates nothing when the snapshot itself fails", async () => {
    const source = h.addVm(TENANT_A, "stopped");
    const key = await h.addKey(TENANT_A, ["vm:write"]);

    const response = await fork(key, source.vmId);

    expect(response.status).toBe(409);
    expect(createCalls()).toHaveLength(0);
    expect(h.resources.filter((row) => row.kind === "snapshot")).toHaveLength(0);
  });

  it("refuses a fork without billing before taking a snapshot", async () => {
    const source = h.addVm(TENANT_A, "running");
    h.setBilling(TENANT_A, false);
    const key = await h.addKey(TENANT_A, ["vm:write"]);

    expect((await fork(key, source.vmId)).status).toBe(402);
    expect(snapshotCalls()).toHaveLength(0);
  });
});
