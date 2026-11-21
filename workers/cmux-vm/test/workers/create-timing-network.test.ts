/**
 * Where a create's time goes, and two ways it spends less of it.
 *
 * A Cloud create made four provider calls in a row (exact-slug recovery read, boot image read, create, resize) and
 * the platform then attached the VM to its mesh with a fifth and sixth. Here: the two reads before the create run
 * together; a create may name the mesh to join, so the VM is on its network from the provider's create and the later
 * attach makes no provider attach call; and one vm_create line (one vm_start line for a wake) says where the time went.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";
import { enrollBody, makeInstallKey } from "../support/mesh-signing.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
const TEAM = "team_alpha";
const SNAPSHOT = "operator-immutable-image-fixture";
const IMAGE = { id: "cloud-standard", revision: "r1" };
const CATALOG = [{ ...IMAGE, displayName: "Cloud standard", snapshotId: SNAPSHOT, services: ["cloud-driver"] }];
const DEVICE_KEY = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=";

let h: Harness;
const harness = async (options: HarnessOptions = {}) => {
  h = await makeHarness({ bootImages: JSON.stringify(CATALOG), ...options });
  h.upstream.snapshots.set(SNAPSHOT, { id: SNAPSHOT, sourceVmId: "operator-image-source", autoDeleteSeconds: null });
  return h;
};
beforeEach(async () => { await harness(); });
afterEach(async () => { await h.dispose(); });

const record = (v: unknown): Record<string, unknown> => (typeof v === "object" && v !== null ? Object.fromEntries(Object.entries(v)) : {});
const create = (key: string, body: unknown, requestKey?: string, extra: Record<string, string> = {}) =>
  h.request("/v1/vms", { ...bearer(key), ...extra, ...(requestKey === undefined ? {} : { "Idempotency-Key": requestKey }) }, { method: "POST", body });
const providerCreates = () => h.upstream.callsTo("POST", /^\/v5\/vms$/);
const providerAttaches = () => h.upstream.callsTo("PUT", /^\/v5\/vms\/[^/]+\/networks$/);
const upstreamIdOf = (vmId: string) => String(h.resources.find((row) => row.cmuxId === vmId)?.upstreamId);
const reachable = (vmId: string) => [...h.mesh.rules.values()].some((rule) => rule.destination["vmId"] === upstreamIdOf(vmId));

/** A mesh with one device allowed to reach every VM, so an attached VM needs a provider rule to be reachable. */
const meshWithDevice = async () => {
  const key = await h.addKey(TEAM, ALL_SCOPES);
  const made = await h.request("/v1/meshes", bearer(key), { method: "POST", body: {} });
  expect(made.status).toBe(201);
  const meshId = String(record(await made.json())["id"]);
  const install = await makeInstallKey();
  const enrolled = await h.request(`/v1/meshes/${meshId}/devices`, bearer(key), { method: "POST", body: await enrollBody(install, meshId, { name: "laptop", wgPublicKey: DEVICE_KEY }) });
  expect(enrolled.status).toBe(201);
  const acl = await h.request(`/v1/meshes/${meshId}/acl`, bearer(key), { method: "PUT", body: { expectedVersion: 0, rules: [{ src: ["device:*"], dst: ["vm:*"], allow: ["tcp:22"] }] } });
  expect(acl.status).toBe(200);
  return { key, meshId, networkId: String(h.resources.find((row) => row.cmuxId === meshId)?.upstreamId) };
};

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

describe("the provider reads before a create", () => {
  const imageKey = () => h.addServiceKey({ id: "cloud-driver", scopes: ["vm:read", "vm:write"], labels: { role: "cloud" } });
  const imageCreate = (key: string, requestKey?: string) => create(key, { image: IMAGE, labels: { role: "cloud" } }, requestKey, { "x-cmux-team-id": TEAM });

  it("reads the boot image while the exact-slug recovery read is still in flight", async () => {
    const key = await imageKey();
    const provider = h.upstream.fetch;
    let recovering = false;
    let overlapped: boolean | null = null;
    h.upstream.fetch = async (request) => {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname.startsWith("/v5/snapshots/")) overlapped ??= recovering;
      if (request.method === "GET" && url.pathname.startsWith("/v5/vms/cmux-vm-") && overlapped === null) {
        // A provider read takes 0.45 to 1.9 s; 200 ms here is long enough for the other read to start.
        recovering = true;
        await new Promise((resolve) => setTimeout(resolve, 200));
        recovering = false;
      }
      return provider(request);
    };
    expect((await imageCreate(key)).status).toBe(201);
    expect(overlapped).toBe(true);
    expect(providerCreates()).toHaveLength(1);
  });

  it("still refuses the create, sending nothing, when the boot image cannot be read", async () => {
    const key = await imageKey();
    h.upstream.fail("getSnapshot", 500);
    expect((await imageCreate(key)).status).toBe(503);
    expect(providerCreates()).toHaveLength(0);
    expect(h.upstream.vms.size).toBe(0);
  });

  it("still answers with a recovered VM when its boot image can no longer be read", async () => {
    const key = await imageKey();
    h.upstream.faults.lostCreateResponses = 1;
    const requestKey = "create-timing-recovered-image";
    expect([201, 503]).toContain((await imageCreate(key, requestKey)).status);
    h.upstream.fail("getSnapshot", 500, 5);
    expect((await imageCreate(key, requestKey)).status).toBe(201);
    expect(providerCreates()).toHaveLength(1);
    expect(h.upstream.vms.size).toBe(1);
  });

  it("still fails on a recovery read the provider did not answer, without sending a create", async () => {
    const key = await imageKey();
    h.upstream.fail("get", 500);
    expect((await imageCreate(key)).status).toBe(503);
    expect(providerCreates()).toHaveLength(0);
  });
});

describe("a create that names the mesh to join", () => {
  it("sends no network when the request names none", async () => {
    const { key } = await meshWithDevice();
    expect((await create(key, {})).status).toBe(201);
    expect(record(providerCreates()[0]?.json)).not.toHaveProperty("networks");
    expect(h.mesh.vmNetworks.size).toBe(0);
  });

  it("puts the VM on the mesh's network in the provider create, and the later attach makes no provider attach call", async () => {
    const { key, meshId, networkId } = await meshWithDevice();
    const made = await create(key, { meshId });
    expect(made.status).toBe(201);
    const vmId = String(record(await made.json())["id"]);
    expect(record(providerCreates()[0]?.json)["networks"]).toEqual([{ vpc: networkId }]);
    expect(h.mesh.vmNetworks.get(upstreamIdOf(vmId))).toBe(networkId);
    // Not yet reachable: only the attach applies the mesh's rules.
    expect(reachable(vmId)).toBe(false);

    const lines = await linesOf("mesh_vm_attach", async () => {
      const attached = await h.request(`/v1/meshes/${meshId}/vms/${vmId}`, bearer(key), { method: "PUT" });
      expect(attached.status).toBe(200);
      const member = record(await attached.json());
      expect(member).toMatchObject({ meshId, vmId });
      expect(String(member["ipv4"])).toMatch(/^10\.\d+\.\d+\.\d+$/u);
    });
    expect(providerAttaches()).toHaveLength(0);
    expect(reachable(vmId)).toBe(true);
    expect(lines).toHaveLength(1);
    expect(lines[0]).not.toHaveProperty("upstreamAttachMs");
    // And the member is the one the mesh lists and reads.
    const read = await h.request(`/v1/meshes/${meshId}/vms/${vmId}`, bearer(key));
    expect(read.status).toBe(200);
  });

  it("falls back to the provider attach when the create's answer does not show the VM on the network", async () => {
    const { key, meshId, networkId } = await meshWithDevice();
    h.upstream.faults.hideCreateNetworks = true;
    const made = await create(key, { meshId });
    expect(made.status).toBe(201);
    const vmId = String(record(await made.json())["id"]);
    const attached = await h.request(`/v1/meshes/${meshId}/vms/${vmId}`, bearer(key), { method: "PUT" });
    expect(attached.status).toBe(200);
    expect(providerAttaches().map((call) => call.json)).toEqual([{ networks: [{ vpc: networkId }] }]);
    expect(reachable(vmId)).toBe(true);
  });

  it("does not take the VM as joined when the create's answer names its networks two different ways", async () => {
    const { key, meshId, networkId } = await meshWithDevice();
    h.upstream.faults.splitCreateNetworks = true;
    const made = await create(key, { meshId });
    expect(made.status).toBe(201);
    const vmId = String(record(await made.json())["id"]);
    const attached = await h.request(`/v1/meshes/${meshId}/vms/${vmId}`, bearer(key), { method: "PUT" });
    expect(attached.status).toBe(200);
    expect(providerAttaches().map((call) => call.json)).toEqual([{ networks: [{ vpc: networkId }] }]);
  });

  it("answers a finished create again under its key from a caller the mesh checks would now refuse", async () => {
    const { key, meshId } = await meshWithDevice();
    const requestKey = "create-timing-mesh-replay";
    const made = await create(key, { meshId }, requestKey);
    expect(made.status).toBe(201);
    const vmId = String(record(await made.json())["id"]);
    // The same team's key without mesh:write: a new create naming the mesh is refused, a finished one is answered.
    const writeOnly = await h.addKey(TEAM, ["vm:read", "vm:write"]);
    expect((await create(writeOnly, { meshId }, "create-timing-mesh-replay-2")).status).toBe(403);
    const again = await create(writeOnly, { meshId }, requestKey);
    expect([200, 201]).toContain(again.status);
    expect(String(record(await again.json())["id"])).toBe(vmId);
    expect(providerCreates()).toHaveLength(1);
  });

  it("needs mesh:write and the caller's own mesh before anything is created", async () => {
    const { meshId } = await meshWithDevice();
    const before = h.upstreamRequests.length;
    const writeOnly = await h.addKey(TEAM, ["vm:write"]);
    expect((await create(writeOnly, { meshId })).status).toBe(403);
    const other = await h.addKey("team_bravo", ALL_SCOPES);
    expect((await create(other, { meshId })).status).toBe(404);
    const own = await h.addKey(TEAM, ALL_SCOPES);
    expect((await create(own, { meshId: "mesh_not-an-id" })).status).toBe(400);
    expect((await create(own, { meshId: `mesh_${"0".repeat(26)}` })).status).toBe(404);
    expect(h.upstreamRequests.length).toBe(before);
    expect(h.resources.filter((row) => row.kind === "vm")).toHaveLength(0);
  });

  it("refuses the same Idempotency-Key with another mesh, and recovers a lost create onto the same mesh once", async () => {
    const { key, meshId, networkId } = await meshWithDevice();
    h.upstream.faults.lostCreateResponses = 1;
    const requestKey = "create-timing-mesh-recovery";
    expect([201, 503]).toContain((await create(key, { meshId }, requestKey)).status);
    expect((await create(key, {}, requestKey)).status).toBe(409);
    const retry = await create(key, { meshId }, requestKey);
    expect(retry.status).toBe(201);
    const vmId = String(record(await retry.json())["id"]);
    expect(providerCreates()).toHaveLength(1);
    expect(h.upstream.vms.size).toBe(1);
    expect(h.mesh.vmNetworks.get(upstreamIdOf(vmId))).toBe(networkId);
    const attached = await h.request(`/v1/meshes/${meshId}/vms/${vmId}`, bearer(key), { method: "PUT" });
    expect(attached.status).toBe(200);
    expect(providerAttaches()).toHaveLength(0);
    expect(reachable(vmId)).toBe(true);
  });

  it("leaves a deleted VM out of the mesh", async () => {
    const { key, meshId } = await meshWithDevice();
    const vmId = String(record(await (await create(key, { meshId })).json())["id"]);
    expect((await h.request(`/v1/vms/${vmId}`, bearer(key), { method: "DELETE" })).status).toBe(204);
    expect((await h.request(`/v1/meshes/${meshId}/vms/${vmId}`, bearer(key))).status).toBe(404);
  });
});

describe("the vm_create and vm_start lines", () => {
  it("names each provider call of a create, the provider's own timings and the total", async () => {
    const key = await h.addKey(TEAM, ["vm:write"]);
    h.upstream.faults.createDebug = { totalMs: 13_250, timingsMs: { schedule: 120, boot: 9_800, "not a number": "x" }, note: "ignored" };
    let vmId = "";
    const lines = await linesOf("vm_create", async () => {
      const made = await create(key, { resources: { vcpus: 8, memoryMib: 16384, diskMib: 131072 } });
      expect(made.status).toBe(201);
      vmId = String(record(await made.json())["id"]);
    });
    expect(lines).toHaveLength(1);
    const line = lines[0]!;
    expect(line).toMatchObject({ event: "vm_create", vmId, ok: true, recovered: false, verifyImageMs: null, meshAtCreate: false, providerTotalMs: 13_250, providerTimingsMs: { schedule: 120, boot: 9_800 } });
    for (const field of ["preMs", "recoverMs", "createMs", "resizeMs", "recordMs", "totalMs"]) expect(Number(line[field]), field).toBeGreaterThanOrEqual(0);
    expect(typeof line["resizeMs"]).toBe("number");
    expect(Number(line["totalMs"])).toBeGreaterThanOrEqual(Number(line["createMs"]));
    expect(JSON.stringify(line)).not.toContain(TEAM);
    expect(JSON.stringify(line)).not.toContain(upstreamIdOf(vmId));
  });

  it("says a create needed no resize, and that a retry recovered the VM instead of creating it", async () => {
    const key = await h.addKey(TEAM, ["vm:write"]);
    // The VM is made upstream but its ownership row is not written: the retry finds it by its exact slug.
    h.recordFault.before = 1;
    const lines = await linesOf("vm_create", async () => {
      expect((await create(key, {}, "create-timing-log-recovery")).status).toBe(503);
      expect((await create(key, {}, "create-timing-log-recovery")).status).toBe(201);
    });
    expect(lines).toHaveLength(2);
    expect(lines[0]).toMatchObject({ ok: false, recovered: false, resizeMs: null });
    expect(typeof lines[0]!["createMs"]).toBe("number");
    expect(lines[1]).toMatchObject({ ok: true, recovered: true, createMs: null, recoverAfterMs: null, resizeMs: null, providerTotalMs: null, providerTimingsMs: null, vmId: lines[0]!["vmId"] });
    expect(typeof lines[1]!["recoverMs"]).toBe("number");
    expect(providerCreates()).toHaveLength(1);
  });

  it("says a create whose answer was lost recovered the VM by its slug afterwards", async () => {
    const key = await h.addKey(TEAM, ["vm:write"]);
    h.upstream.faults.lostCreateResponses = 1;
    const lines = await linesOf("vm_create", async () => { expect((await create(key, {})).status).toBe(201); });
    expect(lines).toHaveLength(1);
    expect(lines[0]).toMatchObject({ ok: true, recovered: true });
    expect(typeof lines[0]!["createMs"]).toBe("number");
    expect(typeof lines[0]!["recoverAfterMs"]).toBe("number");
  });

  it("logs nothing for a create refused before it reached the provider", async () => {
    const key = await h.addKey(TEAM, ["vm:read"]);
    const lines = await linesOf("vm_create", async () => { expect((await create(key, {})).status).toBe(403); });
    expect(lines).toHaveLength(0);
  });

  it("times a start and a resume, with the state a resume read first", async () => {
    const key = await h.addKey(TEAM, ["vm:write"]);
    const stopped = h.addVm(TEAM, "stopped");
    const paused = h.addVm(TEAM, "paused");
    const lines = await linesOf("vm_start", async () => {
      expect((await h.request(`/v1/vms/${stopped.vmId}/start`, bearer(key), { method: "POST" })).status).toBe(200);
      expect((await h.request(`/v1/vms/${paused.vmId}/resume`, bearer(key), { method: "POST" })).status).toBe(200);
    });
    expect(lines).toHaveLength(2);
    expect(lines[0]).toMatchObject({ event: "vm_start", vmId: stopped.vmId, route: "start", stateBefore: null, stateAfter: "running", ok: true });
    expect(lines[1]).toMatchObject({ event: "vm_start", vmId: paused.vmId, route: "resume", stateBefore: "paused", stateAfter: "running", ok: true });
    for (const line of lines) {
      expect(Number(line["startMs"])).toBeGreaterThanOrEqual(0);
      expect(Number(line["totalMs"])).toBeGreaterThanOrEqual(Number(line["startMs"]));
    }
  });

  it("logs a start the provider refused, and nothing for a VM the caller does not own", async () => {
    const key = await h.addKey(TEAM, ["vm:write"]);
    const vm = h.addVm(TEAM, "stopped");
    h.upstream.fail("start", 409);
    const lines = await linesOf("vm_start", async () => {
      expect((await h.request(`/v1/vms/${vm.vmId}/start`, bearer(key), { method: "POST" })).status).toBe(409);
      expect((await h.request(`/v1/vms/${h.addVm("team_bravo").vmId}/start`, bearer(key), { method: "POST" })).status).toBe(404);
    });
    expect(lines).toHaveLength(1);
    expect(lines[0]).toMatchObject({ vmId: vm.vmId, route: "start", ok: false, stateAfter: null });
  });
});
