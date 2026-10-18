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
beforeEach(async () => { h = await makeHarness(); });
afterEach(async () => { await h.dispose(); });

const service = async () => {
  const key = await h.addServiceKey({ id: "cloud-driver", labels: LABELS, scopes: ["vm:read", "vm:write", "snapshot:*"] });
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
});
