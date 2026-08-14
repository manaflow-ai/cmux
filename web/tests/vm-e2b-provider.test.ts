import { afterAll, afterEach, describe, expect, mock, test } from "bun:test";
import { Sandbox, SandboxNotFoundError, type SandboxInfo } from "e2b";
import { E2BProvider } from "../services/vms/drivers/e2b";
import { ProviderError } from "../services/vms/drivers/types";

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

    const result = provider.getStatus("sandbox-unknown");
    await expect(result).rejects.toBeInstanceOf(ProviderError);
    await expect(result).rejects.toThrow("unknown state");
  });

  test("fails with a ProviderError when the status probe is unavailable", async () => {
    statusResponse = new Error("network unavailable");

    const result = provider.getStatus("sandbox-unavailable");
    await expect(result).rejects.toBeInstanceOf(ProviderError);
    await expect(result).rejects.not.toThrow("running");
  });
});

describe("E2BProvider SSH surface", () => {
  test("keeps raw SSH unsupported", async () => {
    await expect(provider.openSSH("sandbox-1")).rejects.toBeInstanceOf(ProviderError);
  });
});
