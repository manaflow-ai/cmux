/**
 * The VM lifecycle against the fake upstream: create, list, start, stop,
 * pause, resume, delete, with tenant tagging, idle timeouts, billing, quotas,
 * rate limits, idempotency and the audit log.
 */
import { afterEach, describe, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TENANT_A = "team_alpha";
const TENANT_B = "team_bravo";
const VM_ID = /^vm_[0-9a-hjkmnp-tv-z]{26}$/;

let h: Harness | undefined;
const harness = async (options: HarnessOptions = {}) => {
  h = await makeHarness(options);
  return h;
};
afterEach(async () => {
  await h?.dispose();
  h = undefined;
});

const json = async (response: Response): Promise<Record<string, unknown>> => {
  const body: unknown = await response.json();
  return typeof body === "object" && body !== null ? Object.fromEntries(Object.entries(body)) : {};
};

const createVm = (t: Harness, key: string, body: unknown = {}, headers: Record<string, string> = {}) =>
  t.request("/v1/vms", { ...bearer(key), ...headers }, { method: "POST", body });

describe("createVm", () => {
  it("creates a VM tagged with the tenant, records ownership, and leaks no upstream id", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:read", "vm:write"]);

    const response = await createVm(t, key, { displayName: "build box" });

    expect(response.status).toBe(201);
    const text = await response.text();
    const vm: unknown = JSON.parse(text);
    expect(vm).toMatchObject({ state: "starting", displayName: "build box", idleTimeoutSeconds: 300 });
    const id = typeof vm === "object" && vm !== null && "id" in vm ? String(vm.id) : "";
    expect(id).toMatch(VM_ID);

    const creates = t.upstream.callsTo("POST", /^\/v5\/vms$/);
    expect(creates).toHaveLength(1);
    expect(creates[0]?.json).toEqual({
      displayName: `cmux-vm-local ${TENANT_A} ${id}`,
      idleTimeoutSeconds: 300,
      metadata: { cmux_tenant: TENANT_A, cmux_id: id, cmux_env: "local" },
      firewall: { rules: [] },
    });
    const upstreamId = [...t.upstream.vms.keys()][0] ?? "missing";
    expect(text).not.toContain(upstreamId);
    expect(text).not.toContain("leak-check");
    expect(t.resources).toContainEqual(expect.objectContaining({ tenantId: TENANT_A, kind: "vm", cmuxId: id, upstreamId }));

    const read = await t.request(`/v1/vms/${id}`, bearer(key));
    expect(read.status).toBe(200);
    expect(await json(read)).toMatchObject({ id, displayName: "build box" });
  });

  it("audits the create with tenant, key and cmux id", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:write"]);
    const vm = await json(await createVm(t, key));
    expect(t.audit).toEqual([
      { tenantId: TENANT_A, actor: expect.stringMatching(/^key:vmk_/), action: "vm.create", cmuxId: vm.id, outcome: "ok", ownerActor: null },
    ]);
  });

  it("caps dev/test idle timeouts at 300 seconds", async () => {
    const t = await harness({ environment: "staging" });
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    const tooLong = await createVm(t, key, { idleTimeoutSeconds: 301 });
    const never = await createVm(t, key, { idleTimeoutSeconds: -1 });
    const short = await createVm(t, key, { idleTimeoutSeconds: 60 });

    expect(tooLong.status).toBe(400);
    expect(await json(tooLong)).toMatchObject({ _tag: "BadRequest" });
    expect(never.status).toBe(400);
    expect(short.status).toBe(201);
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/).map((call) => call.json)).toEqual([
      expect.objectContaining({ idleTimeoutSeconds: 60 }),
    ]);
  });

  it("gives product machines in production no idle timeout, and dev/test tenants there 300 seconds", async () => {
    const t = await harness({ environment: "production", devTestTenants: [TENANT_B] });
    const product = await t.addKey(TENANT_A, ["vm:write"]);
    const devTest = await t.addKey(TENANT_B, ["vm:write"]);

    expect((await createVm(t, product)).status).toBe(201);
    expect((await createVm(t, devTest)).status).toBe(201);
    expect((await createVm(t, devTest, { idleTimeoutSeconds: 3600 })).status).toBe(400);

    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/).map((call) => call.json)).toEqual([
      expect.objectContaining({ idleTimeoutSeconds: -1, metadata: expect.objectContaining({ cmux_tenant: TENANT_A, cmux_env: "production" }) }),
      expect.objectContaining({ idleTimeoutSeconds: 300, metadata: expect.objectContaining({ cmux_tenant: TENANT_B }) }),
    ]);
  });

  it("boots from the tenant's own snapshot by its upstream id", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:write"]);
    const { snapshotId, upstreamId } = t.addSnapshot(TENANT_A);

    const response = await createVm(t, key, { snapshotId });

    expect(response.status).toBe(201);
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)[0]?.json).toMatchObject({ snapshotId: upstreamId });
  });

  it("refuses a tenant without billing with 402 and creates nothing", async () => {
    const t = await harness();
    t.setBilling(TENANT_A, false);
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    const response = await createVm(t, key);

    expect(response.status).toBe(402);
    expect(await json(response)).toMatchObject({ _tag: "PaymentRequired" });
    expect(t.upstreamRequests).toHaveLength(0);
    expect(t.audit).toEqual([expect.objectContaining({ action: "vm.create", cmuxId: null, outcome: "PaymentRequired" })]);
  });

  it("enforces the per-tenant VM quota, counting only the tenant's live VMs", async () => {
    const t = await harness({ maxVms: 1 });
    const keyA = await t.addKey(TENANT_A, ["vm:write"]);
    const keyB = await t.addKey(TENANT_B, ["vm:write"]);

    const first = await json(await createVm(t, keyA));
    const second = await createVm(t, keyA);
    const otherTenant = await createVm(t, keyB);

    expect(second.status).toBe(429);
    expect(await json(second)).toMatchObject({ _tag: "QuotaExceeded", budget: "vms" });
    expect(otherTenant.status).toBe(201);

    expect((await t.request(`/v1/vms/${String(first.id)}`, bearer(keyA), { method: "DELETE" })).status).toBe(204);
    expect((await createVm(t, keyA)).status).toBe(201);
  });

  it("rate limits each tenant separately", async () => {
    const t = await harness({ ratePerMinute: { write: 2 } });
    const keyA = await t.addKey(TENANT_A, ["vm:write"]);
    const keyB = await t.addKey(TENANT_B, ["vm:write"]);

    expect((await createVm(t, keyA)).status).toBe(201);
    expect((await createVm(t, keyA)).status).toBe(201);
    const limited = await createVm(t, keyA);
    expect(limited.status).toBe(429);
    expect(await json(limited)).toMatchObject({ _tag: "QuotaExceeded", retryAfterSeconds: expect.any(Number), budget: "rate" });
    expect((await createVm(t, keyB)).status).toBe(201);
  });
});

describe("idempotency keys on create", () => {
  it("returns the first VM for a retried key and creates once", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:write"]);
    const headers = { "idempotency-key": "create-1" };

    const first = await createVm(t, key, { displayName: "a" }, headers);
    const second = await createVm(t, key, { displayName: "a" }, headers);

    expect(first.status).toBe(201);
    expect(second.status).toBe(201);
    expect((await json(second)).id).toEqual((await json(first)).id);
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
  });

  it("refuses the same key with a different request", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:write"]);
    const headers = { "idempotency-key": "create-2" };

    await createVm(t, key, { displayName: "a" }, headers);
    const reused = await createVm(t, key, { displayName: "b" }, headers);

    expect(reused.status).toBe(409);
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
  });

  it("keeps keys per tenant", async () => {
    const t = await harness();
    const keyA = await t.addKey(TENANT_A, ["vm:write"]);
    const keyB = await t.addKey(TENANT_B, ["vm:write"]);
    const headers = { "idempotency-key": "same" };

    const a = await json(await createVm(t, keyA, {}, headers));
    const b = await json(await createVm(t, keyB, {}, headers));

    expect(a.id).not.toEqual(b.id);
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(2);
  });

  it("lets a failed create be retried with the same key", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:write"]);
    const headers = { "idempotency-key": "create-3" };
    t.upstream.fail("create", 503);

    expect((await createVm(t, key, {}, headers)).status).toBe(503);
    expect((await createVm(t, key, {}, headers)).status).toBe(201);
  });
});

describe("listVms", () => {
  it("pages through the ownership table, newest first", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const ids: string[] = [];
    for (let index = 0; index < 3; index += 1) ids.push(String((await json(await createVm(t, key))).id));

    const page1 = await json(await t.request("/v1/vms?limit=2", bearer(key)));
    expect(page1).toMatchObject({ items: [{ id: ids[2] }, { id: ids[1] }] });
    expect(typeof page1.nextCursor).toBe("string");

    const page2 = await json(await t.request(`/v1/vms?limit=2&cursor=${encodeURIComponent(String(page1.nextCursor))}`, bearer(key)));
    expect(page2).toMatchObject({ items: [{ id: ids[0] }], nextCursor: null });
  });

  it("filters by state", async () => {
    const t = await harness();
    const running = t.addVm(TENANT_A, "running");
    t.addVm(TENANT_A, "paused");
    const key = await t.addKey(TENANT_A, ["vm:read"]);

    const body = await json(await t.request("/v1/vms?state=running", bearer(key)));

    expect(body).toMatchObject({ items: [{ id: running.vmId, state: "running" }], nextCursor: null });
  });

  it("drops rows whose upstream VM is gone", async () => {
    const t = await harness();
    const gone = t.addVm(TENANT_A);
    const kept = t.addVm(TENANT_A);
    t.dropUpstreamVm(gone.upstreamId);
    const key = await t.addKey(TENANT_A, ["vm:read"]);

    const body = await json(await t.request("/v1/vms", bearer(key)));

    expect(body).toMatchObject({ items: [{ id: kept.vmId }] });
  });

  it("rejects a cursor from another tenant", async () => {
    const t = await harness();
    const keyA = await t.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const keyB = await t.addKey(TENANT_B, ["vm:read"]);
    for (let index = 0; index < 2; index += 1) await createVm(t, keyA);
    const page = await json(await t.request("/v1/vms?limit=1", bearer(keyA)));

    const foreign = await t.request(`/v1/vms?cursor=${encodeURIComponent(String(page.nextCursor))}`, bearer(keyB));

    expect(foreign.status).toBe(400);
  });
});

describe("start, stop, pause, resume", () => {
  const action = (t: Harness, key: string, vmId: string, verb: string) => t.request(`/v1/vms/${vmId}/${verb}`, bearer(key), { method: "POST" });

  it("start boots a stopped VM through the upstream start of its exact id", async () => {
    const t = await harness();
    const { vmId, upstreamId } = t.addVm(TENANT_A, "stopped");
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    const response = await action(t, key, vmId, "start");

    expect(response.status).toBe(200);
    expect(await json(response)).toMatchObject({ id: vmId, state: "running" });
    expect(t.upstreamRequests.map((call) => `${call.method} ${call.path}`)).toEqual([`POST /v5/vms/${upstreamId}/start`]);
    expect(t.audit).toEqual([expect.objectContaining({ action: "vm.start", cmuxId: vmId, outcome: "ok" })]);
  });

  it("resume is start of a paused VM", async () => {
    const t = await harness();
    const { vmId, upstreamId } = t.addVm(TENANT_A, "paused");
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    const response = await action(t, key, vmId, "resume");

    expect(response.status).toBe(200);
    expect(await json(response)).toMatchObject({ state: "running" });
    expect(t.upstream.callsTo("POST", new RegExp(`^/v5/vms/${upstreamId}/start$`))).toHaveLength(1);
  });

  it("resume refuses a VM that is not paused", async () => {
    const t = await harness();
    const { vmId } = t.addVm(TENANT_A, "stopped");
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    const response = await action(t, key, vmId, "resume");

    expect(response.status).toBe(409);
    expect(t.upstream.callsTo("POST", /\/start$/)).toHaveLength(0);
  });

  it("pause freezes a running VM and refuses one that is not running", async () => {
    const t = await harness();
    const running = t.addVm(TENANT_A, "running");
    const stopped = t.addVm(TENANT_A, "stopped");
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    const paused = await action(t, key, running.vmId, "pause");
    const refused = await action(t, key, stopped.vmId, "pause");

    expect(await json(paused)).toMatchObject({ state: "paused" });
    expect(refused.status).toBe(409);
    expect(await json(refused)).toMatchObject({ _tag: "Conflict" });
  });

  it("stop shuts a running VM down from inside the guest", async () => {
    const t = await harness();
    const { vmId, upstreamId } = t.addVm(TENANT_A, "running");
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    const response = await action(t, key, vmId, "stop");

    expect(response.status).toBe(200);
    expect(await json(response)).toMatchObject({ id: vmId, state: "stopped" });
    expect(t.upstream.callsTo("POST", new RegExp(`^/v5/vms/${upstreamId}/exec-await$`)).map((call) => call.json)).toEqual([
      { command: "poweroff", timeoutMs: 10000 },
    ]);
  });

  it("stop is a no-op on a stopped VM and refuses a paused one", async () => {
    const t = await harness();
    const stopped = t.addVm(TENANT_A, "stopped");
    const paused = t.addVm(TENANT_A, "paused");
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    const again = await action(t, key, stopped.vmId, "stop");
    const refused = await action(t, key, paused.vmId, "stop");

    expect(again.status).toBe(200);
    expect(await json(again)).toMatchObject({ state: "stopped" });
    expect(refused.status).toBe(409);
    expect(t.upstream.callsTo("POST", /exec-await$/)).toHaveLength(0);
  });
});

describe("deleteVm", () => {
  it("deletes the upstream VM by its exact id and forgets it", async () => {
    const t = await harness();
    const { vmId, upstreamId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:read", "vm:write"]);

    const response = await t.request(`/v1/vms/${vmId}`, bearer(key), { method: "DELETE" });

    expect(response.status).toBe(204);
    expect(t.upstream.callsTo("DELETE", /^\/v5\/vms\//).map((call) => call.path)).toEqual([`/v5/vms/${upstreamId}`]);
    expect((await t.request(`/v1/vms/${vmId}`, bearer(key))).status).toBe(404);
    expect((await t.request(`/v1/vms/${vmId}`, bearer(key), { method: "DELETE" })).status).toBe(404);
    // Refused attempts are audited too, with the public error they got.
    expect(t.audit).toEqual([
      expect.objectContaining({ action: "vm.delete", cmuxId: vmId, outcome: "ok" }),
      expect.objectContaining({ action: "vm.delete", cmuxId: vmId, outcome: "NotFound" }),
    ]);
  });

  it("forgets a VM that is already gone upstream", async () => {
    const t = await harness();
    const { vmId, upstreamId } = t.addVm(TENANT_A);
    t.dropUpstreamVm(upstreamId);
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    expect((await t.request(`/v1/vms/${vmId}`, bearer(key), { method: "DELETE" })).status).toBe(204);
  });
});
