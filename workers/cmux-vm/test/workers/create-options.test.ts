/**
 * Create options from the cmux Actions design (N2, N3, N4, N8, N10, N13):
 * sizes (base image plus grow, not atomic), run and auto-delete limits,
 * labels and the label filter, exec user and stdin, file mode, quota overrides.
 */
import { afterEach, describe, expect, it } from "vitest";
import { makeTenantPolicy, parseVmQuotas } from "../../src/policy.ts";
import { TenantId } from "../../src/lib/ids.ts";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TENANT_A = "team_alpha";

let h: Harness | undefined;
const harness = async () => {
  h = await makeHarness();
  return h;
};
afterEach(async () => {
  await h?.dispose();
  h = undefined;
});

const json = async (response: Response): Promise<Record<string, unknown>> => {
  const body: unknown = await response.json();
  return typeof body === "object" && body !== null ? Object.fromEntries(Object.entries(body)) : {};
};

const create = (t: Harness, key: string, body: unknown) => t.request("/v1/vms", bearer(key), { method: "POST", body });

describe("resources", () => {
  it("boots the largest base size inside the request, then grows to it", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    const response = await create(t, key, { resources: { vcpus: 12, memoryMib: 24576 } });

    expect(response.status).toBe(201);
    expect(await json(response)).toMatchObject({ resources: { vcpus: 12, memoryMib: 24576, diskMib: 65536 } });
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)[0]?.json).toMatchObject({ snapshotId: "freestyle/ubuntu-lg" });
    expect(t.upstream.callsTo("POST", /\/resize$/).map((call) => call.json)).toEqual([{ cpu: 12, memory: 24576 }]);
  });

  it("does not resize when a base size matches exactly", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    const response = await create(t, key, { resources: { vcpus: 2, memoryMib: 4096, diskMib: 16384 } });

    expect(response.status).toBe(201);
    expect(t.upstream.callsTo("POST", /\/resize$/)).toHaveLength(0);
  });

  it("deletes the new VM and answers 409 when growing fails", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:write"]);
    t.upstream.fail("resize", 409);

    const response = await create(t, key, { resources: { diskMib: 50000 } });

    expect(response.status).toBe(409);
    expect(t.upstream.vms.size).toBe(0);
    expect(t.resources.filter((row) => row.kind === "vm")).toHaveLength(0);
  });

  it("rejects sizes outside the allowed range", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:write"]);
    expect((await create(t, key, { resources: { vcpus: 1 } })).status).toBe(400);
    expect((await create(t, key, { resources: { memoryMib: 1_000_000 } })).status).toBe(400);
    expect(t.upstreamRequests).toHaveLength(0);
  });
});

describe("run and auto-delete limits", () => {
  it("passes maxRunSeconds and autoDeleteSeconds to the VM", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:write"]);

    expect((await create(t, key, { maxRunSeconds: 3600, autoDeleteSeconds: 86400 })).status).toBe(201);

    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)[0]?.json).toMatchObject({ maxRunSeconds: 3600, autoDeleteSeconds: 86400 });
  });
});

describe("labels", () => {
  it("stores labels with the VM and filters the list by them", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const ci = await json(await create(t, key, { labels: { role: "ci", "actions/run": "42" } }));
    await create(t, key, { labels: { role: "dev" } });

    expect(ci).toMatchObject({ labels: { role: "ci", "actions/run": "42" } });
    expect(t.resources.find((row) => row.cmuxId === ci.id)?.labels).toEqual({ role: "ci", "actions/run": "42" });
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)[0]?.json).not.toHaveProperty("labels");

    const filtered = await json(await t.request("/v1/vms?label=role%3Dci&label=actions%2Frun%3D42", bearer(key)));
    expect(filtered).toMatchObject({ items: [{ id: ci.id }] });
    expect(Array.isArray(filtered.items) ? filtered.items.length : -1).toBe(1);

    const read = await json(await t.request(`/v1/vms/${String(ci.id)}`, bearer(key)));
    expect(read.labels).toEqual({ role: "ci", "actions/run": "42" });
  });

  it("rejects bad label keys, values and counts", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["vm:write"]);
    const many = Object.fromEntries(Array.from({ length: 17 }, (_, index) => [`k${index}`, "v"]));
    for (const labels of [{ "Bad Key": "v" }, { role: "has space" }, many]) {
      expect((await create(t, key, { labels })).status).toBe(400);
    }
    expect(t.upstreamRequests).toHaveLength(0);
  });
});

describe("exec options and file mode", () => {
  it("passes linuxUser and stdin to the VM", async () => {
    const t = await harness();
    const { vmId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:exec"]);

    const response = await t.request(`/v1/vms/${vmId}/exec`, bearer(key), {
      method: "POST",
      body: { command: "cat", linuxUser: "agent", stdinBase64: btoa("hello"), timeoutMs: 300_000 },
    });

    expect(response.status).toBe(200);
    expect(t.upstream.callsTo("POST", /exec-await$/)[0]?.json).toEqual({
      command: "cat",
      linuxUser: "agent",
      stdin: btoa("hello"),
      timeoutMs: 300_000,
    });
  });

  it("writes a file with a mode", async () => {
    const t = await harness();
    const { vmId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:files"]);

    const response = await t.send(`/v1/vms/${vmId}/files/content?path=%2Fusr%2Flocal%2Fbin%2Fagent&mode=493`, bearer(key), "PUT", new Uint8Array([1]));

    expect(response.status).toBe(204);
    expect(t.upstream.callsTo("PUT", /fs\/write$/)[0]?.search.get("mode")).toBe("493");
  });
});

describe("quotas", () => {
  it("defaults to 20 live VMs and takes per-tenant overrides", () => {
    const quotas = parseVmQuotas('{"team_big": 50, "bad": "x", "neg": -1}');
    expect(quotas).toEqual({ team_big: 50 });
    const policy = makeTenantPolicy({ environment: "production", vmQuotas: quotas });
    expect(policy.maxVms(TenantId.make("team_any"))).toBe(20);
    expect(policy.maxVms(TenantId.make("team_big"))).toBe(50);
    expect(parseVmQuotas("not json")).toEqual({});
  });
});
