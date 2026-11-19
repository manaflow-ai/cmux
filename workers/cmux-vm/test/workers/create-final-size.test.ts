/**
 * A create whose asked size is a boot image variant's baked size boots that variant's snapshot at its final size:
 * one provider call (the create), no resize after it, no read before it. Any other create behaves as before: the
 * image's own snapshot, then a grow. A retry boots what its first attempt journaled, whatever the list says now.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
const SNAPSHOT = "operator-immutable-image-fixture";
const LARGE_SNAPSHOT = "operator-immutable-image-fixture-large";
const IMAGE = { id: "cloud-standard", revision: "r1" };
const LARGE = { vcpus: 4, memoryMib: 16384, diskMib: 65536 };
const BASE_ENTRY = { ...IMAGE, displayName: "Cloud standard", snapshotId: SNAPSHOT, services: ["cloud-driver"] };
const LARGE_ENTRY = { ...BASE_ENTRY, large: { snapshotId: LARGE_SNAPSHOT, ...LARGE } };

let current: Harness | undefined;
const harness = async (options: HarnessOptions = {}) => {
  current = await makeHarness({ bootImages: JSON.stringify([LARGE_ENTRY]), ...options });
  // A snapshot keeps its source VM's size: the image's own is the small base, the large one the chat start size.
  current.upstream.snapshots.set(SNAPSHOT, { id: SNAPSHOT, sourceVmId: "operator-image-source", autoDeleteSeconds: null, resources: { cpu: 2, memory: 4096, storage: 16384 } });
  current.upstream.snapshots.set(LARGE_SNAPSHOT, { id: LARGE_SNAPSHOT, sourceVmId: "operator-image-source", autoDeleteSeconds: null, resources: { cpu: 4, memory: 16384, storage: 65536 } });
  return current;
};
afterEach(async () => { await current?.dispose(); current = undefined; });

const service = (t: Harness) => t.addServiceKey({ id: "cloud-driver", scopes: ["vm:read", "vm:write"], labels: { role: "cloud" } });
const headers = (key: string) => ({ ...bearer(key), "x-cmux-team-id": "team_alpha" });
const create = (t: Harness, key: string, extra: object = {}, retry?: string) => t.request("/v1/vms", {
  ...headers(key), ...(retry === undefined ? {} : { "Idempotency-Key": retry }),
}, { method: "POST", body: { image: IMAGE, labels: { role: "cloud" }, ...extra } });
const record = (v: unknown): Record<string, unknown> => (typeof v === "object" && v !== null ? Object.fromEntries(Object.entries(v)) : {});
const creates = (t: Harness) => t.upstream.callsTo("POST", /^\/v5\/vms$/);
const resizes = (t: Harness) => t.upstream.callsTo("POST", /^\/v5\/vms\/[^/]+\/resize$/);
const slugReads = (t: Harness) => t.upstream.callsTo("GET", /^\/v5\/vms\/cmux-vm-/);
const imageReads = (t: Harness) => t.upstream.callsTo("GET", /^\/v5\/snapshots\//);

/** Collects the vm_create log lines while `run` runs. */
const linesOf = async (run: () => Promise<void>) => {
  const lines: Array<Record<string, unknown>> = [];
  const spy = vi.spyOn(console, "error").mockImplementation((line: unknown) => {
    if (typeof line !== "string" || !line.startsWith("{")) return;
    const parsed = record(JSON.parse(line));
    if (parsed["event"] === "vm_create") lines.push(parsed);
  });
  try { await run(); } finally { spy.mockRestore(); }
  return lines;
};

describe("a create at a variant's size", () => {
  it("boots the variant's snapshot at its final size with no resize, and says so in vm_create", async () => {
    const t = await harness();
    const key = await service(t);
    let text = "";
    const lines = await linesOf(async () => {
      const response = await create(t, key, { resources: LARGE });
      expect(response.status).toBe(201);
      text = await response.text();
    });
    expect(JSON.parse(text)).toMatchObject({ resources: LARGE, bootImage: { ...IMAGE, displayName: "Cloud standard" } });
    // The public answer names the image, never a provider snapshot of it.
    expect(text).not.toContain(SNAPSHOT);
    expect(creates(t)).toHaveLength(1);
    expect(creates(t)[0]?.json).toMatchObject({ snapshotId: LARGE_SNAPSHOT });
    expect(resizes(t)).toHaveLength(0);
    expect(lines).toHaveLength(1);
    expect(lines[0]).toMatchObject({ ok: true, bootVariant: "large", resized: false, resizeMs: null, recovered: false });
    expect(JSON.stringify(lines[0])).not.toContain(SNAPSHOT);
  });

  it.each([
    ["a larger size", { vcpus: 8, memoryMib: 16384, diskMib: 65536 }, true],
    ["a smaller size", { vcpus: 4, memoryMib: 8192, diskMib: 32768 }, true],
    ["a size missing an axis", { vcpus: 4, memoryMib: 16384 }, true],
    ["no size", undefined, false],
  ])("boots the image's own snapshot and grows as before for %s", async (_name, resources, grows) => {
    const t = await harness();
    const key = await service(t);
    const lines = await linesOf(async () => {
      expect((await create(t, key, resources === undefined ? {} : { resources })).status).toBe(201);
    });
    expect(creates(t)[0]?.json).toMatchObject({ snapshotId: SNAPSHOT });
    expect(resizes(t)).toHaveLength(grows ? 1 : 0);
    expect(lines[0]).toMatchObject({ ok: true, bootVariant: "base", resized: grows });
  });

  it("leaves an entry without a variant, and a create without an approved image, as they were", async () => {
    const t = await harness({ bootImages: JSON.stringify([BASE_ENTRY]) });
    const key = await service(t);
    const lines = await linesOf(async () => {
      expect((await create(t, key, { resources: LARGE })).status).toBe(201);
      expect((await t.request("/v1/vms", headers(key), { method: "POST", body: { labels: { role: "cloud" } } })).status).toBe(201);
    });
    expect(creates(t)[0]?.json).toMatchObject({ snapshotId: SNAPSHOT });
    expect(resizes(t)).toHaveLength(1);
    expect(lines[0]).toMatchObject({ bootVariant: "base", resized: true });
    expect(lines[1]).toMatchObject({ bootVariant: null, resized: false });
  });

  it.each([
    ["no snapshot", { ...LARGE }],
    ["a size that is not whole numbers", { snapshotId: LARGE_SNAPSHOT, vcpus: 4.5, memoryMib: 16384, diskMib: 65536 }],
    ["an unknown field", { snapshotId: LARGE_SNAPSHOT, ...LARGE, extra: true }],
    ["an unsafe snapshot reference", { snapshotId: "unsafe\nreference", ...LARGE }],
    ["the image's own snapshot", { snapshotId: SNAPSHOT, ...LARGE }],
  ])("drops a malformed variant (%s) and keeps the image", async (_name, large) => {
    const t = await harness({ bootImages: JSON.stringify([{ ...BASE_ENTRY, large }]) });
    const key = await service(t);
    expect(await (await t.request("/v1/vm-images", headers(key))).json()).toEqual({ order: "configured", items: [{ ...IMAGE, displayName: "Cloud standard" }] });
    expect((await create(t, key, { resources: LARGE })).status).toBe(201);
    expect(creates(t)[0]?.json).toMatchObject({ snapshotId: SNAPSHOT });
    expect(resizes(t)).toHaveLength(1);
  });
});

describe("reads before a create", () => {
  it("makes no exact-slug read on a first attempt, and reads an image from the provider once, not per create", async () => {
    const t = await harness();
    const key = await service(t);
    const lines = await linesOf(async () => {
      expect((await create(t, key, { resources: LARGE })).status).toBe(201);
      expect((await create(t, key, { resources: LARGE })).status).toBe(201);
    });
    expect(slugReads(t)).toHaveLength(0);
    expect(imageReads(t).map((call) => call.path)).toEqual([`/v5/snapshots/${LARGE_SNAPSHOT}`]);
    // The second create is one provider call: the create.
    expect(t.upstreamRequests.slice(-1).map((call) => `${call.method} ${call.path}`)).toEqual(["POST /v5/vms"]);
    expect(t.upstreamRequests).toHaveLength(3);
    expect(lines[0]).toMatchObject({ recoverMs: null, recovered: false });
    expect(typeof lines[0]!["verifyImageMs"]).toBe("number");
    expect(lines[1]).toMatchObject({ recoverMs: null, verifyImageMs: null, recovered: false, bootVariant: "large", resized: false });
  });

  it("still reads the exact slug on a retry and recovers the VM its first attempt made", async () => {
    const t = await harness();
    const key = await service(t);
    // The VM is made upstream but its ownership row is not written: the retry finds it by its exact slug.
    t.recordFault.before = 1;
    const lines = await linesOf(async () => {
      expect((await create(t, key, { resources: LARGE }, "final-size-retry")).status).toBe(503);
      expect((await create(t, key, { resources: LARGE }, "final-size-retry")).status).toBe(201);
    });
    expect(creates(t)).toHaveLength(1);
    expect(slugReads(t)).toHaveLength(1);
    expect(resizes(t)).toHaveLength(0);
    expect(lines[1]).toMatchObject({ ok: true, recovered: true, bootVariant: "large", resized: false });
    expect(typeof lines[1]!["recoverMs"]).toBe("number");
  });

  it("reads an image again after a create with it failed, and then refuses before sending", async () => {
    const t = await harness();
    const key = await service(t);
    expect((await create(t, key, { resources: LARGE })).status).toBe(201);
    t.upstream.snapshots.delete(LARGE_SNAPSHOT);
    // The image is gone at the provider: the create itself is refused, nothing is made.
    expect((await create(t, key, { resources: LARGE })).status).toBe(503);
    expect(creates(t)).toHaveLength(2);
    expect(imageReads(t)).toHaveLength(1);
    // The next create checks the image first and sends nothing.
    expect((await create(t, key, { resources: LARGE })).status).toBe(503);
    expect(creates(t)).toHaveLength(2);
    expect(imageReads(t)).toHaveLength(2);
    expect(t.resources).toHaveLength(1);
  });
});

describe("a retry across a change of the image list", () => {
  it("recovers a create journaled before the image had a variant: it booted the image's own snapshot", async () => {
    const t = await harness({ bootImages: JSON.stringify([BASE_ENTRY]) });
    const key = await service(t);
    t.recordFault.before = 1;
    expect((await create(t, key, { resources: LARGE }, "before-variant")).status).toBe(503);
    t.setBootImages(JSON.stringify([LARGE_ENTRY]));
    const lines = await linesOf(async () => {
      const retried = await create(t, key, { resources: LARGE }, "before-variant");
      expect(retried.status).toBe(201);
      expect(await retried.json()).toMatchObject({ resources: LARGE });
    });
    expect(creates(t)).toHaveLength(1);
    expect(creates(t)[0]?.json).toMatchObject({ snapshotId: SNAPSHOT });
    expect(lines[0]).toMatchObject({ recovered: true, bootVariant: "base" });
  });

  it("never boots another snapshot for a create journaled on a variant the list has since lost", async () => {
    const t = await harness();
    const key = await service(t);
    t.recordFault.before = 1;
    expect((await create(t, key, { resources: LARGE }, "after-variant")).status).toBe(503);
    t.setBootImages(JSON.stringify([BASE_ENTRY]));
    expect((await create(t, key, { resources: LARGE }, "after-variant")).status).toBe(503);
    expect(creates(t)).toHaveLength(1);
    expect(resizes(t)).toHaveLength(0);
    // Listed again, the same key finishes on the VM it made.
    t.setBootImages(JSON.stringify([LARGE_ENTRY]));
    expect((await create(t, key, { resources: LARGE }, "after-variant")).status).toBe(201);
    expect(creates(t)).toHaveLength(1);
  });
});
