import { describe, expect, test } from "bun:test";
import { createCmuxVmClient, DEFAULT_BASE_URL, type Vm } from "../src/index.ts";

const vmId = "vm_0123456789abcdefghjkmnpqrs";
const vm: Vm = {
  id: vmId,
  displayName: null,
  labels: {},
  state: "running",
  resources: { vcpus: 2, memoryMib: 4096, diskMib: 16384 },
  idleTimeoutSeconds: 300,
  maxRunSeconds: null,
  autoDeleteSeconds: null,
  createdAt: "2026-10-07T00:00:00.000Z",
  updatedAt: "2026-10-07T00:00:00.000Z",
};

function recorder(status: number, body: unknown) {
  const requests: Request[] = [];
  const fetch = async (request: Request) => {
    requests.push(request.clone());
    return new Response(body === undefined ? null : JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });
  };
  return { requests, fetch };
}

describe("createCmuxVmClient", () => {
  test("defaults to the production host and sends the bearer token", async () => {
    const { requests, fetch } = recorder(200, vm);
    const client = createCmuxVmClient({ token: "cmuxvm_sk_test", fetch });

    const { data, error } = await client.GET("/v1/vms/{vmId}", { params: { path: { vmId } } });

    expect(error).toBeUndefined();
    expect(data?.state).toBe("running");
    expect(requests[0]?.url).toBe(`${DEFAULT_BASE_URL}/v1/vms/${vmId}`);
    expect(requests[0]?.headers.get("authorization")).toBe("Bearer cmuxvm_sk_test");
    expect(requests[0]?.headers.get("x-cmux-team-id")).toBeNull();
  });

  test("sends the team header and a create body", async () => {
    const { requests, fetch } = recorder(201, vm);
    const client = createCmuxVmClient({
      token: "session",
      teamId: "team_42",
      baseUrl: "http://127.0.0.1:9/",
      fetch,
    });

    const { data } = await client.POST("/v1/vms", {
      params: { header: { "idempotency-key": "retry-1" } },
      body: { displayName: "dev box", idleTimeoutSeconds: 300 },
    });

    expect(data?.id).toBe(vmId);
    const request = requests[0];
    expect(request?.method).toBe("POST");
    expect(request?.url).toBe("http://127.0.0.1:9/v1/vms");
    expect(request?.headers.get("x-cmux-team-id")).toBe("team_42");
    expect(request?.headers.get("idempotency-key")).toBe("retry-1");
    expect(await request?.json()).toEqual({ displayName: "dev box", idleTimeoutSeconds: 300 });
  });

  test("a 404 surfaces as an error with its status", async () => {
    const { fetch } = recorder(404, { _tag: "NotFound", message: "VM not found" });
    const client = createCmuxVmClient({ token: "k", fetch });

    const { data, error, response } = await client.POST("/v1/vms/{vmId}/stop", {
      params: { path: { vmId } },
    });

    expect(data).toBeUndefined();
    expect(response.status).toBe(404);
    expect(error).toEqual({ _tag: "NotFound", message: "VM not found" });
  });
});

test("the default base URL is the production cmux.dev host", () => {
  expect(DEFAULT_BASE_URL).toBe("https://vm.cmux.dev");
});
