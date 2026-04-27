import { beforeEach, describe, expect, mock, test } from "bun:test";

const getUser = mock(async () => null);
const runVmWorkflow = mock(async () => {
  throw new Error("unauthenticated VM routes must not reach the VM workflow");
});
const createVm = mock(() => ({ workflow: "create" }));
const listUserVms = mock(() => ({ workflow: "list" }));
const destroyVm = mock(() => ({ workflow: "destroy" }));
const execVm = mock(() => ({ workflow: "exec" }));
const openAttachEndpoint = mock(() => ({ workflow: "attach" }));
const openSshEndpoint = mock(() => ({ workflow: "ssh" }));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
}));

mock.module("../services/vms/workflows", () => ({
  createVm,
  destroyVm,
  execVm,
  listUserVms,
  openAttachEndpoint,
  openSshEndpoint,
  runVmWorkflow,
}));

const { GET, POST } = await import("../app/api/vm/route");
const { DELETE } = await import("../app/api/vm/[id]/route");
const attachRoute = await import("../app/api/vm/[id]/attach-endpoint/route");
const execRoute = await import("../app/api/vm/[id]/exec/route");
const sshRoute = await import("../app/api/vm/[id]/ssh-endpoint/route");

beforeEach(() => {
  getUser.mockClear();
  getUser.mockResolvedValue(null);
  runVmWorkflow.mockClear();
  createVm.mockClear();
  destroyVm.mockClear();
  execVm.mockClear();
  listUserVms.mockClear();
  openAttachEndpoint.mockClear();
  openSshEndpoint.mockClear();
});

describe("VM REST auth", () => {
  test("rejects unauthenticated provisioning before reaching Postgres or providers", async () => {
    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        body: JSON.stringify({ provider: "freestyle" }),
      }),
    );

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(getUser).toHaveBeenCalled();
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("rejects unauthenticated VM listing before reaching Postgres", async () => {
    const response = await GET(new Request("https://cmux.test/api/vm"));

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("rejects unauthenticated VM mutations before reaching workflows", async () => {
    const context = { params: Promise.resolve({ id: "provider-vm-1" }) };
    const responses = await Promise.all([
      DELETE(new Request("https://cmux.test/api/vm/provider-vm-1", { method: "DELETE" }), context),
      attachRoute.POST(new Request("https://cmux.test/api/vm/provider-vm-1/attach-endpoint", { method: "POST" }), context),
      sshRoute.POST(new Request("https://cmux.test/api/vm/provider-vm-1/ssh-endpoint", { method: "POST" }), context),
      execRoute.POST(
        new Request("https://cmux.test/api/vm/provider-vm-1/exec", {
          method: "POST",
          body: JSON.stringify({ command: "true" }),
        }),
        context,
      ),
    ]);

    for (const response of responses) {
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: "unauthorized" });
    }
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("authenticated provisioning runs the Effect VM workflow", async () => {
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      selectedTeam: {
        id: "team-1",
        clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
      },
      listTeams: async () => [{
        id: "team-1",
        clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
      }],
    });
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-1",
      provider: "freestyle",
      image: "snapshot-test",
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { "idempotency-key": "idem-1" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      id: "provider-vm-1",
      provider: "freestyle",
      image: "snapshot-test",
      createdAt: 1_777_000_000_000,
    });
    expect(createVm).toHaveBeenCalledWith({
      userId: "user-1",
      billingCustomerType: "team",
      billingTeamId: "team-1",
      billingPlanId: "pro",
      maxActiveVms: 10,
      provider: "freestyle",
      image: "snapshot-test",
      idempotencyKey: "idem-1",
    });
    expect(runVmWorkflow).toHaveBeenCalled();
  });
});
