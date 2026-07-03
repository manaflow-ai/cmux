import { beforeEach, describe, expect, mock, test } from "bun:test";

const getUser = mock(async (): Promise<unknown> => null);
const runVmWorkflow = mock(async (program: unknown): Promise<unknown> => program);
const getAgentRoutingState = mock((userId: unknown) => ({ workflow: "get", userId }));
const setAgentRoutingConfig = mock((input: unknown) => ({ workflow: "set", input }));
const clearAgentRoutingConfig = mock((userId: unknown) => ({ workflow: "clear", userId }));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

// Include every export the other vm route tests import: bun's mock.module
// fixes the module's named-export set the first time any test file registers
// it in the shared test process, so a partial list here would break imports
// in test files that run later (and vice versa, see tests/vm-route-auth.test.ts).
mock.module("../services/vms/workflows", () => ({
  runVmWorkflow,
  getAgentRoutingState,
  setAgentRoutingConfig,
  clearAgentRoutingConfig,
  createVm: mock(() => ({ workflow: "create" })),
  destroyVm: mock(() => ({ workflow: "destroy" })),
  execVm: mock(() => ({ workflow: "exec" })),
  forkVm: mock(() => ({ workflow: "fork" })),
  getVm: mock(() => ({ workflow: "get" })),
  listUserVms: mock(() => ({ workflow: "list" })),
  openBaseVm: mock(() => ({ workflow: "base.open" })),
  openAttachEndpoint: mock(() => ({ workflow: "attach" })),
  openSshEndpoint: mock(() => ({ workflow: "ssh" })),
  restoreVm: mock(() => ({ workflow: "restore" })),
  resetBaseVm: mock(() => ({ workflow: "base.reset" })),
  snapshotVm: mock(() => ({ workflow: "snapshot" })),
}));

const { GET, PUT, DELETE } = await import("../app/api/vm/agent-routing/route");

const authedUser = {
  id: "user-1",
  displayName: null,
  primaryEmail: "user@example.com",
  selectedTeam: { id: "team-1", clientReadOnlyMetadata: {} },
  listTeams: async () => [{ id: "team-1", clientReadOnlyMetadata: {} }],
};

const configuredState = {
  configured: true,
  subrouterUrl: "https://subrouter.example.com",
  subrouterTenantKeyMasked: "srt_ab...56",
  updatedAt: 1_782_000_000_000,
};

function putRequest(body: unknown): Request {
  return new Request("https://cmux.test/api/vm/agent-routing", {
    method: "PUT",
    headers: { "content-type": "application/json", origin: "https://cmux.test" },
    body: JSON.stringify(body),
  });
}

beforeEach(() => {
  getUser.mockClear();
  getUser.mockResolvedValue(null);
  runVmWorkflow.mockClear();
  getAgentRoutingState.mockClear();
  setAgentRoutingConfig.mockClear();
  clearAgentRoutingConfig.mockClear();
});

describe("agent routing route auth", () => {
  test("rejects unauthenticated GET/PUT/DELETE before reaching workflows", async () => {
    const responses = await Promise.all([
      GET(new Request("https://cmux.test/api/vm/agent-routing")),
      PUT(putRequest({ subrouterUrl: "https://s.example.com", subrouterTenantKey: "srt_abcdef123456" })),
      DELETE(new Request("https://cmux.test/api/vm/agent-routing", {
        method: "DELETE",
        headers: { origin: "https://cmux.test" },
      })),
    ]);
    for (const response of responses) {
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: "unauthorized" });
    }
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });
});

describe("agent routing route validation", () => {
  beforeEach(() => {
    getUser.mockResolvedValue(authedUser);
  });

  test("rejects non-http(s) or malformed subrouter URLs", async () => {
    for (const subrouterUrl of ["ftp://x.example.com", "not a url", "", undefined]) {
      const response = await PUT(putRequest({ subrouterUrl, subrouterTenantKey: "srt_abcdef123456" }));
      expect(response.status).toBe(400);
      const body = await response.json() as { error: string };
      expect(body.error).toBe("invalid_request");
    }
    expect(setAgentRoutingConfig).not.toHaveBeenCalled();
  });

  test("rejects empty, short, and unsafe tenant keys", async () => {
    for (const subrouterTenantKey of ["", "short", "bad key with spaces", "slash/key1", undefined]) {
      const response = await PUT(putRequest({ subrouterUrl: "https://s.example.com", subrouterTenantKey }));
      expect(response.status).toBe(400);
      const body = await response.json() as { error: string };
      expect(body.error).toBe("invalid_request");
    }
    expect(setAgentRoutingConfig).not.toHaveBeenCalled();
  });

  test("stores trimmed values for a valid config", async () => {
    runVmWorkflow.mockResolvedValue(configuredState);
    const response = await PUT(putRequest({
      subrouterUrl: "https://subrouter.example.com/",
      subrouterTenantKey: " srt_abcdef123456 ",
    }));
    expect(response.status).toBe(200);
    expect(setAgentRoutingConfig).toHaveBeenCalledWith({
      userId: "user-1",
      subrouterUrl: "https://subrouter.example.com",
      subrouterTenantKey: "srt_abcdef123456",
    });
    const body = await response.json() as Record<string, unknown>;
    expect(body).toEqual(configuredState);
    // The full tenant key never appears in the response.
    expect(JSON.stringify(body)).not.toContain("srt_abcdef123456");
  });
});

describe("agent routing route responses", () => {
  beforeEach(() => {
    getUser.mockResolvedValue(authedUser);
  });

  test("GET returns the masked state only", async () => {
    runVmWorkflow.mockResolvedValue(configuredState);
    const response = await GET(new Request("https://cmux.test/api/vm/agent-routing"));
    expect(response.status).toBe(200);
    expect(getAgentRoutingState).toHaveBeenCalledWith("user-1");
    const body = await response.json() as Record<string, unknown>;
    expect(body).toEqual(configuredState);
    expect(body.subrouterTenantKeyMasked).toBe("srt_ab...56");
    expect(Object.keys(body)).not.toContain("subrouterTenantKey");
  });

  test("DELETE clears the config for the authed user", async () => {
    runVmWorkflow.mockResolvedValue({
      configured: false,
      subrouterUrl: null,
      subrouterTenantKeyMasked: null,
      updatedAt: 1_782_000_000_000,
    });
    const response = await DELETE(new Request("https://cmux.test/api/vm/agent-routing", {
      method: "DELETE",
      headers: { origin: "https://cmux.test" },
    }));
    expect(response.status).toBe(200);
    expect(clearAgentRoutingConfig).toHaveBeenCalledWith("user-1");
    const body = await response.json() as { configured: boolean };
    expect(body.configured).toBe(false);
  });
});
