/**
 * Snapshot endpoints end to end in workerd: real API, middleware, proofs and
 * upstream client, with in-memory stores and a fake provider.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ALL_SCOPES, allScopesExcept, SNAPSHOT_ENDPOINTS } from "../support/endpoints.ts";
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

    expect(upstreamPaths()).toEqual([`POST /v5/vms/${upstreamVmId}/snapshot`]);
    expect(h.upstream.callsTo("POST", /\/snapshot$/).at(0)?.json).toEqual({
      displayName: `cmux-vm-local ${TENANT_A} ${String(body["id"])}`,
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

  it("deletes the upstream snapshot again when its ownership row cannot be written", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["snapshot:write"]);
    h.s3a.failNextSnapshotRecord();

    const response = await create(vmId, bearer(key));

    expect(response.status).toBe(503);
    expect(h.upstream.snapshots.size).toBe(0);
    expect(upstreamPaths().map((path) => path.split(" ")[0])).toEqual(["POST", "DELETE"]);
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

    const response = await h.request(`/v1/snapshots/${snapshotId}`, bearer(keyB), { method: endpoint.method });

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ _tag: "NotFound", message: "Snapshot not found" });
    expect(h.upstreamRequests).toHaveLength(0);
    expect(h.upstream.snapshots.has(upstreamId)).toBe(true);
  });

  it("answers 404 to a signed-in member of another team", async () => {
    const { snapshotId } = h.s3a.addSnapshot(TENANT_A);
    h.addMember(TENANT_B, "user_bob");
    const token = await h.sessionToken("user_bob");

    const response = await h.request(`/v1/snapshots/${snapshotId}`, { ...bearer(token), "x-cmux-team-id": TENANT_B }, { method: endpoint.method });

    expect(response.status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it(`refuses a key without ${endpoint.scope} with 403 before looking at the snapshot`, async () => {
    const { snapshotId } = h.s3a.addSnapshot(TENANT_A);
    const key = await h.addKey(TENANT_A, allScopesExcept(endpoint.scope));

    const own = await h.request(`/v1/snapshots/${snapshotId}`, bearer(key), { method: endpoint.method });
    const missing = await h.request("/v1/snapshots/snap_00000000000000000000000000", bearer(key), { method: endpoint.method });

    expect(own.status).toBe(403);
    expect(await own.json()).toMatchObject({ missingScope: endpoint.scope });
    expect(missing.status).toBe(403);
    expect(h.upstreamRequests).toHaveLength(0);
  });
});
