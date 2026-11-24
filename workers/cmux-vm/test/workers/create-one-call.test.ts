/**
 * One provider call per create.
 *
 * A Cloud create that asks for the chat start size made four provider calls: the exact-slug recovery read and the boot
 * image read, the create from an image baked small, and a resize to the size asked. Here, each behind its own switch
 * (a list of service key ids, off when unset): an approved image may list a `large` snapshot of the same bake, booted
 * when the create asks for exactly its size, so no resize follows; and a create whose VM id was minted in the request
 * sends no read before the create.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
const TEAM = "team_alpha";
const SERVICE = "cloud-driver";
const SMALL = "operator-image-small-fixture";
const LARGE = "operator-image-large-fixture";
const IMAGE = { id: "cloud-standard", revision: "r1" };
const LARGE_SHAPE = { vcpus: 4, memoryMib: 16384, diskMib: 65536 };
const ENTRY = { ...IMAGE, displayName: "Cloud standard", snapshotId: SMALL, services: [SERVICE] };
const WITH_LARGE = [{ ...ENTRY, large: { snapshotId: LARGE, ...LARGE_SHAPE } }];
const SIZED = { createSwitches: { sizedImageServiceIds: [SERVICE] } } satisfies HarnessOptions;
const NO_READS = { createSwitches: { noReadsServiceIds: [SERVICE] } } satisfies HarnessOptions;

let h: Harness;
const seedSnapshots = () => {
  // The small image is the bake at the base's size; the large one is the same builder grown and snapshotted again.
  h.upstream.snapshots.set(SMALL, { id: SMALL, sourceVmId: "operator-image-source", autoDeleteSeconds: null, resources: { cpu: 2, memory: 4096, storage: 16384 } });
  h.upstream.snapshots.set(LARGE, { id: LARGE, sourceVmId: "operator-image-source", autoDeleteSeconds: null, resources: { cpu: 4, memory: 16384, storage: 65536 } });
};
const harness = async (options: HarnessOptions = {}, catalog: unknown = WITH_LARGE) => {
  h = await makeHarness({ bootImages: JSON.stringify(catalog), ...options });
  seedSnapshots();
  return h;
};
afterEach(async () => { await h.dispose(); });

const record = (v: unknown): Record<string, unknown> => (typeof v === "object" && v !== null ? Object.fromEntries(Object.entries(v)) : {});
const serviceKey = () => h.addServiceKey({ id: SERVICE, scopes: ["vm:read", "vm:write"], labels: { role: "cloud" } });
const create = (key: string, body: Record<string, unknown>, requestKey?: string) =>
  h.request("/v1/vms", { ...bearer(key), "x-cmux-team-id": TEAM, ...(requestKey === undefined ? {} : { "Idempotency-Key": requestKey }) }, { method: "POST", body: { labels: { role: "cloud" }, ...body } });
const imageCreate = (key: string, resources?: Record<string, number>, requestKey?: string) =>
  create(key, { image: IMAGE, ...(resources === undefined ? {} : { resources }) }, requestKey);
const providerCreates = () => h.upstream.callsTo("POST", /^\/v5\/vms$/);
const providerResizes = () => h.upstream.callsTo("POST", /^\/v5\/vms\/[^/]+\/resize$/);
const slugReads = () => h.upstream.callsTo("GET", /^\/v5\/vms\/cmux-vm-/);
const imageReads = () => h.upstream.callsTo("GET", /^\/v5\/snapshots\//);
/** The provider calls made so far, as `METHOD path-kind`, in order. */
const providerCalls = () => h.upstreamRequests.map((call) => `${call.method} ${call.path.replace(/^\/v5\/vms\/cmux-vm-.*$/u, "/v5/vms/<slug>").replace(/^\/v5\/snapshots\/.*$/u, "/v5/snapshots/<id>").replace(/^\/v5\/vms\/[^/]+\/resize$/u, "/v5/vms/<id>/resize").replace(/^\/v5\/vms\/vm-[^/]+$/u, "/v5/vms/<id>")}`);

/** Collects the JSON log lines of one event while `run` runs. */
const linesOf = async (event: string, run: () => Promise<void>) => {
  const lines: Array<Record<string, unknown>> = [];
  const spy = vi.spyOn(console, "error").mockImplementation((line: unknown) => {
    if (typeof line !== "string" || !line.startsWith("{")) return;
    const parsed = record(JSON.parse(line));
    if (parsed["event"] === event) lines.push(parsed);
  });
  try { await run(); } finally { spy.mockRestore(); }
  return lines;
};
const createLines = (run: () => Promise<void>) => linesOf("vm_create", run);
const BOTH = { createSwitches: { sizedImageServiceIds: [SERVICE], noReadsServiceIds: [SERVICE] } } satisfies HarnessOptions;
const OTHER_LARGE = "operator-image-large-rebaked-fixture";

describe("an approved image's large snapshot", () => {
  it("boots when the create asks for exactly its size, and no resize follows", async () => {
    await harness(SIZED);
    const key = await serviceKey();
    let made: Response | undefined;
    const lines = await createLines(async () => { made = await imageCreate(key, LARGE_SHAPE); });
    expect(made?.status).toBe(201);
    const text = await made!.text();
    expect(JSON.parse(text)).toMatchObject({ resources: LARGE_SHAPE, bootImage: { ...IMAGE, displayName: "Cloud standard" } });
    expect(text).not.toContain(LARGE);
    expect(providerCreates().map((call) => record(call.json)["snapshotId"])).toEqual([LARGE]);
    expect(providerResizes()).toHaveLength(0);
    expect(lines).toHaveLength(1);
    expect(lines[0]).toMatchObject({ ok: true, imageVariant: "large", resizeMs: null });
    expect(JSON.stringify(lines[0])).not.toContain(LARGE);
  });

  it("is not booted for any other size: the small image boots and is resized", async () => {
    await harness(SIZED);
    const key = await serviceKey();
    for (const resources of [{ vcpus: 8, memoryMib: 16384, diskMib: 65536 }, { vcpus: 4, memoryMib: 8192, diskMib: 32768 }, { vcpus: 4, memoryMib: 16384 }]) {
      const before = { creates: providerCreates().length, resizes: providerResizes().length };
      let made: Response | undefined;
      const lines = await createLines(async () => { made = await imageCreate(key, resources); });
      expect(made?.status, JSON.stringify(resources)).toBe(201);
      expect(record(await made!.json())["resources"]).toMatchObject(resources);
      expect(record(providerCreates()[before.creates]?.json)["snapshotId"], JSON.stringify(resources)).toBe(SMALL);
      expect(providerResizes().length, JSON.stringify(resources)).toBe(before.resizes + 1);
      expect(lines[0]).toMatchObject({ imageVariant: "base" });
      expect(typeof lines[0]!["resizeMs"]).toBe("number");
    }
  });

  it("is not booted by a create that names no size", async () => {
    await harness(SIZED);
    const key = await serviceKey();
    expect((await imageCreate(key)).status).toBe(201);
    expect(record(providerCreates()[0]?.json)["snapshotId"]).toBe(SMALL);
    expect(providerResizes()).toHaveLength(0);
  });

  it("is per revision: an image that lists none boots small and is resized", async () => {
    await harness(SIZED, [ENTRY]);
    const key = await serviceKey();
    expect((await imageCreate(key, LARGE_SHAPE)).status).toBe(201);
    expect(record(providerCreates()[0]?.json)["snapshotId"]).toBe(SMALL);
    expect(providerResizes().map((call) => call.json)).toEqual([{ cpu: 4, memory: 16384, storage: 65536 }]);
  });

  it("is off unless the caller's service is listed", async () => {
    await harness({ createSwitches: { sizedImageServiceIds: ["some-other-service"] } });
    const key = await serviceKey();
    let made: Response | undefined;
    const lines = await createLines(async () => { made = await imageCreate(key, LARGE_SHAPE); });
    expect(made?.status).toBe(201);
    expect(record(providerCreates()[0]?.json)["snapshotId"]).toBe(SMALL);
    expect(providerResizes()).toHaveLength(1);
    expect(lines[0]).toMatchObject({ imageVariant: "base" });
  });

  it("still resizes when the provider's answer is smaller than the large size", async () => {
    await harness(SIZED);
    // A large snapshot that boots smaller than its entry says: the resize is decided by the provider's answer.
    h.upstream.snapshots.set(LARGE, { id: LARGE, sourceVmId: "operator-image-source", autoDeleteSeconds: null, resources: { cpu: 4, memory: 8192, storage: 65536 } });
    const key = await serviceKey();
    const made = await imageCreate(key, LARGE_SHAPE);
    expect(made.status).toBe(201);
    expect(record(await made.json())["resources"]).toEqual(LARGE_SHAPE);
    expect(providerResizes().map((call) => call.json)).toEqual([{ memory: 16384 }]);
  });

  it("drops a malformed large entry without disabling the image", async () => {
    for (const large of ["sh-not-an-object", { snapshotId: LARGE }, { snapshotId: LARGE, vcpus: 4, memoryMib: 16384, diskMib: 65536, extra: 1 }, { snapshotId: "", ...LARGE_SHAPE }, { snapshotId: LARGE, vcpus: 4.5, memoryMib: 16384, diskMib: 65536 }]) {
      await harness(SIZED, [{ ...ENTRY, large }]);
      const key = await serviceKey();
      expect((await imageCreate(key, LARGE_SHAPE)).status, JSON.stringify(large)).toBe(201);
      expect(record(providerCreates()[0]?.json)["snapshotId"], JSON.stringify(large)).toBe(SMALL);
      await h.dispose();
    }
    await harness();
  });

  it("leaves a tenant snapshot's create alone, whatever size it asks for", async () => {
    await harness(SIZED);
    const key = await h.addKey(TEAM, ["vm:read", "vm:write"]);
    const { snapshotId } = h.addSnapshot(TEAM);
    const made = await h.request("/v1/vms", bearer(key), { method: "POST", body: { snapshotId, resources: LARGE_SHAPE } });
    expect(made.status).toBe(201);
    expect(record(providerCreates()[0]?.json)["snapshotId"]).not.toBe(LARGE);
    expect(providerResizes()).toHaveLength(1);
  });

  it("recovers a VM its first attempt made from the small image after the entry gains a large snapshot", async () => {
    await harness(SIZED, [ENTRY]);
    const key = await serviceKey();
    // The VM is made upstream from the small image but its ownership row is not written.
    h.recordFault.before = 1;
    expect((await imageCreate(key, LARGE_SHAPE, "one-call-variant-retry")).status).toBe(503);
    h.setBootImages(JSON.stringify(WITH_LARGE));
    const retry = await imageCreate(key, LARGE_SHAPE, "one-call-variant-retry");
    expect(retry.status).toBe(201);
    expect(record(await retry.json())["resources"]).toEqual(LARGE_SHAPE);
    expect(providerCreates().map((call) => record(call.json)["snapshotId"])).toEqual([SMALL]);
    expect(h.upstream.vms.size).toBe(1);
  });

  it("recovers a VM its first attempt made from the large snapshot after the switch is turned off", async () => {
    await harness(SIZED);
    const key = await serviceKey();
    h.recordFault.before = 1;
    expect((await imageCreate(key, LARGE_SHAPE, "one-call-variant-off")).status).toBe(503);
    h.setCreateSwitches({});
    const retry = await imageCreate(key, LARGE_SHAPE, "one-call-variant-off");
    expect(retry.status).toBe(201);
    expect(providerCreates().map((call) => record(call.json)["snapshotId"])).toEqual([LARGE]);
    expect(providerResizes()).toHaveLength(0);
    expect(h.upstream.vms.size).toBe(1);
  });
});

describe("a retry after the entry lost or replaced its large snapshot", () => {
  /** Attempt 1 boots the large snapshot, loses the create's answer and cannot read the slug: the VM exists, unrecorded. */
  const lostLargeBoot = async (requestKey: string) => {
    await harness(BOTH);
    const key = await serviceKey();
    h.upstream.faults.lostCreateResponses = 1;
    h.upstream.fail("get", 500);
    expect((await imageCreate(key, LARGE_SHAPE, requestKey)).status).toBe(503);
    expect(providerCalls()).toEqual(["POST /v5/vms", "GET /v5/vms/<slug>"]);
    expect(h.upstream.vms.size).toBe(1);
    expect(h.resources.filter((row) => row.kind === "vm")).toHaveLength(0);
    return key;
  };

  for (const [what, catalog] of [["dropped", [ENTRY]], ["replaced", [{ ...ENTRY, large: { snapshotId: OTHER_LARGE, ...LARGE_SHAPE } }]]] as const) {
    it(`returns the VM the first attempt made when the entry's large snapshot was ${what}, and creates no second one`, async () => {
      const key = await lostLargeBoot(`one-call-large-${what}`);
      h.upstream.snapshots.set(OTHER_LARGE, { id: OTHER_LARGE, sourceVmId: "operator-image-source", autoDeleteSeconds: null, resources: { cpu: 4, memory: 16384, storage: 65536 } });
      h.setBootImages(JSON.stringify(catalog));
      let retry: Response | undefined;
      const lines = await createLines(async () => { retry = await imageCreate(key, LARGE_SHAPE, `one-call-large-${what}`); });
      expect(retry?.status).toBe(201);
      expect(JSON.parse(await retry!.text())).toMatchObject({ resources: LARGE_SHAPE, bootImage: { ...IMAGE, displayName: "Cloud standard" } });
      expect(providerCreates().map((call) => record(call.json)["snapshotId"])).toEqual([LARGE]);
      expect(providerCalls()).toEqual(["POST /v5/vms", "GET /v5/vms/<slug>", "GET /v5/vms/<slug>"]);
      expect(providerResizes()).toHaveLength(0);
      expect(h.upstream.vms.size).toBe(1);
      expect(h.resources.filter((row) => row.kind === "vm")).toHaveLength(1);
      expect(lines[0]).toMatchObject({ ok: true, recovered: true, imageVariant: "unlisted", createMs: null });
    });
  }

  it("does not adopt a VM at the slug booted from another snapshot than the one journaled", async () => {
    const key = await lostLargeBoot("one-call-large-foreign");
    for (const vm of h.upstream.vms.values()) vm.snapshotId = "some-other-snapshot";
    h.setBootImages(JSON.stringify([ENTRY]));
    expect((await imageCreate(key, LARGE_SHAPE, "one-call-large-foreign")).status).toBe(503);
    expect(providerCreates()).toHaveLength(1);
    expect(h.resources.filter((row) => row.kind === "vm")).toHaveLength(0);
  });

  it("creates nothing from the entry as it is now when the first attempt made nothing", async () => {
    await harness(BOTH);
    const key = await serviceKey();
    h.upstream.fail("create", 500);
    expect((await imageCreate(key, LARGE_SHAPE, "one-call-large-nothing")).status).toBe(503);
    h.setBootImages(JSON.stringify([ENTRY]));
    expect((await imageCreate(key, LARGE_SHAPE, "one-call-large-nothing")).status).toBe(503);
    expect(providerCreates()).toHaveLength(1);
    expect(h.upstream.vms.size).toBe(0);
  });
});

describe("a large snapshot that boots bigger than was asked", () => {
  it("is deleted and the create fails, with nothing recorded", async () => {
    await harness(SIZED);
    // The entry says 4 vCPU / 16 GiB / 64 GiB; the snapshot really boots with a 128 GiB disk.
    h.upstream.snapshots.set(LARGE, { id: LARGE, sourceVmId: "operator-image-source", autoDeleteSeconds: null, resources: { cpu: 4, memory: 16384, storage: 131072 } });
    const key = await serviceKey();
    let made: Response | undefined;
    const lines = await createLines(async () => { made = await imageCreate(key, LARGE_SHAPE, "one-call-oversized"); });
    expect(made?.status).toBe(503);
    expect(providerCreates().map((call) => record(call.json)["snapshotId"])).toEqual([LARGE]);
    expect(h.upstream.vms.size).toBe(0);
    expect(h.resources.filter((row) => row.kind === "vm")).toHaveLength(0);
    expect(lines).toHaveLength(1);
    expect(lines[0]).toMatchObject({ ok: false, imageVariant: "large", oversized: true });
  });

  it("is not adopted by a retry when its delete failed", async () => {
    await harness(SIZED);
    h.upstream.snapshots.set(LARGE, { id: LARGE, sourceVmId: "operator-image-source", autoDeleteSeconds: null, resources: { cpu: 8, memory: 16384, storage: 65536 } });
    const key = await serviceKey();
    h.upstream.fail("delete", 500);
    const discards = await linesOf("vm_create_discard_failed", async () => {
      expect((await imageCreate(key, LARGE_SHAPE, "one-call-oversized-kept")).status).toBe(503);
    });
    expect(discards).toHaveLength(1);
    expect(discards[0]).toMatchObject({ reason: "oversized", status: 500 });
    expect(String(discards[0]!["vmId"])).toMatch(/^vm_/u);
    expect(JSON.stringify(discards[0])).not.toContain([...h.upstream.vms.keys()][0]);
    expect(h.upstream.vms.size).toBe(1);
    const lines = await createLines(async () => { expect((await imageCreate(key, LARGE_SHAPE, "one-call-oversized-kept")).status).toBe(503); });
    expect(lines[0]).toMatchObject({ ok: false, oversized: true });
    expect(h.resources.filter((row) => row.kind === "vm")).toHaveLength(0);
    expect(providerCreates()).toHaveLength(1);
  });

  it("says oversized false on an ordinary create's line", async () => {
    await harness(SIZED);
    const key = await serviceKey();
    const lines = await createLines(async () => { expect((await imageCreate(key, LARGE_SHAPE)).status).toBe(201); });
    expect(lines[0]).toMatchObject({ imageVariant: "large", oversized: false });
  });
});

describe("a create with no provider read before it", () => {
  it("answers 503 for a create the provider failed with a 5xx, and sends no second create under the key inside the grace window", async () => {
    await harness(NO_READS);
    const key = await serviceKey();
    h.upstream.fail("create", 500);
    expect((await imageCreate(key, undefined, "one-call-5xx")).status).toBe(503);
    // A 5xx does not prove nothing was made: the send stays uncertain, and a retry reads the slug but does not send.
    expect(providerCalls()).toEqual(["POST /v5/vms", "GET /v5/vms/<slug>"]);
    expect((await imageCreate(key, undefined, "one-call-5xx")).status).toBe(503);
    expect(providerCalls()).toEqual(["POST /v5/vms", "GET /v5/vms/<slug>", "GET /v5/vms/<slug>"]);
    expect(h.upstream.vms.size).toBe(0);
  });

  it("logs a mismatched VM whose delete failed", async () => {
    await harness(NO_READS);
    const key = await serviceKey();
    const provider = h.upstream.fetch;
    h.upstream.fetch = async (request) => {
      const answer = await provider(request);
      if (request.method !== "POST" || new URL(request.url).pathname !== "/v5/vms" || answer.status !== 201) return answer;
      // The provider really booted another snapshot: the VM says so on every later read too.
      for (const vm of h.upstream.vms.values()) vm.snapshotId = "some-other-snapshot";
      return Response.json({ ...record(await answer.json()), snapshotId: "some-other-snapshot" }, { status: 201 });
    };
    h.upstream.fail("delete", 500);
    const discards = await linesOf("vm_create_discard_failed", async () => { expect((await imageCreate(key)).status).toBe(503); });
    expect(discards).toHaveLength(1);
    expect(discards[0]).toMatchObject({ reason: "receipt", status: 500 });
    expect(JSON.stringify(discards[0])).not.toContain([...h.upstream.vms.keys()][0]);
    expect(h.resources.filter((row) => row.kind === "vm")).toHaveLength(0);
  });

  it("sends only the create on a first attempt", async () => {
    await harness(NO_READS);
    const key = await serviceKey();
    let made: Response | undefined;
    const lines = await createLines(async () => { made = await imageCreate(key, undefined, "one-call-first"); });
    expect(made?.status).toBe(201);
    expect(providerCalls()).toEqual(["POST /v5/vms"]);
    expect(lines).toHaveLength(1);
    expect(lines[0]).toMatchObject({ ok: true, recovered: false, recoverMs: null, verifyImageMs: null, resizeMs: null });
    expect(typeof lines[0]!["createMs"]).toBe("number");
  });

  it("sends only the create for a request without an Idempotency-Key or an image", async () => {
    await harness(NO_READS);
    const key = await serviceKey();
    expect((await create(key, {})).status).toBe(201);
    expect(providerCalls()).toEqual(["POST /v5/vms"]);
  });

  it("with the large snapshot too, a create at the chat start size is one provider call", async () => {
    await harness({ createSwitches: { sizedImageServiceIds: [SERVICE], noReadsServiceIds: [SERVICE] } });
    const key = await serviceKey();
    const made = await imageCreate(key, LARGE_SHAPE, "one-call-everything");
    expect(made.status).toBe(201);
    expect(record(await made.json())["resources"]).toEqual(LARGE_SHAPE);
    expect(providerCalls()).toEqual(["POST /v5/vms"]);
  });

  it("reads the exact slug first on a retry, and recovers the VM instead of creating another", async () => {
    await harness(NO_READS);
    const key = await serviceKey();
    h.recordFault.before = 1;
    expect((await imageCreate(key, undefined, "one-call-retry")).status).toBe(503);
    expect(providerCalls()).toEqual(["POST /v5/vms"]);
    let retry: Response | undefined;
    const lines = await createLines(async () => { retry = await imageCreate(key, undefined, "one-call-retry"); });
    expect(retry?.status).toBe(201);
    expect(providerCalls()).toEqual(["POST /v5/vms", "GET /v5/vms/<slug>"]);
    expect(h.upstream.vms.size).toBe(1);
    expect(lines[0]).toMatchObject({ ok: true, recovered: true, createMs: null, verifyImageMs: null });
    expect(typeof lines[0]!["recoverMs"]).toBe("number");
  });

  it("reads the exact slug first on a retry of a create the provider refused, then creates once", async () => {
    await harness(NO_READS);
    const key = await serviceKey();
    h.upstream.fail("create", 400);
    expect((await imageCreate(key, undefined, "one-call-refused")).status).toBe(503);
    // The refused create is followed by its exact-slug read, as before: only a 404 there proves nothing was made.
    expect(providerCalls()).toEqual(["POST /v5/vms", "GET /v5/vms/<slug>"]);
    expect((await imageCreate(key, undefined, "one-call-refused")).status).toBe(201);
    expect(providerCalls()).toEqual(["POST /v5/vms", "GET /v5/vms/<slug>", "GET /v5/vms/<slug>", "POST /v5/vms"]);
    expect(h.upstream.vms.size).toBe(1);
  });

  it("recovers a first attempt's lost create answer by the read after it", async () => {
    await harness(NO_READS);
    const key = await serviceKey();
    h.upstream.faults.lostCreateResponses = 1;
    expect((await imageCreate(key)).status).toBe(201);
    expect(providerCalls()).toEqual(["POST /v5/vms", "GET /v5/vms/<slug>"]);
    expect(h.upstream.vms.size).toBe(1);
  });

  it("fails a create whose listed snapshot the provider no longer has, and records nothing", async () => {
    await harness(NO_READS);
    h.upstream.snapshots.delete(SMALL);
    const key = await serviceKey();
    expect((await imageCreate(key, undefined, "one-call-missing-image")).status).toBe(503);
    expect(imageReads()).toHaveLength(0);
    expect(h.upstream.vms.size).toBe(0);
    expect(h.resources.filter((row) => row.kind === "vm")).toHaveLength(0);
    // Once the snapshot is back the same key creates.
    seedSnapshots();
    expect((await imageCreate(key, undefined, "one-call-missing-image")).status).toBe(201);
    expect(h.upstream.vms.size).toBe(1);
  });

  it("deletes a VM the provider booted from another snapshot than the approved one, and records nothing", async () => {
    await harness(NO_READS);
    const key = await serviceKey();
    const provider = h.upstream.fetch;
    h.upstream.fetch = async (request) => {
      const answer = await provider(request);
      if (request.method !== "POST" || new URL(request.url).pathname !== "/v5/vms" || answer.status !== 201) return answer;
      return Response.json({ ...record(await answer.json()), snapshotId: "some-other-snapshot" }, { status: 201 });
    };
    expect((await imageCreate(key)).status).toBe(503);
    expect(h.upstream.vms.size).toBe(0);
    expect(h.resources.filter((row) => row.kind === "vm")).toHaveLength(0);
  });

  it("is off unless the caller's service is listed: both reads come before the create", async () => {
    await harness({ createSwitches: { noReadsServiceIds: ["some-other-service"] } });
    const key = await serviceKey();
    expect((await imageCreate(key)).status).toBe(201);
    expect(slugReads()).toHaveLength(1);
    expect(imageReads()).toHaveLength(1);
    expect(providerCalls().at(-1)).toBe("POST /v5/vms");
    expect(providerCalls()).toHaveLength(3);
  });
});
