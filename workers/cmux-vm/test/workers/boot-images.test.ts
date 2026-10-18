import { afterEach, describe, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
const SNAPSHOT = "operator-immutable-image-fixture";
const IMAGE = { id: "cloud-standard", revision: "r1" };
const CATALOG = [{ ...IMAGE, displayName: "Cloud standard", snapshotId: SNAPSHOT, services: ["cloud-driver"] }];
let current: Harness | undefined;
const harness = async () => {
  current = await makeHarness({ bootImages: JSON.stringify(CATALOG) });
  current.upstream.snapshots.set(SNAPSHOT, { id: SNAPSHOT, sourceVmId: "operator-image-source", autoDeleteSeconds: null });
  return current;
};
afterEach(async () => { await current?.dispose(); current = undefined; });
const service = (t: Harness) => t.addServiceKey({ id: "cloud-driver", scopes: ["vm:read", "vm:write"], labels: { role: "cloud" } });
const headers = (key: string) => ({ ...bearer(key), "x-cmux-team-id": "team_alpha" });

describe("approved service boot images", () => {
  it("boots the approved snapshot and confirms its public revision", async () => {
    const t = await harness();
    const key = await service(t);
    const response = await t.request("/v1/vms", headers(key), { method: "POST", body: { image: IMAGE, labels: { role: "cloud" } } });
    expect(response.status).toBe(201);
    const body = await response.text();
    expect(JSON.parse(body)).toMatchObject({ bootImage: { ...IMAGE, displayName: "Cloud standard" } });
    expect(body).not.toContain(SNAPSHOT);
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)[0]?.json).toMatchObject({ snapshotId: SNAPSHOT });
  });

  it("lists only public image descriptors for the approved service", async () => {
    const t = await harness();
    const key = await service(t);
    const response = await t.request("/v1/vm-images", headers(key));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ items: [{ ...IMAGE, displayName: "Cloud standard" }] });
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("does not turn ordinary VM write permission into image-service authority", async () => {
    const t = await harness();
    const key = await t.addKey("team_alpha", ["vm:write"]);
    expect((await t.request("/v1/vms", bearer(key), { method: "POST", body: { image: IMAGE } })).status).toBe(404);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("rejects choosing both an image and a tenant snapshot", async () => {
    const t = await harness();
    const key = await t.addKey("team_alpha", ["vm:write"]);
    const snapshot = t.addSnapshot("team_alpha");
    expect((await t.request("/v1/vms", bearer(key), { method: "POST", body: { image: IMAGE, snapshotId: snapshot.snapshotId } })).status).toBe(400);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("keeps ordinary base-image creation unchanged", async () => {
    const t = await harness();
    const key = await t.addKey("team_alpha", ["vm:write"]);
    const response = await t.request("/v1/vms", bearer(key), { method: "POST", body: {} });
    expect(response.status).toBe(201);
    expect(await response.json()).not.toHaveProperty("bootImage");
  });
});
