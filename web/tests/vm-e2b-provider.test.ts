import { afterAll, afterEach, describe, expect, mock, test } from "bun:test";
import { Sandbox, SandboxNotFoundError, type SandboxInfo } from "e2b";
import { E2BProvider } from "../services/vms/drivers/e2b";
import { ProviderError } from "../services/vms/drivers/types";
import { VmProviderOperationError } from "../services/vms/errors";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";

const provider = new E2BProvider();
const originalGetInfo = Sandbox.getInfo;
type GetInfoOptions = Parameters<typeof Sandbox.getInfo>[1];
type StatusResponse =
  | SandboxInfo
  | Error
  | ((sandboxId: string, options?: GetInfoOptions) => Promise<SandboxInfo>);
let statusResponse: StatusResponse = { state: "running" } as SandboxInfo;
const getInfo = mock(async (sandboxId: string, options?: GetInfoOptions): Promise<SandboxInfo> => {
  if (typeof statusResponse === "function") return await statusResponse(sandboxId, options);
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

  test("does not treat an unconfirmed plain not-found message as destroyed", async () => {
    statusResponse = new Error("Sandbox not found");

    const error = await provider.getStatus("sandbox-malformed-success").catch((cause: unknown) => cause);
    expect(error).toBeInstanceOf(ProviderError);
    expect((error as ProviderError).message).toBe("[e2b] status probe unavailable");
  });

  test("cancels a status probe at the configured short timeout", async () => {
    const timeoutMs = 10;
    const timeoutProvider = new E2BProvider({ statusProbeTimeoutMs: timeoutMs });
    let observedRequestTimeoutMs: number | undefined;
    let observedSignal: AbortSignal | undefined;
    statusResponse = async (_sandboxId, options) => {
      observedRequestTimeoutMs = options?.requestTimeoutMs;
      observedSignal = options?.signal;
      if (!observedSignal) throw new Error("status probe did not receive a cancellation signal");
      if (observedSignal.aborted) throw observedSignal.reason;
      return await new Promise<SandboxInfo>((_resolve, reject) => {
        observedSignal?.addEventListener("abort", () => reject(observedSignal?.reason), { once: true });
      });
    };

    const error = await timeoutProvider.getStatus("sandbox-timeout").catch((cause: unknown) => cause);

    expect(error).toBeInstanceOf(ProviderError);
    expect((error as ProviderError).message).toBe("[e2b] status probe unavailable");
    expect(observedRequestTimeoutMs).toBe(timeoutMs);
    expect(observedSignal?.aborted).toBe(true);
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
