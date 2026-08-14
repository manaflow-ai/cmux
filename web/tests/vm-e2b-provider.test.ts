import { afterAll, afterEach, describe, expect, mock, test } from "bun:test";
import { Sandbox, SandboxNotFoundError, type SandboxInfo } from "e2b";
import { E2BProvider } from "../services/vms/drivers/e2b";
import { ProviderError } from "../services/vms/drivers/types";
import { VmProviderOperationError } from "../services/vms/errors";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";

const provider = new E2BProvider();
const originalGetInfo = Sandbox.getInfo;
let statusResponse: SandboxInfo | Error = { state: "running" } as SandboxInfo;
const getInfo = mock(async (...args: unknown[]): Promise<SandboxInfo> => {
  void args;
  if (statusResponse instanceof Error) throw statusResponse;
  return statusResponse;
});
(Sandbox as unknown as { getInfo: typeof getInfo }).getInfo = getInfo;

afterAll(() => {
  (Sandbox as unknown as { getInfo: typeof originalGetInfo }).getInfo = originalGetInfo;
});

afterEach(() => {
  statusResponse = { state: "running" } as SandboxInfo;
  getInfo.mockClear();
});

describe("E2BProvider status", () => {
  test("maps a running sandbox to running", async () => {
    statusResponse = { state: "running" } as SandboxInfo;

    await expect(provider.getStatus("sandbox-running")).resolves.toBe("running");
    expect(getInfo).toHaveBeenCalledWith("sandbox-running");
  });

  test("maps a paused sandbox to paused", async () => {
    statusResponse = { state: "paused" } as SandboxInfo;

    await expect(provider.getStatus("sandbox-paused")).resolves.toBe("paused");
  });

  test("maps a provider-deleted sandbox to destroyed", async () => {
    statusResponse = new SandboxNotFoundError("Sandbox sandbox-deleted not found");

    await expect(provider.getStatus("sandbox-deleted")).resolves.toBe("destroyed");
  });

  test("fails with a ProviderError for an unknown provider state", async () => {
    statusResponse = { state: "stopping" } as unknown as SandboxInfo;

    const error = await provider.getStatus("sandbox-unknown").catch((cause: unknown) => cause);
    expect(error).toBeInstanceOf(ProviderError);
    expect((error as ProviderError).message).toBe("[e2b] status probe unavailable");
    expect((error as ProviderError).message).not.toContain("stopping");
  });

  test("keeps status probe details out of the VM API error response", async () => {
    statusResponse = { state: "provider-secret-state" } as unknown as SandboxInfo;

    const providerError = await provider.getStatus("sandbox-unknown").catch((cause: unknown) => cause);
    const response = vmWorkflowErrorResponse(
      new VmProviderOperationError({
        provider: "e2b",
        operation: "getStatus",
        cause: providerError,
      }),
    );

    expect(response).not.toBeNull();
    const payload = await response!.json() as {
      error: string;
      message: string;
      reason: string;
      details: Record<string, unknown>;
    };
    expect(payload).toMatchObject({
      error: "vm_cloud_service_unavailable",
      message: "The Cloud VM service could not complete this request yet.",
      reason: "Cloud VM service is temporarily unavailable.",
      details: {
        operation: "getStatus",
        phase: "status",
        retryable: true,
        retryAfterSeconds: 3,
      },
    });
    expect(payload.details.providerMessage).toBeUndefined();
    expect(JSON.stringify(payload)).not.toContain("provider-secret-state");
    expect(JSON.stringify(payload)).not.toContain("status probe unavailable");
  });

  test("fails closed on a malformed provider response", async () => {
    statusResponse = {} as SandboxInfo;

    const error = await provider.getStatus("sandbox-malformed").catch((cause: unknown) => cause);
    expect(error).toBeInstanceOf(ProviderError);
    expect((error as ProviderError).message).toBe("[e2b] status probe unavailable");
  });

  test("fails with a ProviderError when the status probe is unavailable", async () => {
    statusResponse = new Error("provider response contained a private network detail");

    const error = await provider.getStatus("sandbox-unavailable").catch((cause: unknown) => cause);
    expect(error).toBeInstanceOf(ProviderError);
    expect((error as ProviderError).message).toBe("[e2b] status probe unavailable");
    expect((error as ProviderError).message).not.toContain("private network detail");
    expect((error as ProviderError).message).not.toContain("running");
  });
});

describe("E2BProvider SSH surface", () => {
  test("keeps raw SSH unsupported", async () => {
    await expect(provider.openSSH("sandbox-1")).rejects.toBeInstanceOf(ProviderError);
  });
});
