/**
 * The published lifecycle endpoints that S2 implements. Until then each one
 * already enforces its scope and tenant isolation, then answers 501.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const bearer = (token: string) => ({ authorization: `Bearer ${token}` });
const ACTIONS = ["start", "stop", "pause", "resume"] as const;

let h: Harness;
beforeEach(async () => {
  h = await makeHarness();
});
afterEach(async () => {
  await h.dispose();
});

const vmRequests = (vmId: string) => [
  ...ACTIONS.map((action) => ({ path: `/v1/vms/${vmId}/${action}`, method: "POST", body: undefined })),
  { path: `/v1/vms/${vmId}/fork`, method: "POST", body: {} },
  { path: `/v1/vms/${vmId}`, method: "DELETE", body: undefined },
];

describe("lifecycle endpoints on a specific VM", () => {
  it("return 404 to another tenant, even with vm:write", async () => {
    const { vmId } = h.addVm("team_alpha");
    const keyB = await h.addKey("team_bravo", ["vm:read", "vm:write"]);
    for (const request of vmRequests(vmId)) {
      const response = await h.request(request.path, bearer(keyB), request);
      expect({ path: request.path, status: response.status }).toEqual({ path: request.path, status: 404 });
    }
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("return 403 without vm:write", async () => {
    const { vmId } = h.addVm("team_alpha");
    const readOnly = await h.addKey("team_alpha", ["vm:read"]);
    for (const request of vmRequests(vmId)) {
      const response = await h.request(request.path, bearer(readOnly), request);
      expect({ path: request.path, status: response.status }).toEqual({ path: request.path, status: 403 });
    }
  });

  it("return 501 to the owner until implemented", async () => {
    const { vmId } = h.addVm("team_alpha");
    const key = await h.addKey("team_alpha", ["vm:write"]);
    for (const request of vmRequests(vmId)) {
      const response = await h.request(request.path, bearer(key), request);
      expect({ path: request.path, status: response.status }).toEqual({ path: request.path, status: 501 });
    }
    expect(h.upstreamRequests).toHaveLength(0);
  });
});

describe("tenant-wide endpoints", () => {
  it("create needs vm:write and list needs vm:read, then answer 501", async () => {
    const none = await h.addKey("team_alpha", ["snapshot:*"]);
    const both = await h.addKey("team_alpha", ["vm:read", "vm:write"]);
    expect((await h.request("/v1/vms", bearer(none), { method: "POST", body: {} })).status).toBe(403);
    expect((await h.request("/v1/vms", bearer(none))).status).toBe(403);
    expect((await h.request("/v1/vms", bearer(both), { method: "POST", body: {} })).status).toBe(501);
    expect((await h.request("/v1/vms?limit=10", bearer(both))).status).toBe(501);
  });

  it("rejects a create payload that names a non-cmux snapshot id", async () => {
    const key = await h.addKey("team_alpha", ["vm:write"]);
    const response = await h.request("/v1/vms", bearer(key), { method: "POST", body: { snapshotId: "sc-upstream-id" } });
    expect(response.status).toBe(400);
  });
});
