import { beforeEach, describe, expect, mock, test } from "bun:test";
import type { AuthedUser } from "../services/vms/auth";

const user = {
  id: "user-run",
  isAnonymous: false,
  displayName: "Run User",
  primaryEmail: "run@example.com",
  billingCustomerType: "team",
  billingTeamId: "team-run",
  selectedTeamId: "team-run",
  teams: [],
  teamIds: ["team-run"],
  userBillingPlanId: null,
  billingPlanId: "pro",
  billingSeats: 1,
} satisfies AuthedUser;

let allocationRefusal: Response | null = null;
const enforceVmAllocationRateLimit = mock(async () => allocationRefusal);
const createRun = mock(async () => { throw new Error("allocation refusal must precede run persistence"); });
const launchQueuedCloudVmAttempts = mock(async () => {});
const repositoryModule = await import("../services/runs/repository");

mock.module("../services/vms/routeHelpers", () => ({
  withAuthedVmApiRoute: async (
    _request: Request,
    _route: string,
    _attributes: Record<string, unknown>,
    _failureLog: string,
    handler: (context: { user: AuthedUser }) => Promise<Response>,
  ) => handler({ user }),
  resolveVmProvisioningAccountScope: async () => ({
    ok: true,
    entitlements: {
      billingTeamId: "team-run",
      billingCustomerType: "team",
      planId: "pro",
      maxActiveVms: 5,
    },
  }),
  runAfterResponse: () => {},
  jsonResponse: (body: unknown, status = 200, headers: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } }),
  vmErrorResponse: (input: { error: string; status: number; message: string; action: string }) =>
    Response.json(input, { status: input.status }),
}));
mock.module("../services/vms/allocationRateLimit", () => ({ enforceVmAllocationRateLimit }));
mock.module("../services/runs/repository", () => ({
  ...repositoryModule,
  createRun,
  requestDigest: () => "sha256:fixture",
}));
mock.module("../services/runs/dogfood", () => ({ launchQueuedCloudVmAttempts }));

const route = await import("../app/api/runs/route");

function request(): Request {
  return new Request("https://cmux.test/api/runs", {
    method: "POST",
    headers: { "content-type": "application/json", "idempotency-key": "run-key" },
    body: JSON.stringify({
      source: { repository: "manaflow-ai/cmux", commit: "a".repeat(40) },
      recipe: "parallel-review",
      desiredAttempts: 32,
      provider: "cloud-vm",
      routing: { requestedProvider: "freestyle" },
    }),
  });
}

describe("Run create allocation admission", () => {
  beforeEach(() => {
    allocationRefusal = null;
    enforceVmAllocationRateLimit.mockClear();
    createRun.mockClear();
    launchQueuedCloudVmAttempts.mockClear();
  });

  test("allocation refusal precedes a 32-attempt Run", async () => {
    allocationRefusal = Response.json({ error: "vm_allocation_rate_limited" }, { status: 429 });

    const response = await route.POST(request());

    expect(response.status).toBe(429);
    expect(enforceVmAllocationRateLimit).toHaveBeenCalledWith(expect.objectContaining({
      route: "run.create",
      billingTeamId: "team-run",
    }));
    expect(createRun).not.toHaveBeenCalled();
    expect(launchQueuedCloudVmAttempts).not.toHaveBeenCalled();
  });
});
