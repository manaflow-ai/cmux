/**
 * The VM lifecycle against the fake upstream: create, list, start, stop,
 * pause, resume, delete, with tenant tagging, idle timeouts, billing, quotas,
 * rate limits, idempotency and the audit log.
 */
import { afterEach, describe, expect, it } from "vitest";
import { withRequestConnection } from "../../src/db/sql.ts";
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
      slug: `cmux-vm-local-${id.replace("_", "-")}`,
      displayName: `cmux-vm-local ${TENANT_A} ${id}`,
      idleTimeoutSeconds: 300,
      metadata: { cmux_tenant: TENANT_A, cmux_id: id, cmux_env: "local", cmux_actor: expect.stringMatching(/^key:/), cmux_create: expect.stringMatching(/^[A-Za-z0-9_-]+$/) },
      firewall: { rules: [] },
      customer: { customerId: TENANT_A },
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
      expect.objectContaining({ idleTimeoutSeconds: -1, metadata: expect.objectContaining({ cmux_tenant: TENANT_A, cmux_env: "production" }), customer: { customerId: TENANT_A } }),
      expect.objectContaining({ idleTimeoutSeconds: 300, metadata: expect.objectContaining({ cmux_tenant: TENANT_B }), customer: { customerId: TENANT_B } }),
    ]);
  });

  it("tags a Stack team's VM with the vault's production tenant key, outside the create digest", async () => {
    const team = "0b6f3a52-6c1e-4f43-9a1e-2d7c5e8f9a10";
    const t = await harness({ environment: "production" });
    t.setBilling(team, true);
    const key = await t.addKey(team, ["vm:write"]);

    expect((await createVm(t, key)).status).toBe(201);
    const [sent] = t.upstream.callsTo("POST", /^\/v5\/vms$/).map((call) => call.json);
    expect(sent).toMatchObject({ metadata: { cmux_tenant: team, cmux_vt: team } });
    expect(sent).not.toHaveProperty("metadata.cmux_vt_stg");
    expect(sent).not.toHaveProperty("metadata.cmux_vt_dev");
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

  it("reports provider infrastructure overload as unavailable without exposing its response", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:write"]);
    t.upstream.fail("create", 429, 1, { message: "infrastructure overloaded: VM start capacity queue wait expired" });

    const response = await createVm(t, key);

    expect(response.status).toBe(503);
    const body = await json(response);
    expect(body).toMatchObject({ _tag: "ServiceUnavailable" });
    expect(JSON.stringify(body)).not.toContain("infrastructure overloaded");
    expect(JSON.stringify(body)).not.toContain("capacity queue wait expired");
  });

  it("answers a VM call past the rate limit 429 before 404, though both are read at once", async () => {
    const t = await harness({ ratePerMinute: { write: 2 } });
    const { vmId } = t.addVm(TENANT_A, "stopped");
    const keyB = await t.addKey(TENANT_B, ["vm:write"]);
    const start = () => t.request(`/v1/vms/${vmId}/start`, bearer(keyB), { method: "POST" });

    // Another tenant's VM is 404 while the caller is under its limit, and is never started.
    expect((await start()).status).toBe(404);
    expect((await start()).status).toBe(404);
    // Past the limit it is 429: the limit is judged before ownership, as when they were read in turn.
    const limited = await start();
    expect(limited.status).toBe(429);
    expect(await json(limited)).toMatchObject({ _tag: "QuotaExceeded", budget: "rate" });
    expect(t.upstream.callsTo("POST", /\/start$/)).toHaveLength(0);
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

  it("retries a confirmed capacity rejection with the same key", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:write"]);
    const headers = { "idempotency-key": "create-3" };
    t.upstream.fail("create", 429);

    expect((await createVm(t, key, {}, headers)).status).toBe(429);
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

  it("forgets a long-committed VM the provider no longer has, so the next list reads only live ones", async () => {
    const t = await harness();
    const old = new Date(Date.now() - 2 * 3600_000);
    const gone = t.addVm(TENANT_A, "running", {}, { createdAt: old });
    const fresh = t.addVm(TENANT_A, "running", {}, { createdAt: new Date(Date.now() - 60_000) });
    const pending = t.addVm(TENANT_A, "running", {}, { createdAt: old, committed: false });
    const kept = t.addVm(TENANT_A);
    for (const vm of [gone, fresh, pending]) t.dropUpstreamVm(vm.upstreamId);
    const key = await t.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const reads = (vmUpstreamId: string) =>
      t.upstreamRequests.filter((call) => call.method === "GET" && call.path.endsWith(`/${vmUpstreamId}`)).length;

    expect(await json(await t.request("/v1/vms", bearer(key)))).toMatchObject({ items: [{ id: kept.vmId }] });
    expect(await json(await t.request("/v1/vms", bearer(key)))).toMatchObject({ items: [{ id: kept.vmId }] });

    // The long-committed gone VM was read once and then forgotten (its tombstone answers a repeated delete with 204);
    // a fresh row and an uncommitted one may be creations the provider has not made yet, and are read every time.
    expect(reads(gone.upstreamId)).toBe(1);
    expect(reads(fresh.upstreamId)).toBe(2);
    expect(reads(pending.upstreamId)).toBe(2);
    expect((await t.request(`/v1/vms/${gone.vmId}`, bearer(key))).status).toBe(404);
  });

  it("leaves gone rows alone for a read-only key, which may not delete", async () => {
    const t = await harness();
    const gone = t.addVm(TENANT_A, "running", {}, { createdAt: new Date(Date.now() - 2 * 3600_000) });
    t.dropUpstreamVm(gone.upstreamId);
    const key = await t.addKey(TENANT_A, ["vm:read"]);
    const reads = () => t.upstreamRequests.filter((call) => call.method === "GET" && call.path.endsWith(`/${gone.upstreamId}`)).length;

    await t.request("/v1/vms", bearer(key));
    await t.request("/v1/vms", bearer(key));

    expect(reads()).toBe(2);
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
    // The provider's share of the request, for the caller's own trace (cmuxterm-hq goals/cloud-resume-gap.md).
    // cmux-vm's own gate (scope, rate limit, ownership) is named beside it, so the trace splits ours too.
    expect(response.headers.get("server-timing")).toMatch(/^upstream;dur=\d+;desc="1 call", own;dur=\d+$/);
  });

  it("writes the start's audit row after the answer when the Worker can keep the request alive", async () => {
    const deferred: Array<Promise<unknown>> = [];
    const t = await harness({ perRequest: withRequestConnection, defer: (work) => deferred.push(work) });
    const { vmId } = t.addVm(TENANT_A, "stopped");
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    const response = await action(t, key, vmId, "start");

    expect(response.status).toBe(200);
    // The row is handed to waitUntil, not written before the response (cmuxterm-hq goals/cloud-resume-gap.md).
    expect(deferred).toHaveLength(1);
    await Promise.all(deferred);
    expect(t.audit).toEqual([expect.objectContaining({ action: "vm.start", cmuxId: vmId, outcome: "ok" })]);
  });

  it("names the start's slot wait and gives the slot back without holding the answer", async () => {
    const deferred: Array<Promise<unknown>> = [];
    const calls: Array<string> = [];
    let open = (): void => {};
    const gate = new Promise<void>((resolve) => { open = resolve; });
    const createAdmission = {
      admit: async (holder: string) => { calls.push(`admit ${holder.split(":")[0]}`); return { admitted: true as const, waitedMs: 0, inFlight: 1, queued: 0 }; },
      // A release that never finishes until the gate opens: the answer must not wait on it.
      release: async (holder: string) => { await gate; calls.push(`release ${holder.split(":")[0]}`); },
    };
    const t = await harness({ perRequest: withRequestConnection, defer: (work) => deferred.push(work), createAdmission });
    const { vmId } = t.addVm(TENANT_A, "stopped");
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    const response = await action(t, key, vmId, "start");

    expect(response.status).toBe(200);
    expect(response.headers.get("server-timing")).toMatch(/^upstream;dur=\d+;desc="1 call", own;dur=\d+, admit;dur=\d+$/);
    // The release was a second round trip to the queue object on the answer's path; it now runs on waitUntil.
    expect(calls).toEqual(["admit start"]);
    expect(deferred).toHaveLength(1);
    open();
    await Promise.all(deferred);
    expect(calls).toEqual(["admit start", "release start"]);
  });

  it("gives the start's slot back before the answer when nothing can keep the request alive", async () => {
    const calls: Array<string> = [];
    const createAdmission = {
      admit: async () => { calls.push("admit"); return { admitted: true as const, waitedMs: 0, inFlight: 1, queued: 0 }; },
      release: async () => { calls.push("release"); },
    };
    const t = await harness({ perRequest: withRequestConnection, createAdmission });
    const { vmId } = t.addVm(TENANT_A, "stopped");
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    expect((await action(t, key, vmId, "start")).status).toBe(200);
    expect(calls).toEqual(["admit", "release"]);
  });

  it("writes the audit row before the answer when nothing can keep the request alive", async () => {
    const t = await harness({ perRequest: withRequestConnection });
    const { vmId } = t.addVm(TENANT_A, "stopped");
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    expect((await action(t, key, vmId, "start")).status).toBe(200);
    expect(t.audit).toEqual([expect.objectContaining({ action: "vm.start", cmuxId: vmId, outcome: "ok" })]);
  });

  it("names no upstream time on an answer that made no upstream call", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:read"]);

    const response = await t.request("/v1/vms", bearer(key));

    expect(response.status).toBe(200);
    expect(response.headers.get("server-timing")).toBeNull();
  });

  it("resume is start of a paused VM", async () => {
    const t = await harness();
    const { vmId, upstreamId } = t.addVm(TENANT_A, "paused");
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    const response = await action(t, key, vmId, "resume");

    expect(response.status).toBe(200);
    expect(await json(response)).toMatchObject({ state: "running" });
    expect(t.upstream.callsTo("POST", new RegExp(`^/v5/vms/${upstreamId}/start$`))).toHaveLength(1);
    // The state read and the start: both the provider's.
    expect(response.headers.get("server-timing")).toMatch(/^upstream;dur=\d+;desc="2 calls", own;dur=\d+$/);
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
      { command: "poweroff", timeoutMs: 10000, linuxUser: "root" },
    ]);
  });

  it("stop answers an error, not the running VM as stopped, when the guest refuses the poweroff", async () => {
    const t = await harness();
    const { vmId } = t.addVm(TENANT_A, "running");
    const key = await t.addKey(TENANT_A, ["vm:write"]);
    t.upstream.replyToExec("poweroff", () =>
      Response.json({ statusCode: 1, stdout: "", stderr: "Call to PowerOff failed\n", vmId: "x", node: "n" }));

    const response = await action(t, key, vmId, "stop");

    expect(response.status).toBe(503);
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
    const other = await t.addKey(TENANT_B, ["vm:write"]);
    expect((await t.request(`/v1/vms/${vmId}`, bearer(other), { method: "DELETE" })).status).toBe(404);
    // Refused attempts are audited too, with the public error they got.
    expect(t.audit).toEqual([
      expect.objectContaining({ action: "vm.delete", cmuxId: vmId, outcome: "ok" }),
      expect.objectContaining({ action: "vm.delete", cmuxId: vmId, outcome: "NotFound" }),
    ]);
  });

  it("answers a repeated delete of the caller's own deleted VM with 204, so a lost answer can be retried", async () => {
    const t = await harness();
    const { vmId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:read", "vm:write"]);
    expect((await t.request(`/v1/vms/${vmId}`, bearer(key), { method: "DELETE" })).status).toBe(204);
    // The first 204 was lost: the retry confirms the delete without another provider call.
    expect((await t.request(`/v1/vms/${vmId}`, bearer(key), { method: "DELETE" })).status).toBe(204);
    expect(t.upstream.callsTo("DELETE", /^\/v5\/vms\//)).toHaveLength(1);
    expect((await t.request(`/v1/vms/${vmId}`, bearer(key))).status).toBe(404);
    // Still hidden from another tenant, a key whose allowlist excludes it, and a read-only key.
    const other = await t.addKey(TENANT_B, ["vm:write"]);
    const listed = await t.addKey(TENANT_A, ["vm:write"], { allowlist: [t.addVm(TENANT_A).vmId] });
    const reader = await t.addKey(TENANT_A, ["vm:read"]);
    expect((await t.request(`/v1/vms/${vmId}`, bearer(other), { method: "DELETE" })).status).toBe(404);
    expect((await t.request(`/v1/vms/${vmId}`, bearer(listed), { method: "DELETE" })).status).toBe(404);
    expect((await t.request(`/v1/vms/${vmId}`, bearer(reader), { method: "DELETE" })).status).toBe(403);
  });

  it("forgets a VM that is already gone upstream", async () => {
    const t = await harness();
    const { vmId, upstreamId } = t.addVm(TENANT_A);
    t.dropUpstreamVm(upstreamId);
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    expect((await t.request(`/v1/vms/${vmId}`, bearer(key), { method: "DELETE" })).status).toBe(204);
  });
});
