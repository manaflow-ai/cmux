/**
 * Snapshot endpoints end to end in workerd: real API, middleware, proofs and
 * upstream client, with in-memory stores and a fake provider.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ALL_SCOPES, allScopesExcept, SNAPSHOT_ENDPOINTS } from "../support/endpoints.ts";
import { memoryLedgerStorage, TenantLedger, type LedgerStorage } from "../../src/limits/ledger.ts";
import { memoryLimitsLayer } from "../../src/limits/service.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TENANT_A = "team_alpha";
const TENANT_B = "team_bravo";
const bearer = (token: string) => ({ authorization: `Bearer ${token}` });
const SNAPSHOT_ID = /^snap_[0-9a-hjkmnp-tv-z]{26}$/;

let h: Harness;
beforeEach(async () => {
  h = await makeHarness();
});
afterEach(async () => {
  await h.dispose();
});

const create = (vmId: string, headers: Record<string, string>, body: unknown = {}) =>
  h.request(`/v1/vms/${vmId}/snapshots`, headers, { method: "POST", body });

const upstreamPaths = () => h.upstreamRequests.map((call) => `${call.method} ${call.path}`);

describe("cross-tenant isolation", () => {
  it("returns 404 when tenant B snapshots tenant A's VM, and nothing reaches upstream", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const keyB = await h.addKey(TENANT_B, ["snapshot:write"]);

    const response = await create(vmId, bearer(keyB));

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ _tag: "NotFound", message: "VM not found" });
    expect(h.upstreamRequests).toHaveLength(0);
    expect(h.s3a.snapshotRows(TENANT_B)).toHaveLength(0);
    expect(h.audit).toHaveLength(0);
  });

  it("returns 404 when tenant B reads tenant A's snapshot", async () => {
    const { snapshotId } = h.s3a.addSnapshot(TENANT_A);
    const keyB = await h.addKey(TENANT_B, ["snapshot:read"]);

    const response = await h.request(`/v1/snapshots/${snapshotId}`, bearer(keyB));

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ _tag: "NotFound", message: "Snapshot not found" });
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("returns 404 when tenant B deletes tenant A's snapshot, and the snapshot survives", async () => {
    const { snapshotId, upstreamId } = h.s3a.addSnapshot(TENANT_A);
    const keyB = await h.addKey(TENANT_B, ["snapshot:write"]);

    const response = await h.request(`/v1/snapshots/${snapshotId}`, bearer(keyB), { method: "DELETE" });

    expect(response.status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(0);
    expect(h.upstream.snapshots.has(upstreamId)).toBe(true);
    expect(h.s3a.snapshotRows(TENANT_A)).toHaveLength(1);
  });

  it("lists only the caller's own snapshots and never asks upstream", async () => {
    const mine = h.s3a.addSnapshot(TENANT_A);
    h.s3a.addSnapshot(TENANT_B);
    const keyA = await h.addKey(TENANT_A, ["snapshot:read"]);

    const response = await h.request("/v1/snapshots", bearer(keyA));

    expect(response.status).toBe(200);
    const body = await response.json<{ items: Array<{ id: string }>; nextCursor: string | null }>();
    expect(body.items.map((item) => item.id)).toEqual([mine.snapshotId]);
    expect(body.nextCursor).toBeNull();
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("lists only the snapshots in the key's resource allowlist", async () => {
    const allowed = h.s3a.addSnapshot(TENANT_A);
    h.s3a.addSnapshot(TENANT_A);
    const key = await h.addKey(TENANT_A, ["snapshot:read"], { allowlist: [allowed.snapshotId] });

    const body = await (await h.request("/v1/snapshots", bearer(key))).json<{ items: Array<{ id: string }> }>();

    expect(body.items.map((item) => item.id)).toEqual([allowed.snapshotId]);
  });

  it("filters by another tenant's VM id to an empty list", async () => {
    const theirs = h.addVm(TENANT_B);
    h.s3a.addSnapshot(TENANT_B, { sourceVmId: theirs.vmId });
    h.s3a.addSnapshot(TENANT_A);
    const keyA = await h.addKey(TENANT_A, ["snapshot:read"]);

    const response = await h.request(`/v1/snapshots?sourceVmId=${theirs.vmId}`, bearer(keyA));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ items: [], nextCursor: null });
  });

  it("treats a snapshot outside the key's resource allowlist as missing", async () => {
    const { snapshotId } = h.s3a.addSnapshot(TENANT_A);
    const other = h.s3a.addSnapshot(TENANT_A);
    const key = await h.addKey(TENANT_A, ["snapshot:read"], { allowlist: [other.snapshotId] });
    expect((await h.request(`/v1/snapshots/${snapshotId}`, bearer(key))).status).toBe(404);
  });

  it("gives the same 404 for a missing, a malformed and a VM-shaped snapshot id", async () => {
    const key = await h.addKey(TENANT_A, ["snapshot:read"]);
    const { vmId } = h.addVm(TENANT_A);
    const bodies = [];
    for (const id of ["snap_00000000000000000000000000", "not-a-snapshot", vmId]) {
      const response = await h.request(`/v1/snapshots/${id}`, bearer(key));
      expect(response.status).toBe(404);
      bodies.push(await response.json());
    }
    expect(new Set(bodies.map((body) => JSON.stringify(body))).size).toBe(1);
  });
});

describe("create", () => {
  it("snapshots an owned VM, records ownership and audit, and leaks no upstream id", async () => {
    const { vmId, upstreamId: upstreamVmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["snapshot:write"]);

    const response = await create(vmId, bearer(key), {
      displayName: "ci base",
      ttlSeconds: 86_400,
      autoDeleteSeconds: 3_600,
      labels: { pool: "linux-x64", "runner.cmux.dev/warm": "1" },
    });

    expect(response.status).toBe(201);
    const text = await response.text();
    const body = JSON.parse(text);
    expect(body).toMatchObject({
      sourceVmId: vmId,
      displayName: "ci base",
      labels: { pool: "linux-x64", "runner.cmux.dev/warm": "1" },
      lastUsedAt: null,
    });
    expect(String(body["id"])).toMatch(SNAPSHOT_ID);
    for (const leak of [upstreamVmId, "sh-", "slug-", "leak-check", "freestyle", "Freestyle"]) expect(text).not.toContain(leak);

    expect(upstreamPaths().filter((path) => path.startsWith("POST"))).toEqual([`POST /v5/vms/${upstreamVmId}/snapshot`]);
    expect(h.upstream.callsTo("POST", /\/snapshot$/).at(0)?.json).toMatchObject({
      slug: expect.stringContaining(String(body["id"]).replace("_", "-")),
      displayName: expect.stringMatching(/^cmux-snapshot:[a-f0-9]{64}$/),
      ttlSeconds: 86_400,
      autoDeleteSeconds: 3_600,
    });

    const rows = h.s3a.snapshotRows(TENANT_A);
    expect(rows.map((row) => row.cmuxId)).toEqual([body["id"]]);
    expect(h.upstream.snapshots.has(String(rows.at(0)?.upstreamId))).toBe(true);
    expect(h.audit).toMatchObject([{ tenantId: TENANT_A, action: "snapshot.create", cmuxId: body["id"], outcome: "ok" }]);
    expect(h.audit.at(0)?.actor).toMatch(/^key:vmk_/);
  });

  it("replays the first result for a repeated Idempotency-Key and creates once", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["snapshot:write"]);
    const headers = { ...bearer(key), "idempotency-key": "run-42" };

    const first = await create(vmId, headers, { displayName: "x" });
    const second = await create(vmId, headers, { displayName: "x" });

    expect(first.status).toBe(201);
    expect(second.status).toBe(201);
    expect(await second.json()).toEqual(await first.json());
    expect(upstreamPaths().filter((path) => path.startsWith("POST"))).toHaveLength(1);
    expect(h.s3a.snapshotRows(TENANT_A)).toHaveLength(1);
  });

  it("refuses an Idempotency-Key reused with a different request with 409", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["snapshot:write"]);
    const headers = { ...bearer(key), "idempotency-key": "run-43" };

    expect((await create(vmId, headers, { displayName: "x" })).status).toBe(201);
    const reused = await create(vmId, headers, { displayName: "y" });

    expect(reused.status).toBe(409);
    expect(h.s3a.snapshotRows(TENANT_A)).toHaveLength(1);
  });

  it("scopes Idempotency-Keys to the tenant", async () => {
    const a = h.addVm(TENANT_A);
    const b = h.addVm(TENANT_B);
    const keyA = await h.addKey(TENANT_A, ["snapshot:write"]);
    const keyB = await h.addKey(TENANT_B, ["snapshot:write"]);

    const first = await create(a.vmId, { ...bearer(keyA), "idempotency-key": "shared" });
    const second = await create(b.vmId, { ...bearer(keyB), "idempotency-key": "shared" });

    expect(first.status).toBe(201);
    expect(second.status).toBe(201);
    expect(h.s3a.snapshotRows(TENANT_B)).toHaveLength(1);
  });

  it("refuses with 402 when the tenant is not entitled, before calling upstream", async () => {
    const { vmId } = h.addVm(TENANT_A);
    h.setBilling(TENANT_A, false);
    const key = await h.addKey(TENANT_A, ["snapshot:write"]);

    const response = await create(vmId, bearer(key));

    expect(response.status).toBe(402);
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("has its own snapshot budget: the snapshot limit answers 429 naming it, the VM limit does not apply", async () => {
    const limited = await makeHarness({ maxSnapshots: 2, maxVms: 1 });
    try {
      const first = limited.addVm(TENANT_A);
      limited.addVm(TENANT_A);
      const key = await limited.addKey(TENANT_A, ["snapshot:write"]);
      const snap = () => limited.request(`/v1/vms/${first.vmId}/snapshots`, bearer(key), { method: "POST", body: {} });

      // Two live VMs already exceed maxVms 1; snapshots are counted separately.
      expect((await snap()).status).toBe(201);
      expect((await snap()).status).toBe(201);
      const third = await snap();

      expect(third.status).toBe(429);
      expect(await third.json()).toMatchObject({ _tag: "QuotaExceeded", budget: "snapshots" });
      expect(limited.upstreamRequests.filter((call) => call.method === "POST")).toHaveLength(2);
    } finally {
      await limited.dispose();
    }
  });

  it("frees the snapshot budget when a snapshot is deleted", async () => {
    const limited = await makeHarness({ maxSnapshots: 1 });
    try {
      const { vmId } = limited.addVm(TENANT_A);
      const key = await limited.addKey(TENANT_A, ["snapshot:write"]);
      const created = await limited.request(`/v1/vms/${vmId}/snapshots`, bearer(key), { method: "POST", body: {} });
      const { id } = await created.json<{ id: string }>();
      expect((await limited.request(`/v1/vms/${vmId}/snapshots`, bearer(key), { method: "POST", body: {} })).status).toBe(429);
      expect((await limited.request(`/v1/snapshots/${id}`, bearer(key), { method: "DELETE" })).status).toBe(204);
      expect((await limited.request(`/v1/vms/${vmId}/snapshots`, bearer(key), { method: "POST", body: {} })).status).toBe(201);
    } finally {
      await limited.dispose();
    }
  });

  it("maps a VM that cannot be snapshotted to 409 and audits the failure", async () => {
    const { vmId, upstreamId } = h.addVm(TENANT_A, "stopped");
    const key = await h.addKey(TENANT_A, ["snapshot:write"]);

    const response = await create(vmId, bearer(key));

    expect(response.status).toBe(409);
    expect(await response.text()).not.toContain(upstreamId);
    expect(h.audit).toMatchObject([{ action: "snapshot.create", cmuxId: vmId, outcome: "Conflict" }]);
  });

  it("frees the snapshot slot after an unkeyed capture the provider refuses", async () => {
    const limited = await makeHarness({ maxSnapshots: 1 });
    try {
      const stopped = limited.addVm(TENANT_A, "stopped"), running = limited.addVm(TENANT_A);
      const key = await limited.addKey(TENANT_A, ["snapshot:write", "snapshot:read"]);
      expect((await limited.request(`/v1/vms/${stopped.vmId}/snapshots`, bearer(key), { method: "POST", body: {} })).status).toBe(409);
      expect((await limited.request(`/v1/vms/${running.vmId}/snapshots`, bearer(key), { method: "POST", body: {} })).status).toBe(201);
    } finally {
      await limited.dispose();
    }
  });

  it("retains the captured snapshot for reconciliation when its ownership row cannot be written", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["snapshot:write"]);
    h.s3a.failNextSnapshotRecord();

    const response = await create(vmId, bearer(key));

    expect(response.status).toBe(503);
    expect(h.upstream.snapshots.size).toBe(1);
    const { pendingSnapshotId } = await response.json<{ pendingSnapshotId: string }>();
    expect(pendingSnapshotId).toMatch(SNAPSHOT_ID);
    const repair = await h.request(`/v1/snapshot-creations/${pendingSnapshotId}/reconcile`, bearer(key), { method: "POST" });
    expect(repair.status).toBe(200);
    expect(await repair.json()).toMatchObject({ state: "committed", id: pendingSnapshotId });
    expect(h.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
  });

  it("needs snapshot:write; vm:write is not enough", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["vm:write", "vm:read", "snapshot:read"]);

    const response = await create(vmId, bearer(key));

    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ missingScope: "snapshot:write" });
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("accepts a session token for a member of the team", async () => {
    const { vmId } = h.addVm(TENANT_A);
    h.addMember(TENANT_A, "user_alice");
    const token = await h.sessionToken("user_alice");

    const response = await create(vmId, { ...bearer(token), "x-cmux-team-id": TENANT_A });

    expect(response.status).toBe(201);
    expect(h.audit.at(0)?.actor).toBe("user:user_alice");
  });
});

describe("capture recovery", () => {
  it("adopts a capture whose response was lost instead of capturing changed source contents", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["snapshot:write"]);
    const headers = { ...bearer(key), "idempotency-key": "lost-capture" };
    h.upstream.faults.lostSnapshotResponses = 1;
    expect((await create(vmId, headers)).status).toBe(503);
    expect(h.upstream.snapshots.size).toBe(1);
    const retry = await create(vmId, headers);
    expect(retry.status).toBe(201);
    expect(h.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
    expect(h.upstream.snapshots.size).toBe(1);
    expect(h.s3a.snapshotRows(TENANT_A)).toHaveLength(1);
  });

  it("reports failed durable completion after SQL commits, then repairs the same capture", async () => {
    let failWrites = false;
    const wrap = (storage: LedgerStorage): LedgerStorage => ({ ...storage,
      transaction: (run) => storage.transaction((tx) => run(wrap(tx))),
      put: async (key, value) => { if (failWrites && key.startsWith("idem:")) throw new Error("completion receipt unavailable"); await storage.put(key, value); },
    });
    const limited = await makeHarness({ limits: memoryLimitsLayer(() => wrap(memoryLedgerStorage())) });
    try {
      const { vmId } = limited.addVm(TENANT_A);
      const token = await limited.addKey(TENANT_A, ["snapshot:write"]);
      const original = limited.upstream.fetch;
      limited.upstream.fetch = async (request) => {
        const response = await original(request);
        if (request.method === "POST" && new URL(request.url).pathname.endsWith("/snapshot")) failWrites = true;
        return response;
      };
      const headers = { ...bearer(token), "idempotency-key": "completion-failure" };
      const capture = () => limited.request(`/v1/vms/${vmId}/snapshots`, headers, { method: "POST", body: {} });
      const first = await capture();
      expect(first.status).toBe(503);
      expect(limited.s3a.snapshotRows(TENANT_A)).toHaveLength(1);
      failWrites = false;
      const retry = await capture();
      expect(retry.status).toBe(201);
      expect(limited.s3a.snapshotRows(TENANT_A)).toHaveLength(1);
      expect(limited.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
    } finally { failWrites = false; await limited.dispose(); }
  });

  it("replays the committed snapshot after the source VM has been deleted", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["snapshot:write", "vm:write"]);
    const headers = { ...bearer(key), "idempotency-key": "deleted-capture-source" };
    const first = await create(vmId, headers);
    expect(first.status).toBe(201);
    expect((await h.request(`/v1/vms/${vmId}`, bearer(key), { method: "DELETE" })).status).toBe(204);
    const retry = await create(vmId, headers);
    expect(retry.status).toBe(201);
    expect(await retry.json()).toEqual(await first.json());
    expect(h.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
  });

  it("keeps an uncertain capture's snapshot quota reserved", async () => {
    const limited = await makeHarness({ maxSnapshots: 1 });
    try {
      const { vmId } = limited.addVm(TENANT_A);
      const key = await limited.addKey(TENANT_A, ["snapshot:write"]);
      limited.upstream.faults.lostSnapshotResponses = 1;
      const capture = (idempotency: string) => limited.request(`/v1/vms/${vmId}/snapshots`,
        { ...bearer(key), "idempotency-key": idempotency }, { method: "POST", body: {} });
      expect((await capture("uncertain")).status).toBe(503);
      expect((await capture("different")).status).toBe(429);
      expect(limited.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
    } finally { await limited.dispose(); }
  });
});

describe("capture controls", () => {
  const pending = async (idempotency?: string) => {
    const { vmId } = h.addVm(TENANT_A);
    const token = await h.addKey(TENANT_A, ["snapshot:write", "snapshot:read", "vm:write"]);
    h.upstream.faults.lostSnapshotResponses = 1;
    const headers = { ...bearer(token), ...(idempotency === undefined ? {} : { "idempotency-key": idempotency }) };
    const response = await create(vmId, headers);
    expect(response.status).toBe(503);
    const { pendingSnapshotId } = await response.json<{ pendingSnapshotId: string }>();
    expect(pendingSnapshotId).toMatch(SNAPSHOT_ID);
    return { vmId, token, headers, id: pendingSnapshotId };
  };
  it("reads a legacy completed key from canonical ownership and keeps uncertain legacy keys fenced", async () => {
    const storage = memoryLedgerStorage(), ledger = new TenantLedger(storage);
    const local = await makeHarness({ limits: memoryLimitsLayer(() => storage) });
    const digest = async (key: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(["key", key])))), (b) => b.toString(16).padStart(2, "0")).join("");
    try {
      const { snapshotId } = local.s3a.addSnapshot(TENANT_A);
      const token = await local.addKey(TENANT_A, ["snapshot:read", "snapshot:write"]);
      const key = await digest("legacy-completed");
      await ledger.begin(key, "legacy-request", 0);
      await ledger.advance(key, { phase: "snapshotDone", snapshotId }, 1);
      const headers = { ...bearer(token), "idempotency-key": "legacy-completed" };
      expect(await (await local.request("/v1/snapshot-creations/by-key", headers)).json()).toMatchObject({ state: "committed", id: snapshotId, retryCreate: false });
      expect(local.upstream.calls).toHaveLength(0);
      expect((await local.request(`/v1/snapshots/${snapshotId}`, bearer(token), { method: "DELETE" })).status).toBe(204);
      expect(await (await local.request("/v1/snapshot-creations/by-key", headers)).json()).toMatchObject({ state: "deleted", id: snapshotId });
      await ledger.begin(await digest("legacy-uncertain"), "unknown", 0);
      expect((await local.request("/v1/snapshot-creations/by-key", { ...bearer(token), "idempotency-key": "legacy-uncertain" })).status).toBe(409);
      expect(local.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(0);
    } finally { await local.dispose(); }
  });

  it("distinguishes resumable admission from an uncertain provider send", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const token = await h.addKey(TENANT_A, ["snapshot:read", "snapshot:write"]);
    const headers = { ...bearer(token), "idempotency-key": "admission-retry" };
    h.setBilling(TENANT_A, false);
    expect((await create(vmId, headers)).status).toBe(402);
    expect(await (await h.request("/v1/snapshot-creations/by-key", headers)).json()).toMatchObject({ state: "pending", retryCreate: true });
    h.setBilling(TENANT_A, true);
    h.upstream.faults.lostSnapshotResponses = 1;
    expect((await create(vmId, headers)).status).toBe(503);
    expect(await (await h.request("/v1/snapshot-creations/by-key", headers)).json()).toMatchObject({ state: "pending", retryCreate: false });
    const other = await h.addKey(TENANT_B, ["snapshot:read"]);
    expect((await h.request("/v1/snapshot-creations/by-key", { ...bearer(other), "idempotency-key": "admission-retry" })).status).toBe(404);
    expect(h.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
  });

  it("cancels a key before capture admission so a late create cannot allocate", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const token = await h.addKey(TENANT_A, ["snapshot:write"]);
    const headers = { ...bearer(token), "idempotency-key": "cancel-before-admission" };
    const cancelled = await h.request("/v1/snapshot-creations/by-key/cancel", headers, { method: "POST", body: { expectedSnapshotId: null } });
    expect(cancelled.status).toBe(200);
    expect(await cancelled.json()).toMatchObject({ state: "fenced", id: null });
    expect((await create(vmId, headers)).status).toBe(409);
    expect(h.upstream.calls).toHaveLength(0);
  });

  it("cancels an uncertain keyed capture and deletes a committed capture by that exact key", async () => {
    const { id, headers, vmId } = await pending("delete-exact-capture");
    const result = await h.request("/v1/snapshot-creations/by-key/cancel", headers, { method: "POST", body: { expectedSnapshotId: id } });
    expect(result.status).toBe(200);
    expect(await result.json()).toMatchObject({ state: "cancelled", id });
    expect(h.upstream.snapshots.size).toBe(0);
    expect((await create(vmId, headers)).status).toBe(409);
    const committedHeaders = { ...headers, "idempotency-key": "committed-capture" };
    const committed = await (await create(vmId, committedHeaders)).json<{ id: string }>();
    const deleted = await h.request("/v1/snapshot-creations/by-key/cancel", committedHeaders, { method: "POST", body: { expectedSnapshotId: committed.id } });
    expect(deleted.status).toBe(200);
    expect(await deleted.json()).toMatchObject({ state: "cancelled", id: committed.id });
    expect(h.upstream.snapshots.size).toBe(0);
  });

  it("refuses stale or resource-limited key cancellation without deleting a capture", async () => {
    const { id, headers, vmId } = await pending("compared-key");
    for (const expectedSnapshotId of [null, `snap_${"2".repeat(26)}`]) {
      expect((await h.request("/v1/snapshot-creations/by-key/cancel", headers, { method: "POST", body: { expectedSnapshotId } })).status).toBe(409);
    }
    const restricted = await h.addKey(TENANT_A, ["snapshot:write"], { allowlist: [vmId] });
    expect((await h.request("/v1/snapshot-creations/by-key/cancel", { ...bearer(restricted), "idempotency-key": "compared-key" }, { method: "POST", body: { expectedSnapshotId: id } })).status).toBe(403);
    expect(h.upstream.snapshots.size).toBe(1);
    expect(h.upstream.callsTo("DELETE", /\/snapshots\//)).toHaveLength(0);
  });

  it("repairs a lost deletion acknowledgement using canonical ownership", async () => {
    const { id, headers } = await pending("lost-delete-ack");
    const original = h.upstream.fetch;
    let lost = false;
    h.upstream.fetch = async (r) => {
      const response = await original(r);
      if (!lost && r.method === "DELETE" && new URL(r.url).pathname.startsWith("/v5/snapshots/")) { lost = true; throw new TypeError("lost delete reply"); }
      return response;
    };
    const cancel = () => h.request("/v1/snapshot-creations/by-key/cancel", headers, { method: "POST", body: { expectedSnapshotId: id } });
    expect((await cancel()).status).toBe(503);
    expect(h.upstream.snapshots.size).toBe(0);
    expect(await (await cancel()).json()).toMatchObject({ state: "cancelled", id });
    expect(h.s3a.snapshotRows(TENANT_A)).toHaveLength(0);
  });

  it("reserves absent-key fences only for entitled teams and replays existing fences after plan loss", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const token = await h.addKey(TENANT_A, ["snapshot:write"]);
    const headers = { ...bearer(token), "idempotency-key": "fence-entitlement" };
    const cancel = () => h.request("/v1/snapshot-creations/by-key/cancel", headers, { method: "POST", body: { expectedSnapshotId: null } });
    h.setBilling(TENANT_A, false);
    expect((await cancel()).status).toBe(402);
    h.setBilling(TENANT_A, true);
    expect(await (await cancel()).json()).toMatchObject({ state: "fenced", id: null });
    h.setBilling(TENANT_A, false);
    expect(await (await cancel()).json()).toMatchObject({ state: "fenced", id: null });
    expect((await create(vmId, headers)).status).toBe(409);
    expect(h.upstream.calls).toHaveLength(0);
  });

  it("keeps a service's fence private to its current actor and labels", async () => {
    const options = { scopes: ["snapshot:write" as const], labels: { role: "cloud" } };
    const one = await h.addServiceKey({ ...options, id: "cloud-one" });
    const two = await h.addServiceKey({ ...options, id: "cloud-two" });
    const cancel = (token: string) => h.request("/v1/snapshot-creations/by-key/cancel", { ...bearer(token), "x-cmux-team-id": TENANT_A, "idempotency-key": "service-fence" }, { method: "POST", body: { expectedSnapshotId: null } });
    expect((await cancel(one)).status).toBe(200);
    expect((await cancel(two)).status).toBe(404);
    const rotated = await h.addServiceKey({ ...options, id: "cloud-one" });
    expect(await (await cancel(rotated)).json()).toMatchObject({ state: "fenced", id: null });
    expect(h.upstream.calls).toHaveLength(0);
  });

  it("looks up a keyed capture without source access or a provider request", async () => {
    const { vmId, id, headers } = await pending("cloud-snapshot:base");
    expect((await h.request(`/v1/vms/${vmId}`, headers, { method: "DELETE" })).status).toBe(204);
    const count = h.upstream.calls.length;
    const result = await h.request("/v1/snapshot-creations/by-key", headers);
    expect(result.status).toBe(200);
    expect(await result.json()).toMatchObject({ state: "pending", id, receipt: { sourceVmId: vmId } });
    expect(h.upstream.calls).toHaveLength(count);
  });

  it("recovers an unkeyed capture from read-only history after its source is deleted", async () => {
    const { vmId, token, id } = await pending();
    const calls = h.upstream.calls.length;
    const history = await h.request("/v1/snapshot-creations?limit=1", bearer(token));
    expect(await history.json()).toMatchObject({ items: [{ id, state: "pending" }], nextCursor: null });
    expect(h.upstream.calls).toHaveLength(calls);
    expect((await h.request(`/v1/vms/${vmId}`, bearer(token), { method: "DELETE" })).status).toBe(204);
    const repaired = await h.request(`/v1/snapshot-creations/${id}/reconcile`, bearer(token), { method: "POST" });
    expect(repaired.status).toBe(200);
    expect(await repaired.json()).toMatchObject({ id, state: "committed" });
    expect(h.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
  });
  it("does not send again when an unknown capture is absent", async () => {
    const { vmId, headers, id } = await pending("absent-capture");
    h.upstream.snapshots.clear();
    expect((await create(vmId, headers)).status).toBe(503);
    const response = await h.request(`/v1/snapshot-creations/${id}/reconcile`, headers, { method: "POST" });
    expect(await response.json()).toMatchObject({ state: "pending", id });
    expect(h.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
  });
  it("cancels a verified uncertain capture and permanently fences its key", async () => {
    const { vmId, headers, id } = await pending("cancel-capture");
    const cancelled = await h.request(`/v1/snapshot-creations/${id}/cancel`, headers, { method: "POST" });
    expect(cancelled.status).toBe(200);
    expect(await cancelled.json()).toMatchObject({ state: "deleted", cancellation: "completed", id });
    expect(h.upstream.snapshots.size).toBe(0);
    expect((await create(vmId, headers)).status).toBe(409);
    expect(h.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
  });
  it("fences a late successful capture response after cancellation has deleted it", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const token = await h.addKey(TENANT_A, ["snapshot:read", "snapshot:write"]);
    const headers = { ...bearer(token), "idempotency-key": "late-capture" };
    let ready: () => void = () => undefined, release: () => void = () => undefined;
    const reached = new Promise<void>((resolve) => { ready = resolve; });
    const resume = new Promise<void>((resolve) => { release = resolve; });
    const original = h.upstream.fetch;
    h.upstream.fetch = async (request) => {
      const response = await original(request);
      if (request.method === "POST" && new URL(request.url).pathname.endsWith("/snapshot")) { ready(); await resume; }
      return response;
    };
    const running = create(vmId, headers);
    try {
      await reached;
      const page = await (await h.request("/v1/snapshot-creations", bearer(token))).json<{ items: Array<{ id: string }> }>();
      const id = page.items[0]?.id;
      expect(id).toMatch(SNAPSHOT_ID);
      const cancelled = await h.request(`/v1/snapshot-creations/${id}/cancel`, bearer(token), { method: "POST" });
      expect(await cancelled.json()).toMatchObject({ cancellation: "completed", state: "deleted" });
      release();
      expect((await running).status).toBe(503);
      expect(h.upstream.snapshots.size).toBe(0);
      expect((await create(vmId, headers)).status).toBe(409);
      expect(h.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
    } finally { release(); await running; }
  });

  it("keeps cancellation pending when the unknown capture is absent", async () => {
    const { vmId, headers, id } = await pending("cancel-absent");
    h.upstream.snapshots.clear();
    const cancelled = await h.request(`/v1/snapshot-creations/${id}/cancel`, headers, { method: "POST" });
    expect(await cancelled.json()).toMatchObject({ state: "pending", cancellation: "requested", id });
    expect((await create(vmId, headers)).status).toBe(409);
    expect(h.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
  });
  it.each(["slug", "displayName", "sourceVmId"])("refuses recovery when the provider %s no longer matches", async (field) => {
    const { vmId, headers, id } = await pending(`wrong-${field}`);
    const snapshot = [...h.upstream.snapshots.values()][0];
    if (snapshot === undefined) throw new Error("capture missing");
    Object.assign(snapshot, { [field]: "different" });
    const repaired = await h.request(`/v1/snapshot-creations/${id}/reconcile`, headers, { method: "POST" });
    expect(repaired.status).toBe(field === "slug" ? 200 : 503);
    if (field === "slug") expect(await repaired.json()).toMatchObject({ state: "pending" });
    expect(h.s3a.snapshotRows(TENANT_A)).toHaveLength(0);
    expect((await create(vmId, headers)).status).toBe(503);
    expect(h.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
  });
  it("conceals capture controls from another tenant and rejects missing scopes", async () => {
    const { id } = await pending();
    const other = await h.addKey(TENANT_B, ["snapshot:read", "snapshot:write"]);
    const noWrite = await h.addKey(TENANT_A, ["snapshot:read"]);
    const before = h.upstream.calls.length;
    for (const suffix of ["", "/reconcile", "/cancel"]) {
      const opts = suffix === "" ? undefined : { method: "POST" };
      expect((await h.request(`/v1/snapshot-creations/${id}${suffix}`, bearer(other), opts)).status).toBe(404);
    }
    expect((await h.request(`/v1/snapshot-creations/${id}/reconcile`, bearer(noWrite), { method: "POST" })).status).toBe(403);
    expect(h.upstream.calls).toHaveLength(before);
  });
  it("refuses provider credential changes before lookup and resumes under the original context", async () => {
    const { id, headers } = await pending();
    const calls = h.upstream.calls.length;
    h.s3a.changeSnapshotCredential("different-provider-account");
    expect((await h.request(`/v1/snapshot-creations/${id}/reconcile`, headers, { method: "POST" })).status).toBe(503);
    expect(h.upstream.calls).toHaveLength(calls);
    h.s3a.changeSnapshotCredential("upstream-test-key");
    expect((await h.request(`/v1/snapshot-creations/${id}/reconcile`, headers, { method: "POST" })).status).toBe(200);
    expect(h.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
  });
  it("cleans an identity-verified public capture during cancellation instead of adopting it", async () => {
    const { id, headers } = await pending();
    const captured = [...h.upstream.snapshots.values()][0];
    if (captured === undefined) throw new Error("missing capture");
    Object.assign(captured, { public: true });
    expect((await h.request(`/v1/snapshot-creations/${id}/reconcile`, headers, { method: "POST" })).status).toBe(503);
    const cancelled = await h.request(`/v1/snapshot-creations/${id}/cancel`, headers, { method: "POST" });
    expect(await cancelled.json()).toMatchObject({ cancellation: "completed", state: "deleted" });
    expect(h.upstream.snapshots.size).toBe(0);
  });
  it("preserves Cloud service labels and actor ownership across key rotation and recovery", async () => {
    const labels = { role: "cloud", cmux_next_team: TENANT_A };
    const { vmId } = h.addVm(TENANT_A, "running", labels);
    const options = { id: "cloud-api", labels };
    const token = await h.addServiceKey({ ...options, scopes: ["snapshot:read", "snapshot:write"] });
    const headers = { ...bearer(token), "x-cmux-team-id": TENANT_A, "idempotency-key": "cloud-snapshot:base" };
    expect((await create(vmId, headers, {})).status).toBe(403);
    h.upstream.faults.lostSnapshotResponses = 1;
    const first = await create(vmId, headers, { displayName: "base", labels });
    const { pendingSnapshotId: id } = await first.json<{ pendingSnapshotId: string }>();
    expect(id).toMatch(SNAPSHOT_ID);
    const foreign = await h.addServiceKey({ id: "another-service", scopes: ["snapshot:read", "snapshot:write"], labels });
    const foreignHeaders = { ...bearer(foreign), "x-cmux-team-id": TENANT_A };
    expect((await h.request(`/v1/snapshot-creations/${id}`, foreignHeaders)).status).toBe(404);
    expect(await (await h.request("/v1/snapshot-creations", foreignHeaders)).json()).toMatchObject({ items: [] });
    const rotated = await h.addServiceKey({ id: "cloud-api", scopes: ["snapshot:read", "snapshot:write"], labels });
    const rotatedHeaders = { ...bearer(rotated), "x-cmux-team-id": TENANT_A, "idempotency-key": "cloud-snapshot:base" };
    expect((await create(vmId, rotatedHeaders, { displayName: "base", labels })).status).toBe(201);
    expect(h.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
    const row = h.resources.find((r) => r.cmuxId === id);
    if (row === undefined) throw new Error("missing row");
    Object.assign(row, { labels: { role: "other" } });
    expect((await h.request(`/v1/snapshot-creations/${id}`, rotatedHeaders)).status).toBe(404);
  });

  it("keeps source-allowlisted capture access specific to the original actor", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const original = await h.addKey(TENANT_A, ["snapshot:read", "snapshot:write"], { allowlist: [vmId] });
    const other = await h.addKey(TENANT_A, ["snapshot:read", "snapshot:write"], { allowlist: [vmId] });
    h.upstream.faults.lostSnapshotResponses = 1;
    const result = await create(vmId, bearer(original));
    const { pendingSnapshotId: id } = await result.json<{ pendingSnapshotId: string }>();
    expect((await h.request(`/v1/snapshot-creations/${id}/reconcile`, bearer(other), { method: "POST" })).status).toBe(404);
    expect((await h.request("/v1/snapshot-creations", bearer(original))).status).toBe(403);
    expect((await h.request(`/v1/snapshot-creations/${id}/reconcile`, bearer(original), { method: "POST" })).status).toBe(200);
    expect((await h.request(`/v1/snapshots/${id}`, bearer(original))).status).toBe(404);
  });
});

describe("read, list and delete", () => {
  it("gets an owned snapshot with live retention fields", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const { snapshotId, upstreamId } = h.s3a.addSnapshot(TENANT_A, { sourceVmId: vmId, displayName: "base" });
    const key = await h.addKey(TENANT_A, ["snapshot:read"]);

    const response = await h.request(`/v1/snapshots/${snapshotId}`, bearer(key));

    expect(response.status).toBe(200);
    const text = await response.text();
    expect(JSON.parse(text)).toMatchObject({
      id: snapshotId,
      sourceVmId: vmId,
      displayName: "base",
      autoDeleteSeconds: 3600,
      ttlSeconds: null,
    });
    expect(text).not.toContain(upstreamId);
    expect(text).not.toContain("cmux internal");
    expect(upstreamPaths()).toEqual([`GET /v5/snapshots/${upstreamId}`]);
  });

  it("pages newest first with an opaque cursor and filters by source VM", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const ids = [1, 2, 3].map(
      (minute) => h.s3a.addSnapshot(TENANT_A, { sourceVmId: vmId, createdAt: new Date(Date.UTC(2026, 9, 1, 0, minute)) }).snapshotId,
    );
    h.s3a.addSnapshot(TENANT_A, { createdAt: new Date(Date.UTC(2026, 9, 1, 0, 9)) });
    const key = await h.addKey(TENANT_A, ["snapshot:read"]);

    const first = await (await h.request(`/v1/snapshots?limit=2&sourceVmId=${vmId}`, bearer(key))).json<{
      items: Array<{ id: string }>;
      nextCursor: string | null;
    }>();
    expect(first.items.map((item) => item.id)).toEqual([ids[2], ids[1]]);
    expect(first.nextCursor).not.toBeNull();

    const second = await (
      await h.request(`/v1/snapshots?limit=2&sourceVmId=${vmId}&cursor=${first.nextCursor}`, bearer(key))
    ).json<{ items: Array<{ id: string }>; nextCursor: string | null }>();
    expect(second.items.map((item) => item.id)).toEqual([ids[0]]);
    expect(second.nextCursor).toBeNull();

    expect((await h.request("/v1/snapshots?cursor=garbage", bearer(key))).status).toBe(400);
  });

  it("filters by labels from the ownership table only", async () => {
    const warm = h.s3a.addSnapshot(TENANT_A, { labels: { pool: "linux-x64", tier: "warm" } });
    h.s3a.addSnapshot(TENANT_A, { labels: { pool: "linux-arm64", tier: "warm" } });
    h.s3a.addSnapshot(TENANT_B, { labels: { pool: "linux-x64", tier: "warm" } });
    const key = await h.addKey(TENANT_A, ["snapshot:read"]);

    const response = await h.request("/v1/snapshots?labels=pool%3Dlinux-x64%2Ctier%3Dwarm", bearer(key));

    expect(response.status).toBe(200);
    const body = await response.json<{ items: Array<{ id: string; labels: Record<string, string> }> }>();
    expect(body.items.map((item) => item.id)).toEqual([warm.snapshotId]);
    expect(body.items[0]?.labels).toEqual({ pool: "linux-x64", tier: "warm" });
    expect(h.upstreamRequests).toHaveLength(0);
    expect((await h.request("/v1/snapshots?labels=no-equals-sign", bearer(key))).status).toBe(400);
  });

  it("deletes an owned snapshot upstream and in the table, then 404s", async () => {
    const { snapshotId, upstreamId } = h.s3a.addSnapshot(TENANT_A);
    const key = await h.addKey(TENANT_A, ["snapshot:write", "snapshot:read"]);

    const response = await h.request(`/v1/snapshots/${snapshotId}`, bearer(key), { method: "DELETE" });

    expect(response.status).toBe(204);
    expect(h.upstream.snapshots.has(upstreamId)).toBe(false);
    expect(h.s3a.snapshotRows(TENANT_A)).toHaveLength(0);
    expect(h.audit).toMatchObject([{ action: "snapshot.delete", cmuxId: snapshotId, outcome: "ok" }]);
    expect((await h.request(`/v1/snapshots/${snapshotId}`, bearer(key))).status).toBe(404);
  });

  it("finishes a delete whose upstream snapshot is already gone", async () => {
    const { snapshotId, upstreamId } = h.s3a.addSnapshot(TENANT_A);
    h.upstream.snapshots.delete(upstreamId);
    const key = await h.addKey(TENANT_A, ["snapshot:write"]);

    expect((await h.request(`/v1/snapshots/${snapshotId}`, bearer(key), { method: "DELETE" })).status).toBe(204);
    expect(h.s3a.snapshotRows(TENANT_A)).toHaveLength(0);
  });

  it("keeps read and write scopes apart, and snapshot:* grants both", async () => {
    const { snapshotId } = h.s3a.addSnapshot(TENANT_A);
    const reader = await h.addKey(TENANT_A, ["snapshot:read"]);
    const writer = await h.addKey(TENANT_A, ["snapshot:write"]);
    const family = await h.addKey(TENANT_A, ["snapshot:*"]);

    expect((await h.request(`/v1/snapshots/${snapshotId}`, bearer(reader), { method: "DELETE" })).status).toBe(403);
    expect((await h.request(`/v1/snapshots/${snapshotId}`, bearer(writer))).status).toBe(403);
    expect((await h.request("/v1/snapshots", bearer(writer))).status).toBe(403);
    expect((await h.request(`/v1/snapshots/${snapshotId}`, bearer(family))).status).toBe(200);
    expect((await h.request(`/v1/snapshots/${snapshotId}`, bearer(family), { method: "DELETE" })).status).toBe(204);
  });
});

describe.each(SNAPSHOT_ENDPOINTS)("$name isolation", (endpoint) => {
  it("answers 404 to another tenant's key, even with every scope, and calls nothing upstream", async () => {
    const { snapshotId, upstreamId } = h.s3a.addSnapshot(TENANT_A);
    const keyB = await h.addKey(TENANT_B, ALL_SCOPES);

    const response = await h.request(endpoint.template.replace("{snapshotId}", snapshotId), bearer(keyB), { method: endpoint.method, body: "json" in endpoint ? endpoint.json : undefined });

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ _tag: "NotFound", message: "Snapshot not found" });
    expect(h.upstreamRequests).toHaveLength(0);
    expect(h.upstream.snapshots.has(upstreamId)).toBe(true);
  });

  it("answers 404 to a signed-in member of another team", async () => {
    const { snapshotId } = h.s3a.addSnapshot(TENANT_A);
    h.addMember(TENANT_B, "user_bob");
    const token = await h.sessionToken("user_bob");

    const response = await h.request(endpoint.template.replace("{snapshotId}", snapshotId), { ...bearer(token), "x-cmux-team-id": TENANT_B }, { method: endpoint.method, body: "json" in endpoint ? endpoint.json : undefined });

    expect(response.status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it(`refuses a key without ${endpoint.scope} with 403 before looking at the snapshot`, async () => {
    const { snapshotId } = h.s3a.addSnapshot(TENANT_A);
    const key = await h.addKey(TENANT_A, allScopesExcept(endpoint.scope));

    const own = await h.request(endpoint.template.replace("{snapshotId}", snapshotId), bearer(key), { method: endpoint.method, body: "json" in endpoint ? endpoint.json : undefined });
    const missing = await h.request(endpoint.template.replace("{snapshotId}", "snap_00000000000000000000000000"), bearer(key), { method: endpoint.method, body: "json" in endpoint ? endpoint.json : undefined });

    expect(own.status).toBe(403);
    expect(await own.json()).toMatchObject({ missingScope: endpoint.scope });
    expect(missing.status).toBe(403);
    expect(h.upstreamRequests).toHaveLength(0);
  });
});
