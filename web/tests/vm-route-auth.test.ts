import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

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
const VM_ENV_KEYS = [
  "CMUX_VM_CREATE_ENABLED",
  "CMUX_VM_E2B_ENABLED",
  "CMUX_VM_FREESTYLE_ENABLED",
  "CMUX_VM_ALLOWED_ORIGINS",
  "CMUX_VM_ALLOW_UNMANIFESTED_IMAGES",
  "E2B_CMUXD_WS_TEMPLATE",
  "FREESTYLE_SANDBOX_SNAPSHOT",
  "CMUX_VM_FREE_MAX_ACTIVE_VMS",
  "CMUX_VM_PAID_MAX_ACTIVE_VMS",
  "CMUX_VM_PLAN_PRO_MAX_ACTIVE_VMS",
  "VERCEL",
  "VERCEL_ENV",
] as const;
const originalEnv = Object.fromEntries(
  VM_ENV_KEYS.map((key) => [key, process.env[key]]),
) as Record<(typeof VM_ENV_KEYS)[number], string | undefined>;

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
  restoreVmEnv();
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

afterEach(() => {
  restoreVmEnv();
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
        headers: { "idempotency-key": "idem-1", origin: "https://cmux.test" },
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
      imageVersion: null,
      idempotencyKey: "idem-1",
    });
    expect(runVmWorkflow).toHaveBeenCalled();
  });

  test("passes configured plan active VM limits into the create workflow", async () => {
    process.env.CMUX_VM_PLAN_PRO_MAX_ACTIVE_VMS = "25";
    getUser.mockResolvedValue(authedStackUser());
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-plan-limit",
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({
      billingTeamId: "team-1",
      billingPlanId: "pro",
      maxActiveVms: 25,
    }));
  });

  test("uses the native client's requested Stack team for billing", async () => {
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      selectedTeam: {
        id: "team-1",
        clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
      },
      listTeams: async () => [
        {
          id: "team-1",
          clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
        },
        {
          id: "team-2",
          clientReadOnlyMetadata: { cmuxVmPlan: "free" },
        },
      ],
    });
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-team-2",
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-team-id": "team-2",
        },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({
      billingCustomerType: "team",
      billingTeamId: "team-2",
      billingPlanId: "free",
      maxActiveVms: 1,
    }));
  });

  test("rejects a requested Stack team the caller does not belong to", async () => {
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-team-id": "team-other",
        },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ error: "vm_billing_team_not_found" });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("uses the single Stack team when personal team auto-create populated listTeams", async () => {
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      selectedTeam: null,
      listTeams: async () => [{
        id: "team-personal",
        clientReadOnlyMetadata: { cmuxVmPlan: "free" },
      }],
    });
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-personal-team",
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({
      billingCustomerType: "team",
      billingTeamId: "team-personal",
      billingPlanId: "free",
    }));
  });

  test("rejects VM create when Stack Auth returns no teams", async () => {
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      selectedTeam: null,
      listTeams: async () => [],
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: "vm_billing_team_required" });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("rejects VM create when Stack Auth returns multiple teams but no selected/requested team", async () => {
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      selectedTeam: null,
      listTeams: async () => [
        { id: "team-1", clientReadOnlyMetadata: { cmuxVmPlan: "free" } },
        { id: "team-2", clientReadOnlyMetadata: { cmuxVmPlan: "pro" } },
      ],
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: "vm_billing_team_required" });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("filters VM list to the requested Stack team", async () => {
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
      selectedTeam: {
        id: "team-1",
        clientReadOnlyMetadata: { cmuxVmPlan: "free" },
      },
      listTeams: async () => [
        { id: "team-1", clientReadOnlyMetadata: { cmuxVmPlan: "free" } },
        { id: "team-2", clientReadOnlyMetadata: { cmuxVmPlan: "pro" } },
      ],
    });
    runVmWorkflow.mockResolvedValue([{
      providerVmId: "provider-vm-team-2",
      provider: "e2b",
      image: "cmuxd-ws:test",
      imageVersion: "test-version",
      createdAt: 1_777_000_000_000,
    }]);

    const response = await GET(
      new Request("https://cmux.test/api/vm", {
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-team-id": "team-2",
        },
      }),
    );

    expect(response.status).toBe(200);
    expect(listUserVms).toHaveBeenCalledWith("user-1", "team-2");
    expect(await response.json()).toMatchObject({
      vms: [{ id: "provider-vm-team-2", provider: "e2b" }],
    });
  });

  test("blocks authenticated cookie mutations from cross-site origins before workflow", async () => {
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: {
          origin: "https://evil.example",
          "sec-fetch-site": "cross-site",
        },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "forbidden" });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("requires an Origin header for cookie-authenticated mutations", async () => {
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { "sec-fetch-site": "same-origin" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "forbidden" });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("blocks cross-site cookie mutations on VM child routes before workflow", async () => {
    getUser.mockResolvedValue(authedStackUser());
    const context = { params: Promise.resolve({ id: "provider-vm-1" }) };
    const headers = {
      origin: "https://evil.example",
      "sec-fetch-site": "cross-site",
    };

    const responses = await Promise.all([
      DELETE(new Request("https://cmux.test/api/vm/provider-vm-1", { method: "DELETE", headers }), context),
      attachRoute.POST(new Request("https://cmux.test/api/vm/provider-vm-1/attach-endpoint", { method: "POST", headers }), context),
      sshRoute.POST(new Request("https://cmux.test/api/vm/provider-vm-1/ssh-endpoint", { method: "POST", headers }), context),
      execRoute.POST(
        new Request("https://cmux.test/api/vm/provider-vm-1/exec", {
          method: "POST",
          headers,
          body: JSON.stringify({ command: "true" }),
        }),
        context,
      ),
    ]);

    for (const response of responses) {
      expect(response.status).toBe(403);
      expect(await response.json()).toEqual({ error: "forbidden" });
    }
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("allows native bearer mutations without browser CSRF headers", async () => {
    getUser.mockResolvedValue(authedStackUser());
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-native",
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: null,
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          origin: "https://evil.example",
          "sec-fetch-site": "cross-site",
        },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(runVmWorkflow).toHaveBeenCalled();
  });

  test("blocks VM create kill switch before workflow", async () => {
    process.env.CMUX_VM_CREATE_ENABLED = "0";
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({
      error: "vm_create_disabled",
      provider: "freestyle",
    });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("blocks provider kill switch before workflow", async () => {
    process.env.CMUX_VM_E2B_ENABLED = "false";
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "e2b", image: "cmuxd-ws:proxy-20260424a" }),
      }),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({
      error: "vm_create_disabled",
      provider: "e2b",
    });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("requires manifest images in deployed environments before workflow", async () => {
    process.env.VERCEL = "1";
    process.env.VERCEL_ENV = "preview";
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle", image: "unknown-snapshot" }),
      }),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({
      error: "vm_image_config_error",
      provider: "freestyle",
      image: "unknown-snapshot",
    });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("omits image from image config errors when no image was resolved", async () => {
    process.env.VERCEL = "1";
    process.env.VERCEL_ENV = "preview";
    getUser.mockResolvedValue(authedStackUser());

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle" }),
      }),
    );

    const payload = await response.json();
    expect(response.status).toBe(503);
    expect(payload).toMatchObject({
      error: "vm_image_config_error",
      provider: "freestyle",
      envVar: "FREESTYLE_SANDBOX_SNAPSHOT",
    });
    expect(payload).not.toHaveProperty("image");
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("records manifest image version on create workflow input", async () => {
    process.env.VERCEL = "1";
    process.env.VERCEL_ENV = "preview";
    process.env.FREESTYLE_SANDBOX_SNAPSHOT = "sh-6ch5p9k23xrcx24056n8";
    getUser.mockResolvedValue(authedStackUser());
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-manifest",
      provider: "freestyle",
      image: "sh-6ch5p9k23xrcx24056n8",
      imageVersion: "freestyle-rpclease-20260502a",
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { origin: "https://cmux.test" },
        body: JSON.stringify({ provider: "freestyle" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(createVm).toHaveBeenCalledWith(expect.objectContaining({
      image: "sh-6ch5p9k23xrcx24056n8",
      imageVersion: "freestyle-rpclease-20260502a",
    }));
  });
});

function restoreVmEnv(): void {
  for (const key of VM_ENV_KEYS) {
    const value = originalEnv[key];
    if (value === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }
}

function authedStackUser() {
  return {
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
  };
}
