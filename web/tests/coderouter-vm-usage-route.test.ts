import { beforeEach, describe, expect, mock, test } from "bun:test";

const ownedVm = "0f4b1c2e-1111-4222-8333-444455556666";
const otherVm = "9f9f9f9f-2222-4333-8444-555566667777";
const zeroVm = "1a1a1a1a-3333-4444-8555-666677778888";
const destroyedVm = "2b2b2b2b-4444-4555-8666-777788889999";
const ready = {
  kind: "ready" as const,
  vmId: ownedVm,
  periodDays: 30,
  generatedAt: "2026-09-02T12:00:00.000Z",
  rateCardVersion: "2026-08-08",
  totals: {
    inputTokens: 1_000,
    cachedInputTokens: 200,
    outputTokens: 300,
    totalTokens: 1_300,
    apiEquivalentUsd: 4.25,
    pricedTokens: 1_300,
    unpricedTokens: 0,
  },
  daily: [{ day: "2026-09-02", totalTokens: 1_300, apiEquivalentUsd: 4.25 }],
};

let sessionResolution:
  | { ok: true; teamId: string; stackUserId: string }
  | { ok: false; response: Response } = {
    ok: true,
    teamId: "team-1",
    stackUserId: "user-1",
  };
let vmMetricsKind: "ready" | "unavailable" = "ready";
let machinesKind: "ready" | "unavailable" = "ready";
const vmMetricsCalls: Array<[string, string, string]> = [];
const machineMetricsCalls: Array<[string, string]> = [];
const captured: Array<Record<string, unknown>> = [];

const machines = [
  { vmId: ownedVm, displayName: "builder", destroyed: false, createdAt: "2026-08-01T00:00:00.000Z" },
  { vmId: zeroVm, displayName: null, destroyed: false, createdAt: "2026-08-02T00:00:00.000Z" },
  { vmId: destroyedVm, displayName: "old", destroyed: true, createdAt: "2026-07-01T00:00:00.000Z" },
];

mock.module("../services/coderouter/requestContext", () => ({
  resolveCoderouterUsageTeam: async () => sessionResolution,
}));
mock.module("../services/coderouter/teamMachines", () => ({
  findTeamMachine: async (teamId: string, vmId: string) =>
    teamId === "team-1"
      ? machines.find((machine) => machine.vmId === vmId.toLowerCase()) ?? null
      : null,
  listTeamMachines: async (teamId: string) => teamId === "team-1" ? machines : [],
  normalizeVmId: (value: string) => value.toLowerCase(),
}));
mock.module("../services/coderouter/vmMetrics", () => ({
  loadCoderouterVmMetrics: async (teamId: string, vmId: string, surface: string) => {
    vmMetricsCalls.push([teamId, vmId, surface]);
    return vmMetricsKind === "ready" ? { ...ready, vmId } : { kind: "unavailable" };
  },
  loadCoderouterTeamMachineMetrics: async (teamId: string, surface: string) => {
    machineMetricsCalls.push([teamId, surface]);
    return machinesKind === "ready"
      ? {
        kind: "ready",
        periodDays: 30,
        generatedAt: ready.generatedAt,
        rateCardVersion: ready.rateCardVersion,
        machines: [
          { vmId: "unknown-vm", totals: { ...ready.totals, totalTokens: 9_999_999 } },
          { vmId: ownedVm, totals: ready.totals },
          { vmId: destroyedVm, totals: { ...ready.totals, totalTokens: 10 } },
        ],
      }
      : { kind: "unavailable" };
  },
}));
mock.module("../services/coderouter/analytics", () => ({
  captureCoderouterEvent: (input: Record<string, unknown>) => {
    captured.push(input);
  },
}));
const routeTokens = new Map<string, { teamId: string; stackUserId: string; vmId: string | null }>([
  ["crt_bound", { teamId: "team-1", stackUserId: "user-1", vmId: ownedVm }],
  ["crt_cli", { teamId: "team-1", stackUserId: "user-1", vmId: null }],
  ["crt_foreign", { teamId: "team-2", stackUserId: "user-2", vmId: otherVm }],
]);
mock.module("../services/coderouter/repository", () => ({
  authenticateRouteToken: async (token: string) => routeTokens.get(token) ?? null,
}));

const { GET: getVmUsage } = await import("../app/api/coderouter/vm-usage/route");
const { GET: getTeamUsage } = await import(
  "../app/api/coderouter/vm-usage/team/route"
);
const { GET: getSelfUsage } = await import(
  "../app/api/coderouter/vm-usage/self/route"
);

const publicTotals = {
  inputTokens: 1_000,
  cachedInputTokens: 200,
  outputTokens: 300,
  totalTokens: 1_300,
  apiEquivalentUsd: 4.25,
};

describe("GET /api/coderouter/vm-usage", () => {
  beforeEach(() => {
    sessionResolution = { ok: true, teamId: "team-1", stackUserId: "user-1" };
    vmMetricsKind = "ready";
    machinesKind = "ready";
    vmMetricsCalls.length = 0;
    machineMetricsCalls.length = 0;
    captured.length = 0;
  });

  test("returns the session auth failure untouched", async () => {
    sessionResolution = {
      ok: false,
      response: Response.json({ error: "unauthorized" }, { status: 401 }),
    };
    const response = await getVmUsage(
      new Request(`https://cmux.test/api/coderouter/vm-usage?vmId=${ownedVm}`),
    );
    expect(response.status).toBe(401);
    expect(vmMetricsCalls).toEqual([]);
  });

  test("requires a vmId and hides machines outside the team", async () => {
    const missing = await getVmUsage(
      new Request("https://cmux.test/api/coderouter/vm-usage"),
    );
    expect(missing.status).toBe(400);
    expect(await missing.json()).toEqual({ error: "invalid_request" });

    const foreign = await getVmUsage(
      new Request(`https://cmux.test/api/coderouter/vm-usage?vmId=${otherVm}`),
    );
    expect(foreign.status).toBe(404);
    expect(foreign.headers.get("cache-control")).toBe("no-store");
    expect(await foreign.json()).toEqual({ error: "vm_not_found" });
    expect(vmMetricsCalls).toEqual([]);
  });

  test("serves the fixed per-machine contract", async () => {
    const response = await getVmUsage(
      new Request(
        `https://cmux.test/api/coderouter/vm-usage?vmId=${ownedVm.toUpperCase()}`,
      ),
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("content-type")).toContain("application/json");
    expect(await response.json()).toEqual({
      vmId: ownedVm,
      periodDays: 30,
      kind: "ready",
      asOf: "2026-09-02T12:00:00.000Z",
      totals: publicTotals,
      days: [{ day: "2026-09-02", totalTokens: 1_300, apiEquivalentUsd: 4.25 }],
    });
    expect(vmMetricsCalls).toEqual([["team-1", ownedVm, "vm_usage_api"]]);
  });

  test("fails closed to an unavailable body with the same shape", async () => {
    vmMetricsKind = "unavailable";
    const response = await getVmUsage(
      new Request(`https://cmux.test/api/coderouter/vm-usage?vmId=${ownedVm}`),
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      vmId: ownedVm,
      periodDays: 30,
      kind: "unavailable",
      asOf: null,
      totals: null,
      days: [],
    });
  });
});

describe("GET /api/coderouter/vm-usage/team", () => {
  beforeEach(() => {
    sessionResolution = { ok: true, teamId: "team-1", stackUserId: "user-1" };
    machinesKind = "ready";
    machineMetricsCalls.length = 0;
  });

  test("joins usage with owned machines and drops unknown ids", async () => {
    const response = await getTeamUsage(
      new Request("https://cmux.test/api/coderouter/vm-usage/team"),
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.json();
    expect(body).toEqual({
      teamId: "team-1",
      periodDays: 30,
      kind: "ready",
      asOf: "2026-09-02T12:00:00.000Z",
      machines: [
        { vmId: ownedVm, displayName: "builder", totals: publicTotals },
        {
          vmId: destroyedVm,
          displayName: "old",
          totals: { ...publicTotals, totalTokens: 10 },
        },
        {
          vmId: zeroVm,
          displayName: null,
          totals: {
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            totalTokens: 0,
            apiEquivalentUsd: 0,
          },
        },
      ],
    });
    expect(JSON.stringify(body)).not.toContain("unknown-vm");
    expect(JSON.stringify(body)).not.toContain("pricedTokens");
    expect(machineMetricsCalls).toEqual([["team-1", "team_machines_api"]]);
  });

  test("returns an empty machine list when the Endpoint is unavailable", async () => {
    machinesKind = "unavailable";
    const response = await getTeamUsage(
      new Request("https://cmux.test/api/coderouter/vm-usage/team"),
    );
    expect(await response.json()).toEqual({
      teamId: "team-1",
      periodDays: 30,
      kind: "unavailable",
      asOf: null,
      machines: [],
    });
  });

  test("returns the session auth failure untouched", async () => {
    sessionResolution = {
      ok: false,
      response: Response.json({ error: "forbidden" }, { status: 403 }),
    };
    const response = await getTeamUsage(
      new Request("https://cmux.test/api/coderouter/vm-usage/team"),
    );
    expect(response.status).toBe(403);
    expect(machineMetricsCalls).toEqual([]);
  });
});

describe("GET /api/coderouter/vm-usage/self", () => {
  beforeEach(() => {
    vmMetricsKind = "ready";
    vmMetricsCalls.length = 0;
    captured.length = 0;
  });

  test("rejects the placeholder bearer without an edge-injected token", async () => {
    const response = await getSelfUsage(
      new Request("https://cmux.test/api/coderouter/vm-usage/self", {
        headers: { authorization: "Bearer cmux-vm-edge-placeholder" },
      }),
    );
    expect(response.status).toBe(401);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      error: "unauthorized",
      message: "Sign in with `cr login` and retry.",
      retryable: false,
    });
    expect(captured).toEqual([{
      event: "coderouter_auth_rejected",
      properties: { surface: "vm_usage", reason: "missing_route_token" },
    }]);
  });

  test("rejects a bound token presented for another machine", async () => {
    const response = await getSelfUsage(
      new Request("https://cmux.test/api/coderouter/vm-usage/self", {
        headers: {
          authorization: "Bearer cmux-vm-edge-placeholder",
          "x-coderouter-route-token": "crt_bound",
          "x-cmux-vm-id": otherVm,
        },
      }),
    );
    expect(response.status).toBe(401);
    expect((await response.json()).error).toBe("unauthorized");
    expect(captured[0]?.properties).toEqual({
      surface: "vm_usage",
      reason: "vm_mismatch",
    });
    expect(vmMetricsCalls).toEqual([]);
  });

  test("refuses unbound CLI tokens", async () => {
    const response = await getSelfUsage(
      new Request("https://cmux.test/api/coderouter/vm-usage/self", {
        headers: { authorization: "Bearer crt_cli" },
      }),
    );
    expect(response.status).toBe(403);
    expect((await response.json()).error).toBe("vm_bound_token_required");
    expect(vmMetricsCalls).toEqual([]);
  });

  test("serves the bound machine's usage through the edge headers", async () => {
    const response = await getSelfUsage(
      new Request("https://cmux.test/api/coderouter/vm-usage/self", {
        headers: {
          authorization: "Bearer cmux-vm-edge-placeholder",
          "x-coderouter-route-token": "crt_bound",
          "x-cmux-vm-id": ownedVm,
        },
      }),
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      vmId: ownedVm,
      periodDays: 30,
      kind: "ready",
      totals: publicTotals,
    });
    expect(vmMetricsCalls).toEqual([["team-1", ownedVm, "vm_self_api"]]);
  });

  test("hides a bound machine the token's team no longer owns", async () => {
    const response = await getSelfUsage(
      new Request("https://cmux.test/api/coderouter/vm-usage/self", {
        headers: {
          "x-coderouter-route-token": "crt_foreign",
          "x-cmux-vm-id": otherVm,
        },
      }),
    );
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "vm_not_found" });
  });
});
