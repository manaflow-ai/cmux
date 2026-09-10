import { beforeEach, describe, expect, mock, test } from "bun:test";
import { vmSelfResponse } from "../services/vms/selfDiscovery";

// GET /api/vm/self: a guest process learns which machine it is and which
// machines its team has. The only credential is the VM-bound route token the
// edge injects; the guest's own bearer is the public placeholder.

const selfVm = "0f4b1c2e-1111-4222-8333-444455556666";
const siblingVm = "9f9f9f9f-2222-4333-8444-555566667777";
const destroyedVm = "2b2b2b2b-4444-4555-8666-777788889999";
const unaddressedVm = "3c3c3c3c-5555-4666-8777-888899990000";
const foreignVm = "4d4d4d4d-6666-4777-8888-999900001111";

const machines = [
  { vmId: siblingVm, providerVmId: "fs-sibling", displayName: null, slug: "quiet-teal-otter", status: "paused", destroyed: false, createdAt: "2026-09-02T00:00:00.000Z" },
  { vmId: selfVm, providerVmId: "fs-self", displayName: "builder", slug: "sleepy-red-fox", status: "running", destroyed: false, createdAt: "2026-09-01T00:00:00.000Z" },
  { vmId: destroyedVm, providerVmId: "fs-old", displayName: "old", slug: null, status: "destroyed", destroyed: true, createdAt: "2026-07-01T00:00:00.000Z" },
  { vmId: unaddressedVm, providerVmId: null, displayName: null, slug: null, status: "provisioning", destroyed: false, createdAt: "2026-09-03T00:00:00.000Z" },
];

let listFailure: Error | null = null;
const listCalls: string[] = [];
const findCalls: Array<[string, string]> = [];
// A live row the capped list never returns: the self lookup must still find it.
const uncapped = { vmId: foreignVm, providerVmId: "fs-uncapped", displayName: null, slug: "old-grey-heron", status: "running", destroyed: false, createdAt: "2020-01-01T00:00:00.000Z" };
mock.module("../services/coderouter/teamMachines", () => ({
  findTeamMachine: async (teamId: string, vmId: string) => {
    findCalls.push([teamId, vmId]);
    if (listFailure) throw listFailure;
    if (teamId === "team-2" && vmId === foreignVm) return uncapped;
    return teamId === "team-1" ? machines.find((machine) => machine.vmId === vmId) ?? null : null;
  },
  listTeamMachines: async (teamId: string, options?: { liveOnly?: boolean }) => {
    listCalls.push(teamId);
    if (listFailure) throw listFailure;
    expect(options).toEqual({ liveOnly: true });
    return teamId === "team-1" ? machines : [];
  },
}));
const routeTokens = new Map<string, { teamId: string; stackUserId: string; vmId: string | null }>([
  ["crt_bound", { teamId: "team-1", stackUserId: "user-1", vmId: selfVm }],
  ["crt_cli", { teamId: "team-1", stackUserId: "user-1", vmId: null }],
  ["crt_foreign", { teamId: "team-2", stackUserId: "user-2", vmId: foreignVm }],
]);
mock.module("../services/coderouter/repository", () => ({
  authenticateRouteToken: async (token: string) => routeTokens.get(token) ?? null,
}));

const { GET } = await import("../app/api/vm/self/route");

const edgeRequest = (token: string, vmId: string) =>
  new Request("https://cmux.test/api/vm/self", {
    headers: {
      authorization: "Bearer cmux-vm-edge-placeholder",
      "x-coderouter-route-token": token,
      "x-cmux-vm-id": vmId,
    },
  });

describe("GET /api/vm/self", () => {
  beforeEach(() => {
    listFailure = null;
    listCalls.length = 0;
    findCalls.length = 0;
  });

  test("rejects the placeholder bearer without an edge-injected token", async () => {
    const response = await GET(
      new Request("https://cmux.test/api/vm/self", {
        headers: { authorization: "Bearer cmux-vm-edge-placeholder" },
      }),
    );
    expect(response.status).toBe(401);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect((await response.json()).error).toBe("unauthorized");
    expect(listCalls).toEqual([]);
  });

  test("rejects a bound token whose vm header names another machine", async () => {
    const response = await GET(edgeRequest("crt_bound", siblingVm));
    expect(response.status).toBe(401);
    expect(listCalls).toEqual([]);
  });

  test("refuses unbound CLI tokens", async () => {
    const response = await GET(
      new Request("https://cmux.test/api/vm/self", { headers: { authorization: "Bearer crt_cli" } }),
    );
    expect(response.status).toBe(403);
    expect((await response.json()).error).toBe("vm_bound_token_required");
    expect(listCalls).toEqual([]);
  });

  test("serves the machine and its live team siblings, self marked", async () => {
    const response = await GET(edgeRequest("crt_bound", selfVm));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.json();
    expect(body).toEqual({
      schema: 1,
      machine: {
        id: "fs-self",
        vmId: selfVm,
        name: "builder",
        displayName: "builder",
        slug: "sleepy-red-fox",
        status: "running",
        createdAt: "2026-09-01T00:00:00.000Z",
        self: true,
      },
      team: { id: "team-1" },
      machines: [
        {
          id: "fs-sibling",
          vmId: siblingVm,
          name: "quiet-teal-otter",
          displayName: null,
          slug: "quiet-teal-otter",
          status: "paused",
          createdAt: "2026-09-02T00:00:00.000Z",
          self: false,
        },
        {
          id: "fs-self",
          vmId: selfVm,
          name: "builder",
          displayName: "builder",
          slug: "sleepy-red-fox",
          status: "running",
          createdAt: "2026-09-01T00:00:00.000Z",
          self: true,
        },
      ],
    });
    // Destroyed and not-yet-addressed rows never leak; nothing secret does either.
    const text = JSON.stringify(body);
    expect(text).not.toContain(destroyedVm);
    expect(text).not.toContain(unaddressedVm);
    expect(text).not.toContain("crt_");
    expect(text).not.toContain("user-1");
    expect(listCalls).toEqual(["team-1"]);
  });

  test("finds the caller by id even when the capped team list omits it", async () => {
    const response = await GET(edgeRequest("crt_foreign", foreignVm));
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.machine).toMatchObject({ id: "fs-uncapped", name: "old-grey-heron", self: true });
    expect(body.machines).toEqual([body.machine]);
    expect(findCalls).toEqual([["team-2", foreignVm]]);
  });

  test("answers 404 when the bound row is gone", async () => {
    routeTokens.set("crt_gone", { teamId: "team-1", stackUserId: "user-1", vmId: destroyedVm });
    const destroyed = await GET(edgeRequest("crt_gone", destroyedVm));
    expect(destroyed.status).toBe(404);
    expect((await destroyed.json()).error).toBe("vm_not_found");
    routeTokens.set("crt_missing", { teamId: "team-1", stackUserId: "user-1", vmId: "5e5e5e5e-7777-4888-8999-000011112222" });
    const missing = await GET(edgeRequest("crt_missing", "5e5e5e5e-7777-4888-8999-000011112222"));
    expect(missing.status).toBe(404);
  });

  test("fails closed with a retryable 503 when the lookup is unavailable", async () => {
    listFailure = new Error("rds down");
    const response = await GET(edgeRequest("crt_bound", selfVm));
    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("5");
    expect((await response.json()).retryable).toBe(true);
  });
});

describe("vmSelfResponse", () => {
  test("names a machine by displayName, then slug, then provider id", () => {
    const a = { vmId: "a", providerVmId: "fs-a", displayName: "  ", slug: null, status: "running", destroyed: false, createdAt: "2026-01-02T00:00:00.000Z" };
    const b = { vmId: "b", providerVmId: "fs-b", displayName: null, slug: null, status: "running", destroyed: false, createdAt: "2026-01-01T00:00:00.000Z" };
    const body = vmSelfResponse({ teamId: "t", vmId: "b" }, b, [a, b]);
    expect(body?.machines.map((machine) => machine.name)).toEqual(["  ", "fs-b"]);
    expect(body?.machine.id).toBe("fs-b");
    // The own row is never listed twice and a mis-bound self is refused.
    expect(body?.machines.filter((machine) => machine.self)).toHaveLength(1);
    expect(vmSelfResponse({ teamId: "t", vmId: "b" }, a, [a, b])).toBeNull();
  });
});
