/**
 * Classic -> NEXT migration: a service key with import:classic copies a classic VM into a NEXT tenant as a
 * snapshot. The import is idempotent per (tenant, classic VM, migration) and never snapshots twice, a provider VM
 * the account does not hold is 404 import.upstream_vm_not_found, and the rollback deletes only imports.
 * Sessions and API keys never hold the scope.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TENANT_A = "team_alpha";
const TENANT_B = "team_bravo";
const PLATFORM = { "cmux.service": "cloud-platform" };
const PATH = "/v1/imports/classic-vm-snapshots";

interface ImportBody {
  readonly id: string;
  readonly upstream_snapshot_id: string;
  readonly state: string;
  readonly tenant_id: string;
  readonly classic_vm_id: string;
  readonly migration_id: string;
  readonly created_by: string;
}

let h: Harness;
beforeEach(async () => {
  h = await makeHarness();
});
afterEach(async () => {
  await h.dispose();
});

const asTeam = (secret: string, team: string, extra: Record<string, string> = {}) => ({ ...bearer(secret), "x-cmux-team-id": team, ...extra });
const importer = (options: { readonly teams?: ReadonlyArray<string> } = {}) =>
  h.addServiceKey({ id: "classic-import", scopes: ["import:classic"], labels: PLATFORM, ...options });
const body = (upstreamVmId: string, overrides: Record<string, string> = {}) => ({
  tenant_id: TENANT_A,
  created_by: "stack-user-1",
  classic_vm_id: "cvm-1",
  upstream_vm_id: upstreamVmId,
  migration_id: "mig-1",
  ...overrides,
});
const snapshotSends = () => h.upstreamRequests.filter((call) => call.method === "POST" && call.path.endsWith("/snapshot"));

describe("import", () => {
  it("snapshots the provider VM, registers it under the tenant with the classic labels, and audits it", async () => {
    const key = await importer();
    const vm = h.upstream.addVm("running");
    const response = await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id) });
    expect(response.status).toBe(200);
    const result = await response.json<ImportBody>();
    expect(result).toMatchObject({ state: "created", tenant_id: TENANT_A, classic_vm_id: "cvm-1", migration_id: "mig-1", created_by: "user:stack-user-1" });
    expect(result.id).toMatch(/^snap_/);
    expect(h.upstream.snapshots.get(result.upstream_snapshot_id)?.sourceVmId).toBe(vm.id);
    expect(snapshotSends()).toHaveLength(1);
    const row = h.resources.find((resource) => resource.cmuxId === result.id);
    expect(row).toMatchObject({
      tenantId: TENANT_A,
      kind: "snapshot",
      upstreamId: result.upstream_snapshot_id,
      createdBy: "user:stack-user-1",
      labels: { ...PLATFORM, "classic.vm_id": "cvm-1", "classic.migration_id": "mig-1" },
    });
    expect(h.audit).toContainEqual(
      expect.objectContaining({ tenantId: TENANT_A, actor: "service:classic-import", action: "snapshot.import_classic", cmuxId: result.id, outcome: "ok" }),
    );
  });

  it("is idempotent: the same tenant, classic VM and migration answer the first import and never snapshot again", async () => {
    const key = await importer();
    const vm = h.upstream.addVm("running");
    const first = await (await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id) })).json<ImportBody>();
    const again = await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id) });
    expect(again.status).toBe(200);
    expect(await again.json<ImportBody>()).toMatchObject({ id: first.id, upstream_snapshot_id: first.upstream_snapshot_id, state: "ready" });
    expect(snapshotSends()).toHaveLength(1);

    // Another migration run of the same classic VM is a separate copy.
    const other = await (await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id, { migration_id: "mig-2" }) })).json<ImportBody>();
    expect(other.id).not.toBe(first.id);
    expect(snapshotSends()).toHaveLength(2);
  });

  it("adopts the provider snapshot of a send whose reply was lost instead of snapshotting again", async () => {
    const key = await importer();
    const vm = h.upstream.addVm("running");
    h.upstream.faults.lostSnapshotResponses = 1;
    const lost = await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id) });
    expect(lost.status).toBe(503);
    expect(h.resources.filter((row) => row.kind === "snapshot")).toHaveLength(0);
    const retry = await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id) });
    expect(retry.status).toBe(200);
    const result = await retry.json<ImportBody>();
    expect(result.state).toBe("created");
    expect(snapshotSends()).toHaveLength(1);
    expect(h.upstream.snapshots.size).toBe(1);
    expect(h.upstream.snapshots.has(result.upstream_snapshot_id)).toBe(true);
  });

  it("keeps the provider snapshot when the row write committed but its reply was lost, and answers that row", async () => {
    const key = await importer();
    const vm = h.upstream.addVm("running");
    h.s3a.loseNextSnapshotRecordReply();
    const response = await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id) });
    expect(response.status).toBe(200);
    const result = await response.json<ImportBody>();
    expect(result.state).toBe("created");
    expect(h.upstream.snapshots.has(result.upstream_snapshot_id)).toBe(true);
    expect(h.resources.find((row) => row.cmuxId === result.id)?.upstreamId).toBe(result.upstream_snapshot_id);
    const again = await (await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id) })).json<ImportBody>();
    expect(again).toMatchObject({ id: result.id, state: "ready" });
    expect(h.upstream.snapshots.has(again.upstream_snapshot_id)).toBe(true);
    expect(snapshotSends()).toHaveLength(1);
  });

  it("keeps the provider snapshot when the row write fails, and a retry records it without snapshotting again", async () => {
    const key = await importer();
    const vm = h.upstream.addVm("running");
    h.s3a.failNextSnapshotRecord();
    expect((await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id) })).status).toBe(503);
    expect(h.upstream.snapshots.size).toBe(1);
    expect(h.upstream.callsTo("DELETE", /^\/v5\/snapshots\//)).toHaveLength(0);
    const retry = await (await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id) })).json<ImportBody>();
    expect(retry.state).toBe("created");
    expect(h.upstream.snapshots.has(retry.upstream_snapshot_id)).toBe(true);
    expect(snapshotSends()).toHaveLength(1);
  });

  it("refuses a concurrent second use of an Idempotency-Key, then its mismatch, so one key never binds two imports", async () => {
    const key = await importer();
    const vm = h.upstream.addVm("running");
    const other = h.upstream.addVm("running");
    const keyed = asTeam(key, TENANT_A, { "idempotency-key": "shared-key" });
    const [a, b] = await Promise.all([
      h.request(PATH, keyed, { method: "POST", body: body(vm.id) }),
      h.request(PATH, keyed, { method: "POST", body: body(other.id, { classic_vm_id: "cvm-2" }) }),
    ]);
    expect([a.status, b.status].sort()).toEqual([200, 409]);
    const loser = a.status === 409 ? body(vm.id) : body(other.id, { classic_vm_id: "cvm-2" });
    expect((await h.request(PATH, keyed, { method: "POST", body: loser })).status).toBe(409);
    expect(snapshotSends()).toHaveLength(1);
    expect(h.resources.filter((row) => row.labels["classic.import_key"] !== undefined)).toHaveLength(1);
  });

  it("replays an Idempotency-Key and refuses it for a different request", async () => {
    const key = await importer();
    const vm = h.upstream.addVm("running");
    const keyed = asTeam(key, TENANT_A, { "idempotency-key": "import-1" });
    const first = await (await h.request(PATH, keyed, { method: "POST", body: body(vm.id) })).json<ImportBody>();
    const replay = await h.request(PATH, keyed, { method: "POST", body: body(vm.id) });
    expect(await replay.json<ImportBody>()).toMatchObject({ id: first.id, state: "ready" });
    const reused = await h.request(PATH, keyed, { method: "POST", body: body(vm.id, { classic_vm_id: "cvm-2" }) });
    expect(reused.status).toBe(409);
    expect(snapshotSends()).toHaveLength(1);
    const row = h.resources.find((resource) => resource.cmuxId === first.id);
    expect(row?.labels["classic.import_key"]).toMatch(/^[0-9a-f]{40}$/);
    expect(JSON.stringify(row?.labels)).not.toContain("import-1");
  });

  it("answers 404 import.upstream_vm_not_found for a VM the provider account does not hold, and records nothing", async () => {
    const key = await importer();
    const response = await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body("vm-in-another-account") });
    expect(response.status).toBe(404);
    const error = await response.json<{ readonly code: string; readonly message: string }>();
    expect(error.code).toBe("import.upstream_vm_not_found");
    expect(error.message).toContain("different provider account");
    expect(h.resources).toHaveLength(0);
  });

  it("refuses a tenant_id other than the team the request names", async () => {
    const key = await importer();
    const vm = h.upstream.addVm("running");
    const response = await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id, { tenant_id: TENANT_B }) });
    expect(response.status).toBe(400);
    expect(snapshotSends()).toHaveLength(0);
  });
});

describe("booting an import", () => {
  // cmux-platform's Cloud driver key (cloud-platform-<env>) is confined to role=cloud and creates VMs labelled role=cloud
  // (cmux-platform src/server/cloud/vmapi/CloudProvider.ts). Granted import:classic, it must boot what it imported.
  const CLOUD = { role: "cloud" };
  const platformKey = () =>
    h.addServiceKey({ id: "cloud-platform-dev", scopes: ["vm:read", "vm:write", "vm:exec", "snapshot:read", "snapshot:write", "import:classic"], labels: CLOUD });

  it("the importing platform key creates a VM from the imported snapshot", async () => {
    const key = await platformKey();
    const source = h.upstream.addVm("running");
    const imported = await (await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(source.id) })).json<ImportBody>();
    expect(h.resources.find((row) => row.cmuxId === imported.id)?.labels).toMatchObject(CLOUD);

    const listed = await h.request("/v1/snapshots", asTeam(key, TENANT_A));
    expect((await listed.json<{ readonly items: ReadonlyArray<{ readonly id: string }> }>()).items.map((item) => item.id)).toContain(imported.id);
    expect((await h.request(`/v1/snapshots/${imported.id}`, asTeam(key, TENANT_A))).status).toBe(200);

    const created = await h.request("/v1/vms", asTeam(key, TENANT_A), {
      method: "POST",
      body: { labels: { ...CLOUD, cmux_next_team: "team-1" }, snapshotId: imported.id },
    });
    expect(created.status).toBe(201);
    const boots = h.upstreamRequests.filter((call) => call.method === "POST" && call.path === "/v5/vms");
    expect(boots.at(-1)?.json).toMatchObject({ snapshotId: imported.upstream_snapshot_id });
  });

  it("the tenant's own session sees the import as its creator's snapshot", async () => {
    const key = await platformKey();
    const source = h.upstream.addVm("running");
    const imported = await (await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(source.id) })).json<ImportBody>();
    h.addMember(TENANT_A, "stack-user-1");
    const session = await h.sessionToken("stack-user-1");
    const mine = await h.request("/v1/snapshots?createdBy=caller", asTeam(session, TENANT_A));
    expect((await mine.json<{ readonly items: ReadonlyArray<{ readonly id: string }> }>()).items.map((item) => item.id)).toEqual([imported.id]);
  });
});

describe("authorization", () => {
  it("refuses a session, an API key and a service key without the scope", async () => {
    const vm = h.upstream.addVm("running");
    h.addMember(TENANT_A, "user-1");
    const session = await h.sessionToken("user-1");
    const apiKey = await h.addKey(TENANT_A, ["snapshot:write", "import:classic"]);
    const service = await h.addServiceKey({ id: "other-service", scopes: ["snapshot:write"], labels: PLATFORM });
    for (const headers of [asTeam(session, TENANT_A), bearer(apiKey), asTeam(service, TENANT_A)]) {
      const response = await h.request(PATH, headers, { method: "POST", body: body(vm.id) });
      expect(response.status).toBe(403);
      expect(await response.json<{ readonly missingScope: string }>()).toMatchObject({ missingScope: "import:classic" });
    }
    expect(snapshotSends()).toHaveLength(0);
  });

  it("keeps the service key's team restriction", async () => {
    const key = await importer({ teams: [TENANT_B] });
    const vm = h.upstream.addVm("running");
    expect((await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id) })).status).toBe(403);
    expect(snapshotSends()).toHaveLength(0);
  });

  it("never issues an API key with the scope", async () => {
    h.addMember(TENANT_A, "admin-1");
    h.addAdmin(TENANT_A, "admin-1");
    const session = await h.sessionToken("admin-1");
    const response = await h.request("/v1/api-keys", asTeam(session, TENANT_A), { method: "POST", body: { name: "migrator", scopes: ["import:classic"] } });
    expect(response.status).toBe(400);
    expect(h.storedKeys()).toHaveLength(0);
  });
});

describe("list", () => {
  it("lists the tenant's imports by classic VM and migration, rolled-back ones included", async () => {
    const key = await importer();
    const vm = h.upstream.addVm("running");
    const first = await (await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id) })).json<ImportBody>();
    const second = await (await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id, { migration_id: "mig-2" }) })).json<ImportBody>();
    h.s3a.addSnapshot(TENANT_A, { labels: PLATFORM });

    const all = await h.request(`${PATH}?tenant_id=${TENANT_A}`, asTeam(key, TENANT_A));
    expect(all.status).toBe(200);
    expect((await all.json<{ readonly items: ReadonlyArray<ImportBody> }>()).items.map((item) => item.id).sort()).toEqual([first.id, second.id].sort());

    const one = await (await h.request(`${PATH}?tenant_id=${TENANT_A}&classic_vm_id=cvm-1&migration_id=mig-2`, asTeam(key, TENANT_A))).json<{ readonly items: ReadonlyArray<ImportBody> }>();
    expect(one.items).toEqual([expect.objectContaining({ id: second.id, state: "ready", upstream_snapshot_id: second.upstream_snapshot_id })]);

    expect((await h.request(`${PATH}/${second.id}`, asTeam(key, TENANT_A), { method: "DELETE" })).status).toBe(204);
    const after = await (await h.request(`${PATH}?tenant_id=${TENANT_A}&migration_id=mig-2`, asTeam(key, TENANT_A))).json<{ readonly items: ReadonlyArray<ImportBody> }>();
    expect(after.items).toEqual([expect.objectContaining({ id: second.id, state: "deleted" })]);

    expect((await h.request(`${PATH}?tenant_id=${TENANT_B}`, asTeam(key, TENANT_A))).status).toBe(400);
  });
});

describe("rollback", () => {
  it("deletes the provider snapshot and the row; a second rollback succeeds; a new import copies again", async () => {
    const key = await importer();
    const vm = h.upstream.addVm("running");
    const first = await (await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id) })).json<ImportBody>();
    const removed = await h.request(`${PATH}/${first.id}`, asTeam(key, TENANT_A), { method: "DELETE" });
    expect(removed.status).toBe(204);
    expect(h.upstream.snapshots.has(first.upstream_snapshot_id)).toBe(false);
    expect(h.resources.some((row) => row.cmuxId === first.id)).toBe(false);
    expect((await h.request(`${PATH}/${first.id}`, asTeam(key, TENANT_A), { method: "DELETE" })).status).toBe(204);
    expect(h.audit).toContainEqual(expect.objectContaining({ action: "snapshot.rollback_classic_import", cmuxId: first.id, outcome: "ok" }));

    const again = await (await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id) })).json<ImportBody>();
    expect(again).toMatchObject({ state: "created" });
    expect(again.id).not.toBe(first.id);
  });

  it("never deletes a snapshot that an import did not make", async () => {
    const key = await importer();
    const own = h.s3a.addSnapshot(TENANT_A, { labels: PLATFORM });
    const response = await h.request(`${PATH}/${own.snapshotId}`, asTeam(key, TENANT_A), { method: "DELETE" });
    expect(response.status).toBe(409);
    expect(h.upstream.snapshots.has(own.upstreamId)).toBe(true);
    expect(h.resources.some((row) => row.cmuxId === own.snapshotId)).toBe(true);

    // Without the key's labels it is not even visible.
    const hidden = h.s3a.addSnapshot(TENANT_A, { labels: { "classic.migration_id": "mig-1" } });
    expect((await h.request(`${PATH}/${hidden.snapshotId}`, asTeam(key, TENANT_A), { method: "DELETE" })).status).toBe(404);
    expect(h.upstream.snapshots.has(hidden.upstreamId)).toBe(true);
  });

  it("is 404 for another tenant's import", async () => {
    const key = await importer();
    const vm = h.upstream.addVm("running");
    const first = await (await h.request(PATH, asTeam(key, TENANT_A), { method: "POST", body: body(vm.id) })).json<ImportBody>();
    expect((await h.request(`${PATH}/${first.id}`, asTeam(key, TENANT_B), { method: "DELETE" })).status).toBe(404);
    expect(h.upstream.snapshots.has(first.upstream_snapshot_id)).toBe(true);
  });
});
