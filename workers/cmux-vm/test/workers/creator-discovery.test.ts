import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
interface Page {
  readonly items: ReadonlyArray<{ readonly id: string }>;
  readonly nextCursor: string | null;
}
const TEAM = "team_alpha";
const LABELS = { role: "cloud" };
let h: Harness;
beforeEach(async () => {
  h = await makeHarness();
});
afterEach(async () => {
  await h.dispose();
});

const service = async () => {
  const key = await h.addServiceKey({ id: "cloud-driver", labels: LABELS, scopes: ["vm:read", "vm:write", "snapshot:read", "snapshot:write"] });
  return { ...bearer(key), "x-cmux-team-id": TEAM };
};
const create = async (headers: Record<string, string>, path: string) => {
  const response = await h.request(path, headers, { method: "POST", body: { labels: LABELS } });
  expect(response.status).toBe(201);
  return response.json<{ readonly id: string }>();
};
const list = async (headers: Record<string, string>, path: string) => {
  const response = await h.request(path, headers);
  expect(response.status).toBe(200);
  return response.json<Page>();
};

describe("creator-constrained discovery", () => {
  it("recovers only the service's VMs when another caller chooses identical labels", async () => {
    const headers = await service();
    const member = bearer(await h.addKey(TEAM, ["vm:read", "vm:write"]));
    const mine = await create(headers, "/v1/vms");
    const other = await create(member, "/v1/vms");
    const page = await list(headers, "/v1/vms?createdBy=caller");
    expect(page.items.map((vm) => vm.id)).toEqual([mine.id]);
    expect(page.nextCursor).toBeNull();
    expect((await list(member, "/v1/vms?createdBy=caller")).items.map((vm) => vm.id)).toEqual([other.id]);
  });

  it("preserves tenant-wide VM listing when no creator filter is requested", async () => {
    const headers = await service();
    const member = bearer(await h.addKey(TEAM, ["vm:read", "vm:write"]));
    const mine = await create(headers, "/v1/vms");
    const other = await create(member, "/v1/vms");
    expect((await list(headers, "/v1/vms")).items.map((vm) => vm.id).sort()).toEqual([mine.id, other.id].sort());
  });

  it("recovers only snapshots created by the authenticated caller", async () => {
    const headers = await service();
    const member = bearer(await h.addKey(TEAM, ["snapshot:*"]));
    const { vmId } = h.addVm(TEAM, "running", LABELS);
    const mine = await create(headers, `/v1/vms/${vmId}/snapshots`);
    const other = await create(member, `/v1/vms/${vmId}/snapshots`);
    expect((await list(headers, "/v1/snapshots?createdBy=caller")).items.map((snapshot) => snapshot.id)).toEqual([mine.id]);
    expect((await list(member, "/v1/snapshots?createdBy=caller")).items.map((snapshot) => snapshot.id)).toEqual([other.id]);
  });

  it("applies service labels to snapshot listing even without a creator filter", async () => {
    const headers = await service();
    const mine = h.s3a.addSnapshot(TEAM, { labels: LABELS });
    h.s3a.addSnapshot(TEAM, { labels: { role: "other" } });
    expect((await list(headers, "/v1/snapshots")).items.map((snapshot) => snapshot.id)).toEqual([mine.snapshotId]);
    expect((await list(headers, "/v1/snapshots?labels=role%3Dother")).items).toEqual([]);
  });

  it("keeps a service's creator stable across key rotation, separate from other services and tenants", async () => {
    const headers = await service();
    const mine = await create(headers, "/v1/vms");
    const rotated = await service();
    expect((await list(rotated, "/v1/vms?createdBy=caller")).items.map((vm) => vm.id)).toEqual([mine.id]);
    const other = await h.addServiceKey({ id: "other-service", labels: LABELS, scopes: ["vm:read"] });
    expect((await list({ ...bearer(other), "x-cmux-team-id": TEAM }, "/v1/vms?createdBy=caller")).items).toEqual([]);
    expect((await list({ ...headers, "x-cmux-team-id": "team_bravo" }, "/v1/vms?createdBy=caller")).items).toEqual([]);
  });

  it("filters VM creators before pagination and still intersects requested labels", async () => {
    const headers = await service();
    const first = await create(headers, "/v1/vms");
    const second = await create(headers, "/v1/vms");
    for (let i = 0; i < 3; i++) h.addVm(TEAM, "running", LABELS);
    const page = await list(headers, "/v1/vms?createdBy=caller&limit=1&label=role%3Dcloud");
    expect(page.items.map((vm) => vm.id)).toEqual([second.id]);
    expect(page.nextCursor).not.toBeNull();
    const next = await list(headers, `/v1/vms?createdBy=caller&limit=1&cursor=${encodeURIComponent(page.nextCursor ?? "")}`);
    expect(next.items.map((vm) => vm.id)).toEqual([first.id]);
    expect((await list(headers, "/v1/vms?createdBy=caller&label=role%3Dother")).items).toEqual([]);
    expect(JSON.stringify(page)).not.toMatch(/createdBy|created_by|upstreamId|service:cloud-driver/);
  });

  it("filters snapshot creators before pagination, intersects source and labels, and hides creator identity", async () => {
    const headers = await service();
    const { vmId } = h.addVm(TEAM, "running", LABELS);
    const one = await create(headers, `/v1/vms/${vmId}/snapshots`);
    const two = await create(headers, `/v1/vms/${vmId}/snapshots`);
    for (let i = 0; i < 3; i++) h.s3a.addSnapshot(TEAM, { labels: LABELS, sourceVmId: vmId });
    const query = `/v1/snapshots?createdBy=caller&limit=1&sourceVmId=${vmId}&labels=role%3Dcloud`;
    const page = await list(headers, query);
    expect(page.items).toHaveLength(1);
    expect(page.nextCursor).not.toBeNull();
    const next = await list(headers, `${query}&cursor=${encodeURIComponent(page.nextCursor ?? "")}`);
    expect([...page.items, ...next.items].map((snapshot) => snapshot.id).sort()).toEqual([one.id, two.id].sort());
    expect(next.nextCursor).toBeNull();
    expect((await list(headers, "/v1/snapshots?createdBy=caller&labels=role%3Dother")).items).toEqual([]);
    const otherVm = h.addVm(TEAM, "running", LABELS);
    expect((await list(headers, `/v1/snapshots?createdBy=caller&sourceVmId=${otherVm.vmId}`)).items).toEqual([]);
    expect(JSON.stringify(page)).not.toMatch(/createdBy|created_by|upstreamId|service:cloud-driver/);
  });

  it("rejects arbitrary actor selectors without reaching the provider", async () => {
    const headers = await service();
    for (const path of ["/v1/vms", "/v1/snapshots"]) {
      for (const value of ["service:cloud-driver", "key:other", "", "all"]) {
        expect((await h.request(`${path}?createdBy=${encodeURIComponent(value)}`, headers)).status).toBe(400);
      }
    }
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("keeps read scopes required when creator filtering is requested", async () => {
    const key = bearer(await h.addKey(TEAM, ["vm:write", "snapshot:write"]));
    expect((await h.request("/v1/vms?createdBy=caller", key)).status).toBe(403);
    expect((await h.request("/v1/snapshots?createdBy=caller", key)).status).toBe(403);
    expect(h.upstreamRequests).toHaveLength(0);
  });
});
