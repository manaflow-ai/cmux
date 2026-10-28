import { afterEach, describe, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
const SNAPSHOT = "operator-immutable-image-fixture";
const IMAGE = { id: "cloud-standard", revision: "r1" };
const CATALOG = [{ ...IMAGE, displayName: "Cloud standard", snapshotId: SNAPSHOT, services: ["cloud-driver"] }];
let current: Harness | undefined;
const harness = async (options: HarnessOptions = {}) => {
  current = await makeHarness({ bootImages: JSON.stringify(CATALOG), ...options });
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

const create = (t: Harness, key: string, extra: object = {}, retry?: string) => t.request("/v1/vms", {
  ...headers(key), ...(retry === undefined ? {} : { "Idempotency-Key": retry }),
}, { method: "POST", body: { image: IMAGE, labels: { role: "cloud" }, ...extra } });

describe("approved image boundaries and retries", () => {
  it("keeps another service and ordinary tenant keys outside the catalog", async () => {
    const t = await harness();
    const ordinary = await t.addKey("team_alpha", ["vm:read", "vm:write"]);
    const other = await t.addServiceKey({ id: "other-service", scopes: ["vm:read", "vm:write"], labels: { role: "cloud" } });
    for (const key of [ordinary, other]) {
      expect(await (await t.request("/v1/vm-images", headers(key))).json()).toEqual({ items: [] });
      expect((await create(t, key)).status).toBe(404);
    }
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("retains read/write scopes, required labels and the service team allowlist", async () => {
    const t = await harness();
    const read = await t.addServiceKey({ id: "cloud-driver", scopes: ["vm:read"], labels: { role: "cloud" } });
    const write = await t.addServiceKey({ id: "cloud-driver", scopes: ["vm:write"], labels: { role: "cloud" } });
    const foreign = await t.addServiceKey({ id: "cloud-driver", teams: ["team_bravo"] });
    expect((await create(t, read)).status).toBe(403);
    expect((await t.request("/v1/vm-images", headers(write))).status).toBe(403);
    expect((await create(t, write, { labels: {} })).status).toBe(403);
    expect((await t.request("/v1/vm-images", headers(foreign))).status).toBe(403);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("rejects a stale revision before contacting the provider", async () => {
    const t = await harness();
    const key = await service(t);
    expect((await create(t, key, { image: { ...IMAGE, revision: "r0" } })).status).toBe(409);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it.each(["missing", "mutable-alias"])("does not fall back from an unavailable or mutable image: %s", async (mode) => {
    const t = await harness();
    const key = await service(t);
    if (mode === "missing") t.upstream.snapshots.delete(SNAPSHOT);
    else t.upstream.snapshots.set(SNAPSHOT, { id: "different-canonical-id", sourceVmId: "operator", autoDeleteSeconds: null });
    const response = await create(t, key);
    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain(SNAPSHOT);
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(0);
    expect(t.resources).toHaveLength(0);
  });

  it.each(["billing", "quota", "idle-cap"])("retains the existing creation gate: %s", async (gate) => {
    const t = await harness(gate === "quota" ? { maxVms: 0 } : {});
    const key = await service(t);
    if (gate === "billing") t.setBilling("team_alpha", false);
    const response = await create(t, key, gate === "idle-cap" ? { idleTimeoutSeconds: -1 } : {});
    expect(response.status).toBe(gate === "billing" ? 402 : gate === "quota" ? 429 : 400);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("replays an identical image but conflicts when the operator changes its backing snapshot or revision", async () => {
    const t = await harness();
    const key = await service(t);
    const first = await create(t, key, {}, "image-retry");
    const replay = await create(t, key, {}, "image-retry");
    expect(first.status).toBe(201);
    expect(replay.status).toBe(201);
    expect(await replay.json()).toEqual(await first.json());
    t.setBootImages(JSON.stringify([{ ...CATALOG[0], snapshotId: "replacement-snapshot" }]));
    expect((await create(t, key, {}, "image-retry")).status).toBe(409);
    t.setBootImages(JSON.stringify([{ ...CATALOG[0], revision: "r2" }]));
    expect((await create(t, key, { image: { ...IMAGE, revision: "r2" } }, "image-retry")).status).toBe(409);
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
    expect(t.upstream.callsTo("GET", /^\/v5\/snapshots\//)).toHaveLength(1);
  });

  it("does not grant network access with image approval", async () => {
    const t = await harness();
    const key = await service(t);
    expect((await create(t, key, { initialNetwork: { publicEgress: true } })).status).toBe(403);
    expect(t.upstreamRequests).toHaveLength(0);
    const network = await t.addServiceKey({ id: "cloud-driver", scopes: ["vm:write", "vm:network"], labels: { role: "cloud" } });
    const response = await create(t, network, { initialNetwork: { publicEgress: true } });
    expect(response.status).toBe(201);
    expect(await response.json()).toMatchObject({ bootImage: IMAGE, initialNetwork: { publicEgress: true } });
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)[0]?.json).toMatchObject({ snapshotId: SNAPSHOT,
      firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] } });
  });

  it.each([
    "not-json", "{}", JSON.stringify([CATALOG[0], CATALOG[0]]),
    JSON.stringify([{ ...CATALOG[0], services: [] }]), JSON.stringify([{ ...CATALOG[0], unknown: "field" }]),
    JSON.stringify([{ ...CATALOG[0], snapshotId: "unsafe\nreference" }]),
  ])("disables malformed operator configuration while preserving ordinary create", async (bootImages) => {
    const t = await harness({ bootImages });
    const key = await service(t);
    expect(await (await t.request("/v1/vm-images", headers(key))).json()).toEqual({ items: [] });
    expect((await create(t, key)).status).toBe(404);
    expect(t.upstreamRequests).toHaveLength(0);
    expect((await t.request("/v1/vms", headers(key), { method: "POST", body: { labels: { role: "cloud" } } })).status).toBe(201);
  });
});
