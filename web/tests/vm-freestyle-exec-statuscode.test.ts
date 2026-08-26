import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";

// Regression: the Freestyle exec path used to read the provider response with
// `(r as { statusCode?: number }).statusCode ?? 0`, so a malformed exec payload with NO
// statusCode at all was reported as a successful exit-0 command. A missing exit code must be
// an error, never silent success — callers use exit codes to decide whether lease installs,
// repairs, and health probes worked.
describe("FreestyleProvider exec response validation", () => {
  const originalFetch = globalThis.fetch;
  const originalApiKey = process.env.FREESTYLE_API_KEY;

  beforeEach(() => {
    process.env.FREESTYLE_API_KEY = "test-freestyle-api-key";
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
    if (originalApiKey === undefined) delete process.env.FREESTYLE_API_KEY;
    else process.env.FREESTYLE_API_KEY = originalApiKey;
  });

  function stubExecResponse(body: unknown): void {
    globalThis.fetch = (async () =>
      new Response(JSON.stringify(body), {
        status: 200,
        headers: { "content-type": "application/json" },
      })) as typeof fetch;
  }

  test("a response missing statusCode is an error, not exit-0 success", async () => {
    stubExecResponse({ stdout: "partial output", stderr: "" });
    const provider = new FreestyleProvider();
    await expect(provider.exec("vm-1", "true")).rejects.toThrow(/statusCode|unexpected response shape/);
  });

  test("a well-formed response maps statusCode to exitCode", async () => {
    stubExecResponse({ statusCode: 7, stdout: "out", stderr: "err" });
    const provider = new FreestyleProvider();
    const result = await provider.exec("vm-1", "false");
    expect(result.exitCode).toBe(7);
    expect(result.stdout).toBe("out");
    expect(result.stderr).toBe("err");
  });

  test("null stdout/stderr normalize to empty strings", async () => {
    stubExecResponse({ statusCode: 0, stdout: null, stderr: null });
    const provider = new FreestyleProvider();
    const result = await provider.exec("vm-1", "true");
    expect(result).toEqual({ exitCode: 0, stdout: "", stderr: "" });
  });
});
