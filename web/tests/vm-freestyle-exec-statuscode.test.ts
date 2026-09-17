import { describe, expect, test } from "bun:test";
import type { Freestyle } from "freestyle";
import { ProviderError } from "../services/vms/drivers/types";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";

// Use the current SDK seam: the shim probe succeeds before the command under test.
function providerWithResponse(body: unknown): FreestyleProvider {
  const client = {
    vms: {
      ref: () => ({
        exec: async ({ command }: { command: string }) => command.includes("sha256sum")
          ? { statusCode: 0, stdout: "", stderr: "" }
          : body,
      }),
    },
  } as unknown as Freestyle;
  return new FreestyleProvider({
    client: () => client,
    resolveDaemonSource: async () => { throw new Error("exec must not resolve the daemon source"); },
  });
}

describe("FreestyleProvider exec response validation", () => {
  test("a response missing statusCode is an error, not command success", async () => {
    const provider = providerWithResponse({ stdout: "partial output", stderr: "" });
    const error = await provider.exec("vm-1", "true").catch((error: unknown) => error);
    expect(error).toBeInstanceOf(ProviderError);
    expect((error as ProviderError).cause).toBeInstanceOf(ProviderError);
    expect(String((error as ProviderError).cause)).toContain("unexpected response shape");
  });

  test("a well-formed response maps statusCode to exitCode", async () => {
    const provider = providerWithResponse({ statusCode: 7, stdout: "out", stderr: "err" });
    expect(await provider.exec("vm-1", "false")).toEqual({
      exitCode: 7, stdout: "out", stderr: "err",
    });
  });

  test("null stdout/stderr normalize to empty strings", async () => {
    const provider = providerWithResponse({ statusCode: 0, stdout: null, stderr: null });
    expect(await provider.exec("vm-1", "true")).toEqual({ exitCode: 0, stdout: "", stderr: "" });
  });

  test("an explicit null statusCode preserves the provider timeout", async () => {
    const provider = providerWithResponse({ statusCode: null, stdout: "partial", stderr: "" });
    expect(await provider.exec("vm-1", "slow-command")).toEqual({
      exitCode: 124, stdout: "partial", stderr: "",
    });
  });
});
